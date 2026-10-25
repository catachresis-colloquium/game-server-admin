// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Internal read-only inspection primitives. No process execution or lifecycle API.
const std = @import("std");
pub const ActiveState = enum { active, inactive, failed, activating, deactivating, reloading, maintenance, refreshing };
pub const LoadState = enum { loaded, @"not-found", @"bad-setting", masked, @"error", merged, stub };
pub const Snapshot = struct {
    // Borrows strings from the supplied systemctl output.
    unit: []const u8,
    load: LoadState,
    active: ActiveState,
    working_directory: ?[]const u8,
    active_enter_us: ?u64,
};

pub fn safeUnit(unit: []const u8) bool {
    if (unit.len <= ".service".len or unit.len > 255 or !std.ascii.isAlphanumeric(unit[0]) or !std.mem.endsWith(u8, unit, ".service")) return false;
    for (unit) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "._@-", c) == null) return false;
    return true;
}

/// Fixed, minimal property request. Caller owns invocation/collection policy.
/// No shell string, Environment, ExecStart, status output, or arbitrary verb.
pub fn showArguments(unit: []const u8) ![5][]const u8 {
    if (!safeUnit(unit)) return error.InvalidUnit;
    return .{ "systemctl", "show", "--no-pager", "--property=Id,LoadState,ActiveState,WorkingDirectory,ActiveEnterTimestampMonotonic", unit };
}

pub fn parse(output: []const u8, requested_unit: []const u8) !Snapshot {
    if (!safeUnit(requested_unit)) return error.InvalidUnit;
    if (output.len > 65536) return error.InputTooLarge;
    const keys = [_][]const u8{ "Id", "LoadState", "ActiveState", "WorkingDirectory", "ActiveEnterTimestampMonotonic" };
    var values: [keys.len]?[]const u8 = @splat(null);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line.len > 4096) return error.InputTooLarge;
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse return error.MalformedSystemdOutput;
        for (keys, 0..) |key, i| {
            if (std.mem.eql(u8, key, line[0..equal])) {
                if (values[i] != null) return error.DuplicateProperty;
                values[i] = line[equal + 1 ..];
            }
        }
        // Unrequested properties are ignored and never retained in the report.
    }
    const unit = values[0] orelse return error.MalformedSystemdOutput;
    if (!std.mem.eql(u8, unit, requested_unit)) return error.UnitMismatch;
    const load = std.meta.stringToEnum(LoadState, values[1] orelse return error.MalformedSystemdOutput) orelse return error.MalformedSystemdOutput;
    const active = std.meta.stringToEnum(ActiveState, values[2] orelse return error.MalformedSystemdOutput) orelse return error.MalformedSystemdOutput;
    var entered: ?u64 = null;
    if (values[4]) |value| {
        const n = std.fmt.parseInt(u64, value, 10) catch return error.MalformedSystemdOutput;
        if (n != 0) entered = n;
    }
    return .{ .unit = unit, .load = load, .active = active, .working_directory = if (values[3]) |v| if (v.len == 0) null else v else null, .active_enter_us = entered };
}

test "systemd: fixed read-only arguments and invalid unit rejection" {
    const argv = try showArguments("minecraft-survival.service");
    try std.testing.expectEqualStrings("show", argv[1]);
    try std.testing.expect(std.mem.indexOf(u8, argv[3], "Environment") == null);
    for ([_][]const u8{ "--help", "../minecraft.service", "minecraft.service;restart", "minecraft\n.service", "minecraft.socket" }) |unit| {
        try std.testing.expectError(error.InvalidUnit, showArguments(unit));
    }
}

test "systemd: malformed, duplicate and mismatched evidence" {
    try std.testing.expectError(error.MalformedSystemdOutput, parse("bad output", "mc.service"));
    try std.testing.expectError(error.DuplicateProperty, parse("Id=mc.service\nId=mc.service\n", "mc.service"));
    try std.testing.expectError(error.UnitMismatch, parse("Id=other.service\nLoadState=loaded\nActiveState=active", "mc.service"));
    try std.testing.expectError(error.MalformedSystemdOutput, parse("Id=mc.service\nLoadState=loaded\nActiveState=nonsense", "mc.service"));
}
