// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
const std = @import("std");
pub const Decimal = struct { negative: bool, integral: bool, magnitude: ?u64 };

/// Analyze a valid JSON numeric lexeme from the scanner without floating point.
/// Null magnitude means an integral value beyond u64, not a fractional value.
pub fn analyze(raw: []const u8) Decimal {
    const negative = raw[0] == '-';
    const start: usize = if (negative) 1 else 0;
    const end = std.mem.indexOfAny(u8, raw, "eE") orelse raw.len;
    var exponent: i64 = 0;
    if (end != raw.len) {
        var i = end + 1;
        const neg = raw[i] == '-';
        if (raw[i] == '-' or raw[i] == '+') i += 1;
        for (raw[i..]) |c| exponent = @min(1_000_000_000, exponent * 10 + (c - '0'));
        if (neg) exponent = -exponent;
    }
    var digits: i64 = 0;
    var fraction: i64 = 0;
    var after_dot = false;
    var first: ?i64 = null;
    var last: i64 = 0;
    for (raw[start..end]) |c| {
        if (c == '.') {
            after_dot = true;
            continue;
        }
        if (after_dot) fraction += 1;
        if (c != '0') {
            if (first == null) first = digits;
            last = digits;
        }
        digits += 1;
    }
    const begin = first orelse return .{ .negative = negative, .integral = true, .magnitude = 0 };
    const whole_digits = digits + exponent - fraction;
    if (last >= whole_digits) return .{ .negative = negative, .integral = false, .magnitude = null };
    if (whole_digits - begin > 20) return .{ .negative = negative, .integral = true, .magnitude = null };
    var value: u64 = 0;
    var position: i64 = 0;
    for (raw[start..end]) |c| {
        if (c == '.') continue;
        if (position >= begin and position < whole_digits) {
            value = std.math.mul(u64, value, 10) catch return .{ .negative = negative, .integral = true, .magnitude = null };
            value = std.math.add(u64, value, c - '0') catch return .{ .negative = negative, .integral = true, .magnitude = null };
        }
        position += 1;
    }
    while (position < whole_digits) : (position += 1)
        value = std.math.mul(u64, value, 10) catch return .{ .negative = negative, .integral = true, .magnitude = null };
    return .{ .negative = negative, .integral = true, .magnitude = value };
}

test "decimal integrality preserves source precision" {
    for ([_][]const u8{ "25565", "25565.0", "2.5565e4", "25565000e-3", "0e-999999999999999999" }) |raw|
        try std.testing.expect(analyze(raw).integral);
    for ([_][]const u8{ "25565.5", "25565.0000000000000000000000000000000001", "1e-999999999999999999" }) |raw|
        try std.testing.expect(!analyze(raw).integral);
    try std.testing.expectEqual(@as(?u64, 25565), analyze("2.5565e4").magnitude);
    try std.testing.expect(analyze("1e9999999999999999999999").magnitude == null);
}
