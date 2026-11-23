// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
const std = @import("std");
const fleet = @import("fleet_dispatch.zig");
const registry = @import("deployment_registry.zig");
const actions = @import("server_actions.zig");

const Fake = struct {
    mutex: std.Thread.Mutex = .{},
    current: usize = 0,
    local_current: usize = 0,
    peak_global: usize = 0,
    peak_local: usize = 0,
    calls: usize = 0,
    deny: ?[]const u8 = null,
    cancel_after_first: ?*fleet.Cancel = null,

    fn resolve(_: *anyopaque, host: []const u8) anyerror!fleet.Access {
        if (std.mem.startsWith(u8, host, "remote-")) return .{ .ssh = host };
        if (std.mem.eql(u8, host, "bad-access")) return .{ .ssh = "bad host;" };
        return .local;
    }
    fn authorize(ctx: *anyopaque, i: *const fleet.Instance, _: fleet.Action) bool {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.deny == null or !std.mem.eql(u8, self.deny.?, i.id);
    }
    fn available(_: *anyopaque, runtime: registry.model.Runtime, _: fleet.Action) bool {
        return runtime != .process;
    }
    fn safe(_: *anyopaque, i: *const fleet.Instance, _: fleet.Action) bool {
        return !std.mem.eql(u8, i.id, "unsafe");
    }
    fn execute(ctx: *anyopaque, a: std.mem.Allocator, i: *const fleet.Instance, access: fleet.Access, _: fleet.Action, _: u32, cancel: *fleet.Cancel) anyerror!fleet.Execution {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        self.calls += 1;
        self.current += 1;
        self.peak_global = @max(self.peak_global, self.current);
        const local = access == .local;
        if (local) {
            self.local_current += 1;
            self.peak_local = @max(self.peak_local, self.local_current);
        }
        const issue_cancel = self.cancel_after_first != null and self.calls == 1;
        self.mutex.unlock();
        if (issue_cancel) cancel.request();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        self.mutex.lock();
        self.current -= 1;
        if (local) self.local_current -= 1;
        self.mutex.unlock();
        if (std.mem.eql(u8, i.id, "failure")) return .{ .status = .failed, .failure = .none, .started = true, .exit_code = 7, .error_output = "fixture failure" };
        if (std.mem.eql(u8, i.id, "uncertain")) return .{ .status = .indeterminate, .failure = .transport_timeout, .started = true, .effect_known = false };
        return .{ .status = .completed, .success = true, .started = true, .exit_code = 0, .output = try a.dupe(u8, i.id) };
    }
    fn backend(self: *Fake) fleet.Backend {
        return .{ .context = self, .resolve_host = resolve, .authorize = authorize, .available = available, .game_safe = safe, .execute = execute };
    }
};

fn declaration(id: []const u8, host: []const u8, runtime: registry.model.Runtime) fleet.Instance {
    return .{
        .id = id,
        .profile_id = "shared-profile",
        .host = host,
        .runtime = .{ .type = runtime, .identity = "safe-unit.service" },
        .game = .{ .version = "fixture" },
        .capabilities = .{ .probe = .{ .enabled = true }, .lifecycle = .{ .start = true } },
    };
}

test "fleet: explicit IDs keep partial failures attributed and reject gates before execution" {
    const a = std.testing.allocator;
    var inventory = registry.Registry.init(a);
    defer inventory.deinit();
    try inventory.register(declaration("one", "local", .systemd));
    try inventory.register(declaration("failure", "local", .systemd));
    try inventory.register(declaration("uncertain", "remote-east", .systemd));
    try inventory.register(declaration("denied", "local", .systemd));
    try inventory.register(declaration("unsupported", "local", .process));
    try inventory.register(declaration("unsafe", "local", .systemd));
    try inventory.register(declaration("bad-host", "bad-access", .systemd));
    var fake = Fake{ .deny = "denied" };
    var batch = try fleet.dispatch(a, &inventory, .{ .instance_ids = &.{ "one", "failure", "uncertain", "denied", "unsupported", "unsafe", "bad-host", "missing" }, .action = .Status }, fake.backend());
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 8), batch.results.len);
    try std.testing.expectEqualStrings("one", batch.results[0].execution.output);
    try std.testing.expectEqual(.failed, batch.results[1].execution.status);
    try std.testing.expectEqualStrings("failure", batch.results[1].instance_id);
    try std.testing.expectEqual(.indeterminate, batch.results[2].execution.status);
    try std.testing.expect(!batch.results[2].execution.effect_known);
    try std.testing.expectEqualStrings("CallerUnauthorized", batch.results[3].execution.error_output);
    try std.testing.expectEqualStrings("BackendUnavailable", batch.results[4].execution.error_output);
    try std.testing.expectEqualStrings("GameUnsafe", batch.results[5].execution.error_output);
    try std.testing.expectEqualStrings("InvalidHostAccess", batch.results[6].execution.error_output);
    try std.testing.expectEqualStrings("UnknownInstance", batch.results[7].execution.error_output);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
}

test "fleet: global and per-host limits and destructive default are bounded" {
    const a = std.testing.allocator;
    var inventory = registry.Registry.init(a);
    defer inventory.deinit();
    try inventory.register(declaration("a", "local", .systemd));
    try inventory.register(declaration("b", "local", .systemd));
    try inventory.register(declaration("c", "local", .systemd));
    try inventory.register(declaration("d", "remote-west", .systemd));
    var fake = Fake{};
    var batch = try fleet.dispatch(a, &inventory, .{ .instance_ids = &.{ "a", "b", "c", "d" }, .action = .Start, .global_limit = 3 }, fake.backend());
    defer batch.deinit();
    try std.testing.expect(fake.peak_global <= 3);
    try std.testing.expectEqual(@as(usize, 1), fake.peak_local);
}

test "fleet: readonly default allows bounded same-host overlap" {
    const a = std.testing.allocator;
    var inventory = registry.Registry.init(a);
    defer inventory.deinit();
    try inventory.register(declaration("a", "local", .systemd));
    try inventory.register(declaration("b", "local", .systemd));
    try inventory.register(declaration("c", "local", .systemd));
    var fake = Fake{};
    var batch = try fleet.dispatch(a, &inventory, .{ .instance_ids = &.{ "a", "b", "c" }, .action = .Status, .global_limit = 3 }, fake.backend());
    defer batch.deinit();
    try std.testing.expect(fake.peak_local >= 2 and fake.peak_local <= 2);
}

test "fleet: cancellation prevents queued work from starting" {
    const a = std.testing.allocator;
    var inventory = registry.Registry.init(a);
    defer inventory.deinit();
    try inventory.register(declaration("a", "local", .systemd));
    try inventory.register(declaration("b", "local", .systemd));
    try inventory.register(declaration("c", "local", .systemd));
    var fake = Fake{};
    var cancel = fleet.Cancel{};
    fake.cancel_after_first = &cancel;
    var batch = try fleet.dispatch(a, &inventory, .{ .instance_ids = &.{ "a", "b", "c" }, .action = .Start, .global_limit = 1, .cancel = &cancel }, fake.backend());
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    var cancelled: usize = 0;
    for (batch.results) |result| if (result.execution.status == .cancelled) {
        cancelled += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), cancelled);
}

test "fleet: duplicate targets and unsafe request limits are rejected before dispatch" {
    const a = std.testing.allocator;
    var inventory = registry.Registry.init(a);
    defer inventory.deinit();
    var fake = Fake{};
    try std.testing.expectError(error.DuplicateTarget, fleet.dispatch(a, &inventory, .{ .instance_ids = &.{ "x", "x" }, .action = .Status }, fake.backend()));
    try std.testing.expectError(error.InvalidLimit, fleet.dispatch(a, &inventory, .{ .instance_ids = &.{"x"}, .action = .Status, .global_limit = 33 }, fake.backend()));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

const Capture = struct {
    arena: std.heap.ArenaAllocator,
    argv: ?[][]const u8 = null,
    remote: bool = false,
    fn run(ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, remote: bool) anyerror!actions.ActionResult {
        _ = a;
        const self: *Capture = @ptrCast(@alignCast(ctx));
        const owned = self.arena.allocator();
        self.argv = try owned.alloc([]const u8, argv.len);
        for (argv, 0..) |arg, n| self.argv.?[n] = try owned.dupe(u8, arg);
        self.remote = remote;
        return .{ .success = true, .exit_code = 0, .output = "captured" };
    }
};

test "fleet: production adapter preserves validated action and SSH quoting path" {
    var capture = Capture{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer capture.arena.deinit();
    const runner: actions.CommandRunner = .{ .context = &capture, .run = Capture.run };
    const a = std.testing.allocator;
    _ = try actions.executeActionUsing(a, "remote-host", .Status, "minecraft.service", .systemd, runner);
    try std.testing.expect(capture.remote);
    try std.testing.expectEqualStrings("ssh", capture.argv.?[0]);
    try std.testing.expect(std.mem.indexOf(u8, capture.argv.?[7], "'systemctl' 'status' 'minecraft.service'") != null);
    capture.argv = null;
    capture.remote = false;
    _ = try actions.executeActionUsing(a, "", .Status, "minecraft.service", .systemd, runner);
    try std.testing.expect(!capture.remote);
    try std.testing.expectEqualStrings("systemctl", capture.argv.?[0]);
}
