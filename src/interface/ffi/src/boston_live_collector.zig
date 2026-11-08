// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
// Explicit-instance read-only BostonUnlocked Podman inspection.
const std = @import("std");
const registry = @import("deployment_registry.zig");
const model = @import("deployment_model.zig");
const process = @import("bounded_process.zig");

fn target(snapshot: *const registry.Snapshot, id: []const u8, host: []const u8, for_logs: bool) !*const model.Instance {
    const instance = try snapshot.lookup(id);
    if (!std.mem.eql(u8, instance.profile_id, "boston-unlocked")) return error.UnsupportedProfile;
    if (!std.mem.eql(u8, instance.host, host)) return error.HostMismatch;
    if (instance.runtime.type != .podman) return error.UnsupportedRuntime;
    const name = instance.runtime.identity;
    if (name.len == 0 or name.len > 128 or !std.ascii.isAlphanumeric(name[0])) return error.InvalidContainer;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_.-", c) == null) return error.InvalidContainer;
    if (for_logs and !instance.capabilities.logs.enabled) return error.LogsUnsupported;
    if (!for_logs and !instance.capabilities.probe.enabled) return error.ProbeUnsupported;
    return instance;
}

fn run(a: std.mem.Allocator, args: []const []const u8) !process.Result {
    var cancel = process.Cancel{};
    const result = try process.run(a, args, false, 5000, &cancel);
    if (!result.success or result.status != .completed or result.exit_code == null or result.exit_code.? != 0) {
        a.free(result.output);
        a.free(result.error_output);
        return error.ReadCommandFailed;
    }
    if (result.output.len + result.error_output.len > 65536) {
        a.free(result.output);
        a.free(result.error_output);
        return error.OutputTooLarge;
    }
    return result;
}

fn parse(text: []const u8, name: []const u8) !struct { id: []const u8, state: []const u8, pid: u32 } {
    if (text.len > 2048) return error.MalformedInspect;
    var fields = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \r\n"), '|');
    const actual = fields.next() orelse return error.MalformedInspect;
    const id = fields.next() orelse return error.MalformedInspect;
    const state = fields.next() orelse return error.MalformedInspect;
    const pid = std.fmt.parseInt(u32, fields.next() orelse return error.MalformedInspect, 10) catch return error.MalformedInspect;
    if (fields.next() != null or !std.mem.eql(u8, actual, name) or id.len < 12 or id.len > 64) return error.MalformedInspect;
    for (id) |c| if (!std.ascii.isHex(c)) return error.MalformedInspect;
    for ([_][]const u8{ "configured", "created", "initialized", "running", "stopped", "paused", "exited", "stopping", "restarting", "removing", "dead", "unknown" }) |valid| {
        if (std.mem.eql(u8, state, valid)) return .{ .id = id, .state = state, .pid = pid };
    }
    return error.MalformedInspect;
}

pub fn inspect(a: std.mem.Allocator, snapshot: *const registry.Snapshot, id: []const u8, host: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const instance = try target(snapshot, id, host, false);
    const args = [_][]const u8{ "podman", "inspect", "--format", "{{.Name}}|{{.Id}}|{{.State.Status}}|{{.State.Pid}}", instance.runtime.identity };
    const result = try run(scratch, &args);
    const evidence = try parse(result.output, instance.runtime.identity);
    const second = try run(scratch, &args);
    const again = try parse(second.output, instance.runtime.identity);
    if (!std.mem.eql(u8, evidence.id, again.id) or !std.mem.eql(u8, evidence.state, again.state) or evidence.pid != again.pid) return error.ContainerChanged;
    return std.json.Stringify.valueAlloc(a, .{ .instance_id = instance.id, .profile_id = instance.profile_id, .host = instance.host, .runtime_identity = instance.runtime.identity, .container_id = evidence.id, .state = evidence.state, .container_init_pid = if (std.mem.eql(u8, evidence.state, "running")) @as(?u32, evidence.pid) else null, .sampled_at_unix_seconds = std.time.timestamp(), .evidence_source = "Podman inspect of explicitly declared container", .declared_ports = instance.ports, .declared_data_paths = instance.paths.data, .declared_config_paths = instance.paths.config, .readiness = @as(?bool, null) }, .{ .whitespace = .indent_2 });
}

fn safeLogs(a: std.mem.Allocator, stdout: []const u8, stderr: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for ([_][]const u8{ stdout, stderr }) |stream| {
        var lines = std.mem.splitScalar(u8, stream, '\n');
        while (lines.next()) |line| {
            // Only known startup messages are returned; request and account logs are excluded.
            const prefixes = [_][]const u8{ "[localservice-cs] listening on ", "[localservice-cs] APlay TCP stub on ", "[localservice-cs] PhotonProxy TCP stub on ", "[localservice-cs] structured logs: ", "[localservice-cs] mission seed mode: " };
            var accepted = false;
            for (prefixes) |prefix| if (std.mem.startsWith(u8, line, prefix)) {
                accepted = true;
                break;
            };
            if (!accepted or std.mem.indexOfScalar(u8, line, 0x1b) != null) continue;
            const lower = try std.ascii.allocLowerString(a, line);
            defer a.free(lower);
            var secret = false;
            for ([_][]const u8{ "password", "token", "secret", "credential", "steamid", "account" }) |term| if (std.mem.indexOf(u8, lower, term) != null) {
                secret = true;
                break;
            };
            if (secret) continue;
            if (out.items.len + line.len + 1 > 65536) return error.OutputTooLarge;
            try out.appendSlice(a, line);
            try out.append(a, '\n');
        }
    }
    return out.toOwnedSlice(a);
}

pub fn logs(a: std.mem.Allocator, snapshot: *const registry.Snapshot, id: []const u8, host: []const u8, requested: u16) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const instance = try target(snapshot, id, host, true);
    const count = try std.fmt.allocPrint(scratch, "{d}", .{@min(@as(u16, 200), @max(@as(u16, 1), requested))});
    const result = try run(scratch, &.{ "podman", "logs", "--tail", count, instance.runtime.identity });
    return safeLogs(a, result.output, result.error_output);
}

test "Boston container inspection rejects incorrect identities and invalid state" {
    _ = try parse("boston-unlocked-test|0123456789abcdef|running|42", "boston-unlocked-test");
    try std.testing.expectError(error.MalformedInspect, parse("other|0123456789abcdef|running|42", "boston-unlocked-test"));
    try std.testing.expectError(error.MalformedInspect, parse("boston-unlocked-test|0123456789abcdef|bogus|42", "boston-unlocked-test"));
}

test "Boston log projection excludes secrets and unrelated request lines" {
    const output = try safeLogs(std.testing.allocator, "[localservice-cs] listening on port 80\nrequest password=hidden\n", "[localservice-cs] APlay TCP stub on port 5055\n[localservice-cs] listening on token=hidden\n");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("[localservice-cs] listening on port 80\n[localservice-cs] APlay TCP stub on port 5055\n", output);
}

test "Boston inspection and logs reject missing instances" {
    var reg = registry.Registry.init(std.testing.allocator);
    defer reg.deinit();
    var snapshot = try reg.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectError(error.UnknownInstance, inspect(std.testing.allocator, &snapshot, "missing", "local"));
    try std.testing.expectError(error.UnknownInstance, logs(std.testing.allocator, &snapshot, "missing", "local", 10));
}

test "Boston capabilities gate probe and logs independently" {
    const a = std.testing.allocator;
    var reg = registry.Registry.init(a);
    defer reg.deinit();
    try reg.register(.{ .id = "test", .profile_id = "boston-unlocked", .host = "local", .runtime = .{ .type = .podman, .identity = "test-container" }, .game = .{ .version = "test" }, .capabilities = .{ .logs = .{ .enabled = true } } });
    try reg.register(.{ .id = "probe-only", .profile_id = "boston-unlocked", .host = "local", .runtime = .{ .type = .podman, .identity = "test-container" }, .game = .{ .version = "test" }, .capabilities = .{ .probe = .{ .enabled = true } } });
    var snap = try reg.snapshot(a);
    defer snap.deinit();
    try std.testing.expectError(error.ProbeUnsupported, inspect(a, &snap, "test", "local"));
    _ = try target(&snap, "test", "local", true);
    try std.testing.expectError(error.HostMismatch, target(&snap, "test", "other", true));
    try std.testing.expectError(error.LogsUnsupported, logs(a, &snap, "probe-only", "local", 10));
}
