// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
const std = @import("std");
const posix = std.posix;
pub const Cancel = struct {
    requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pub fn request(self: *Cancel) void {
        self.requested.store(true, .release);
    }
    pub fn isRequested(self: *Cancel) bool {
        return self.requested.load(.acquire);
    }
};
pub const Status = enum { completed, failed, rejected, cancelled, timed_out, indeterminate };
pub const Failure = enum { none, admission, transport, transport_timeout, execution_timeout, cancellation, output_limit, backend };
pub const Result = struct {
    status: Status,
    success: bool = false,
    exit_code: ?i32 = null,
    output: []const u8 = "",
    error_output: []const u8 = "",
    failure: Failure = .none,
    started: bool = false,
    effect_known: bool = true,
};
fn drain(file: std.fs.File, open: *bool, out: *std.ArrayList(u8), a: std.mem.Allocator, total: *usize) !bool {
    if (!open.*) return true;
    var bytes: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(file.handle, &bytes) catch |err| switch (err) {
            error.WouldBlock => return true,
            else => return err,
        };
        if (n == 0) {
            open.* = false;
            return true;
        }
        if (total.* + n > 65536) return false;
        total.* += n;
        try out.appendSlice(a, bytes[0..n]);
    }
}
fn finishReaped(result: *Result, exit_code: ?i32, output_complete: bool, remote: bool) void {
    result.exit_code = exit_code;
    result.effect_known = exit_code != null;
    result.success = output_complete and exit_code != null and exit_code.? == 0;
    result.status = if (result.success) .completed else .failed;
    if (!output_complete) {
        result.failure = .output_limit;
        result.error_output = "captured output exceeded limit; output is incomplete";
    }
    if (remote and exit_code == 255) {
        result.status = .indeterminate;
        result.failure = .transport;
        result.effect_known = false;
    }
}
/// Linux-only bounded transport. Killing local SSH cannot prove remote rollback.
/// Caller frees both output slices. Cancelled-before-spawn returns empty literals.
pub fn run(a: std.mem.Allocator, argv: []const []const u8, remote: bool, timeout_ms: u32, cancel: *Cancel) !Result {
    if (@import("builtin").os.tag != .linux) return error.BackendUnavailable;
    if (timeout_ms == 0 or timeout_ms > 300000) return error.InvalidTimeout;
    if (cancel.isRequested()) return .{ .status = .cancelled, .failure = .cancellation };
    var timer = try std.time.Timer.start();
    var child = std.process.Child.init(argv, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var reaped = false;
    defer {
        if (!reaped) {
            posix.kill(child.id, posix.SIG.KILL) catch {};
            _ = posix.waitpid(child.id, 0);
        }
        if (child.stdout) |file| file.close();
        if (child.stderr) |file| file.close();
        if (child.err_pipe) |fd| posix.close(fd);
    }
    try child.waitForSpawn();
    for ([_]std.fs.File{ child.stdout.?, child.stderr.? }) |file| {
        const old = try posix.fcntl(file.handle, posix.F.GETFL, 0);
        _ = try posix.fcntl(file.handle, posix.F.SETFL, old | (@as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK")));
    }
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(a);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(a);
    var out_open = true;
    var err_open = true;
    var total: usize = 0;
    var result = Result{ .status = .failed, .started = true };
    while (true) {
        if (!(try drain(child.stdout.?, &out_open, &stdout, a, &total)) or !(try drain(child.stderr.?, &err_open, &stderr, a, &total))) {
            result.status = .indeterminate;
            result.failure = .output_limit;
            result.effect_known = false;
            break;
        }
        const waited = posix.waitpid(child.id, posix.W.NOHANG);
        if (waited.pid != 0) {
            reaped = true;
            const status = waited.status;
            const exit_code: ?i32 = if (posix.W.IFEXITED(status)) @intCast(posix.W.EXITSTATUS(status)) else if (posix.W.IFSIGNALED(status)) -@as(i32, @intCast(posix.W.TERMSIG(status))) else null;
            const stdout_ok = try drain(child.stdout.?, &out_open, &stdout, a, &total);
            const stderr_ok = try drain(child.stderr.?, &err_open, &stderr, a, &total);
            finishReaped(&result, exit_code, stdout_ok and stderr_ok, remote);
            break;
        }
        if (cancel.isRequested()) {
            result.status = if (remote) .indeterminate else .cancelled;
            result.failure = .cancellation;
            result.effect_known = false;
            break;
        }
        if (timer.read() >= @as(u64, timeout_ms) * std.time.ns_per_ms) {
            result.status = if (remote) .indeterminate else .timed_out;
            result.failure = if (remote) .transport_timeout else .execution_timeout;
            result.effect_known = false;
            break;
        }
        var fds = [_]posix.pollfd{
            .{ .fd = if (out_open) child.stdout.?.handle else -1, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (err_open) child.stderr.?.handle else -1, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&fds, 2);
    }
    result.output = try a.dupe(u8, stdout.items);
    errdefer a.free(result.output);
    result.error_output = try a.dupe(u8, stderr.items);
    return result;
}

test "bounded process: reaped child with final output overflow is failed but effect is known" {
    var result = Result{ .status = .completed, .success = true, .exit_code = 0, .effect_known = true };
    // This is the final-drain branch after waitpid has returned the child's
    // status. It remains separately testable because the precise pipe race is
    // otherwise timing-dependent.
    finishReaped(&result, 0, false, false);
    try std.testing.expectEqual(Status.failed, result.status);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.effect_known);
    try std.testing.expectEqual(@as(?i32, 0), result.exit_code);
    try std.testing.expectEqual(Failure.output_limit, result.failure);
    try std.testing.expect(std.mem.indexOf(u8, result.error_output, "incomplete") != null);
}
test "bounded process: exits, transport uncertainty, deadlines and cancellation" {
    const a = std.testing.allocator;
    var cancel = Cancel{};
    var r = try run(a, &.{ "/bin/sh", "-c", "printf fixture-output; printf fixture-error >&2; exit 7" }, false, 1000, &cancel);
    try std.testing.expectEqualStrings("fixture-output", r.output);
    try std.testing.expectEqualStrings("fixture-error", r.error_output);
    a.free(r.output);
    a.free(r.error_output);
    try std.testing.expectEqual(@as(?i32, 7), r.exit_code);
    r = try run(a, &.{ "/bin/sh", "-c", "exit 255" }, true, 1000, &cancel);
    a.free(r.output);
    a.free(r.error_output);
    try std.testing.expectEqual(.indeterminate, r.status);
    try std.testing.expectEqual(.transport, r.failure);
    try std.testing.expect(!r.effect_known);
    for ([_]bool{ false, true }) |remote| {
        r = try run(a, &.{ "/bin/sh", "-c", "exec sleep 5" }, remote, 10, &cancel);
        a.free(r.output);
        a.free(r.error_output);
        try std.testing.expectEqual(if (remote) Status.indeterminate else Status.timed_out, r.status);
        try std.testing.expect(!r.effect_known);
    }
    cancel.request();
    r = try run(a, &.{"/nonexistent/must-not-execute"}, false, 10, &cancel);
    try std.testing.expect(!r.started and r.status == .cancelled);
}

const Running = struct {
    cancel: Cancel = .{},
    result: ?Result = null,
    fn run(self: *Running) void {
        self.result = @import("bounded_process.zig").run(std.testing.allocator, &.{ "/bin/sh", "-c", "exec sleep 5" }, true, 5000, &self.cancel) catch unreachable;
    }
};

test "bounded process: cancelling an issued remote transport is indeterminate" {
    var running = Running{};
    const thread = try std.Thread.spawn(.{}, Running.run, .{&running});
    std.Thread.sleep(20 * std.time.ns_per_ms);
    running.cancel.request();
    thread.join();
    const result = running.result.?;
    defer std.testing.allocator.free(result.output);
    defer std.testing.allocator.free(result.error_output);
    try std.testing.expectEqual(Status.indeterminate, result.status);
    try std.testing.expectEqual(Failure.cancellation, result.failure);
    try std.testing.expect(!result.effect_known);
}
