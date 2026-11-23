// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
const std = @import("std");
const registry = @import("deployment_registry.zig");
const actions = @import("server_actions.zig");
pub const process = @import("bounded_process.zig");
pub const Action = actions.ActionKind;
pub const Instance = registry.Instance;
pub const Cancel = process.Cancel;
pub const Execution = process.Result;
const A = std.mem.Allocator;
pub const Access = union(enum) { local, ssh: []const u8 };
/// Callback concurrency contract:
/// - resolve_host runs synchronously during preflight, before workers start;
/// - authorize, available, game_safe and execute run during preflight and may
///   also run concurrently from worker threads;
/// - implementations and their shared context must therefore be thread-safe,
///   except resolve_host which is not called concurrently by dispatch.
/// All callbacks must be bounded/nonblocking local lookups except execute,
/// which must honor the provided deadline and cancellation token. Allocators
/// supplied to dispatch and execute must support concurrent use until Batch
/// deinit; each execute call receives its own result arena, but arenas share
/// the caller's underlying allocator. The production implementation below
/// uses the existing validated/quoted action path and a bounded Linux transport.
pub const Backend = struct {
    context: *anyopaque,
    resolve_host: *const fn (*anyopaque, []const u8) anyerror!Access,
    authorize: *const fn (*anyopaque, *const Instance, Action) bool,
    available: *const fn (*anyopaque, registry.model.Runtime, Action) bool,
    game_safe: *const fn (*anyopaque, *const Instance, Action) bool,
    execute: *const fn (*anyopaque, A, *const Instance, Access, Action, u32, *Cancel) anyerror!Execution,
};
pub const Request = struct {
    instance_ids: []const []const u8,
    action: Action,
    global_limit: u8 = 4,
    per_host_limit: ?u8 = null,
    timeout_ms: u32 = 10000,
    cancel: ?*Cancel = null,
};
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    instance_id: []const u8,
    host: []const u8,
    action: Action,
    execution: Execution = .{ .status = .rejected, .failure = .admission },
};
pub const Batch = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: registry.Snapshot,
    results: []Result,
    pub fn deinit(self: *Batch) void {
        for (self.results) |*result| result.arena.deinit();
        self.arena.deinit();
        self.snapshot.deinit();
    }
};
const Target = struct { instance: *const Instance, access: Access, group: usize };
pub fn supported(i: *const Instance, action: Action) bool {
    return switch (action) {
        .Start => i.capabilities.lifecycle.start,
        .Stop => i.capabilities.lifecycle.stop,
        .Restart => i.capabilities.lifecycle.restart,
        .Update => i.capabilities.lifecycle.update,
        .Backup => i.capabilities.backup.enabled,
        .Status => i.capabilities.probe.enabled,
        .Logs => i.capabilities.logs.enabled,
        .ValidateConfig => i.capabilities.config.enabled,
    };
}
fn validAccess(access: Access) bool {
    return switch (access) {
        .local => true,
        // The legacy executor infers locality from these aliases. Reject an
        // inconsistent explicit SSH route rather than silently execute locally.
        .ssh => |host| actions.isSafeHost(host) and !std.mem.eql(u8, host, "localhost") and !std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "::1"),
    };
}
fn gate(backend: Backend, i: *const Instance, action: Action) ?[]const u8 {
    if (!supported(i, action)) return "CapabilityUnsupported";
    if (!backend.authorize(backend.context, i, action)) return "CallerUnauthorized";
    if (!backend.available(backend.context, i.runtime.type, action)) return "BackendUnavailable";
    if (!backend.game_safe(backend.context, i, action)) return "GameUnsafe";
    return null;
}
const Control = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    backend: Backend,
    request: Request,
    cancel: *Cancel,
    results: []Result,
    targets: []?Target,
    queued: []bool,
    running: []usize,
    host_limit: usize,
    fn worker(self: *Control) void {
        while (true) {
            self.mutex.lock();
            var selected: ?usize = null;
            while (selected == null) {
                var pending = false;
                for (self.queued, 0..) |queued, n| {
                    if (!queued) continue;
                    if (self.cancel.isRequested()) {
                        self.queued[n] = false;
                        self.results[n].execution = .{ .status = .cancelled, .failure = .cancellation };
                        continue;
                    }
                    pending = true;
                    if (self.running[self.targets[n].?.group] < self.host_limit) {
                        selected = n;
                        break;
                    }
                }
                if (selected != null) break;
                if (!pending) {
                    self.mutex.unlock();
                    return;
                }
                self.condition.wait(&self.mutex);
            }
            const n = selected.?;
            const target = self.targets[n].?;
            self.queued[n] = false;
            self.running[target.group] += 1;
            self.mutex.unlock();
            var result: Execution = .{ .status = .rejected, .failure = .admission };
            if (self.cancel.isRequested()) {
                result = .{ .status = .cancelled, .failure = .cancellation };
            } else if (gate(self.backend, target.instance, self.request.action)) |reason| {
                result.error_output = reason;
            } else {
                result = self.backend.execute(self.backend.context, self.results[n].arena.allocator(), target.instance, target.access, self.request.action, self.request.timeout_ms, self.cancel) catch |err|
                    .{ .status = .indeterminate, .failure = .backend, .error_output = @errorName(err), .started = true, .effect_known = false };
            }
            self.results[n].execution = result;
            self.mutex.lock();
            self.running[target.group] -= 1;
            self.condition.broadcast();
            self.mutex.unlock();
        }
    }
};

/// Resolves every target against one owned snapshot before worker startup.
/// Backend policy/execution callbacks must follow Backend's thread-safety
/// contract. The allocator must support concurrent worker allocations and
/// remain valid until the returned batch is deinitialized.
pub fn dispatch(a: A, inventory: *registry.Registry, request: Request, backend: Backend) !Batch {
    if (request.instance_ids.len == 0 or request.instance_ids.len > 256) return error.InvalidTargetCount;
    if (request.global_limit == 0 or request.global_limit > 32 or request.timeout_ms == 0 or request.timeout_ms > 300000) return error.InvalidLimit;
    const host_limit = request.per_host_limit orelse (if (request.action == .Status or request.action == .Logs) @as(u8, 2) else @as(u8, 1));
    if (host_limit == 0 or host_limit > 8) return error.InvalidLimit;
    for (request.instance_ids, 0..) |id, n| for (request.instance_ids[0..n]) |previous| {
        if (std.mem.eql(u8, id, previous)) return error.DuplicateTarget;
    };
    var snapshot = try inventory.snapshot(a);
    errdefer snapshot.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const count = request.instance_ids.len;
    const results = try owned.alloc(Result, count);
    var initialized: usize = 0;
    errdefer for (results[0..initialized]) |*r| r.arena.deinit();
    const targets = try owned.alloc(?Target, count);
    @memset(targets, null);
    const queued = try owned.alloc(bool, count);
    @memset(queued, false);
    const running = try owned.alloc(usize, count);
    @memset(running, 0);
    var groups = std.StringHashMap(usize).init(owned);
    // Entire target set resolves against this ONE owned registry generation.
    for (request.instance_ids, 0..) |id, n| {
        results[n] = .{ .arena = std.heap.ArenaAllocator.init(a), .instance_id = try owned.dupe(u8, id), .host = "", .action = request.action };
        initialized += 1;
        if (!registry.model.validId(id)) {
            results[n].execution.error_output = "InvalidInstanceId";
            continue;
        }
        const instance = snapshot.lookup(id) catch {
            results[n].execution.error_output = "UnknownInstance";
            continue;
        };
        results[n].host = instance.host;
        if (!actions.isSafeContainerName(instance.runtime.identity)) {
            results[n].execution.error_output = "InvalidBackendIdentity";
            continue;
        }
        if (gate(backend, instance, request.action)) |reason| {
            results[n].execution.error_output = reason;
            continue;
        }
        var access = backend.resolve_host(backend.context, instance.host) catch {
            results[n].execution.error_output = "HostAccessUnavailable";
            continue;
        };
        if (!validAccess(access)) {
            results[n].execution.error_output = "InvalidHostAccess";
            continue;
        }
        const key = switch (access) {
            .local => "@local",
            .ssh => |host| host,
        };
        const entry = try groups.getOrPut(try owned.dupe(u8, key));
        if (!entry.found_existing) entry.value_ptr.* = groups.count() - 1;
        if (access == .ssh) access = .{ .ssh = try owned.dupe(u8, access.ssh) };
        targets[n] = .{ .instance = instance, .access = access, .group = entry.value_ptr.* };
        queued[n] = true;
    }
    var local_cancel = Cancel{};
    var control = Control{ .backend = backend, .request = request, .cancel = request.cancel orelse &local_cancel, .results = results, .targets = targets, .queued = queued, .running = running, .host_limit = host_limit };
    var workers: [31]std.Thread = undefined;
    var spawned: usize = 0;
    for (0..@min(request.global_limit - 1, count)) |_| {
        workers[spawned] = std.Thread.spawn(.{}, Control.worker, .{&control}) catch break;
        spawned += 1;
    }
    // Thread resource failure reduces concurrency instead of losing issued results.
    control.worker();
    for (workers[0..spawned]) |thread| thread.join();
    return .{ .arena = arena, .snapshot = snapshot, .results = results };
}

/// Application supplies inventory host resolution, authentication and game-safety
/// policy independently. No permissive default exists for either policy check.
pub const Production = struct {
    context: *anyopaque,
    resolve_host: *const fn (*anyopaque, []const u8) anyerror!Access,
    authorize: *const fn (*anyopaque, *const Instance, Action) bool,
    game_safe: *const fn (*anyopaque, *const Instance, Action) bool,
    pub fn backend(self: *Production) Backend {
        return .{ .context = self, .resolve_host = resolveAccess, .authorize = checkAuthorized, .available = available, .game_safe = checkSafe, .execute = execute };
    }
    fn resolveAccess(ctx: *anyopaque, host: []const u8) !Access {
        const self: *Production = @ptrCast(@alignCast(ctx));
        return self.resolve_host(self.context, host);
    }
    fn checkAuthorized(ctx: *anyopaque, i: *const Instance, action: Action) bool {
        const self: *Production = @ptrCast(@alignCast(ctx));
        return self.authorize(self.context, i, action);
    }
    fn checkSafe(ctx: *anyopaque, i: *const Instance, action: Action) bool {
        const self: *Production = @ptrCast(@alignCast(ctx));
        return self.game_safe(self.context, i, action);
    }
    fn available(_: *anyopaque, runtime: registry.model.Runtime, action: Action) bool {
        if (@import("builtin").os.tag != .linux or runtime == .process) return false;
        // The old systemd path falls back to status for unsupported verbs; do not
        // advertise that fallback as update/backup/validation execution.
        return action == .Start or action == .Stop or action == .Restart or action == .Status or action == .Logs;
    }
    const Runner = struct {
        timeout: u32,
        cancel: *Cancel,
        result: ?Execution = null,
        fn run(ctx: *anyopaque, a: A, argv: []const []const u8, remote: bool) !actions.ActionResult {
            const self: *Runner = @ptrCast(@alignCast(ctx));
            const result = try process.run(a, argv, remote, self.timeout, self.cancel);
            self.result = result;
            return .{ .success = result.success, .exit_code = result.exit_code orelse -1, .output = result.output };
        }
    };
    fn execute(_: *anyopaque, a: A, i: *const Instance, access: Access, action: Action, timeout: u32, cancel: *Cancel) !Execution {
        var runner = Runner{ .timeout = timeout, .cancel = cancel };
        const runtime: actions.Runtime = switch (i.runtime.type) {
            .systemd => .systemd,
            .podman => .podman,
            .process => return error.BackendUnavailable,
        };
        _ = try actions.executeActionUsing(a, switch (access) {
            .local => "",
            .ssh => |host| host,
        }, action, i.runtime.identity, runtime, .{ .context = &runner, .run = Runner.run });
        return runner.result orelse error.BackendDidNotExecute;
    }
};
test {
    _ = @import("fleet_dispatch_test.zig");
}
