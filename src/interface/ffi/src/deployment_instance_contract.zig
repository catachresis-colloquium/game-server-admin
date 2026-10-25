// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Fixture/test-only. No registry, ABI, process, filesystem or network adapter.
const std = @import("std");
const Allocator = std.mem.Allocator;
const exact = @import("exact_json_number.zig");
pub const CONTRACT_NAME = "gsa.deployment-instance";
pub const CONTRACT_VERSION = "0.1.0";
const ReadOnly = struct { enabled: bool, mode: []const u8 };
const Port = struct {
    protocol: []const u8,
    port: i64,
    purpose: []const u8,

    // Zig's integer JSON parser accepts numeric strings. Inspect the token's
    // JSON type first, so this boundary agrees with JSON Schema's integer type.
    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !Port {
        var exact_options = options;
        exact_options.parse_numbers = false;
        var value = try std.json.innerParse(std.json.Value, allocator, source, exact_options);
        if (value == .object) {
            if (value.object.get("port")) |number| {
                switch (number) {
                    .number_string => |raw| {
                        const number_value = exact.analyze(raw);
                        if (!number_value.integral) return error.InvalidNumber;
                        const magnitude = number_value.magnitude orelse 0;
                        const n = if (number_value.negative or magnitude > 65535) 0 else magnitude;
                        try value.object.put("port", .{ .integer = @intCast(n) });
                    },
                    else => return error.UnexpectedToken,
                }
            }
        }
        return std.json.innerParseFromValue(Port, allocator, value, options);
    }
};
const Mod = struct { id: []const u8, version: []const u8 };

/// Blocks are explicit and required; game.update_channel is optional opaque
/// metadata (omission/null means unspecified). No operational defaults.
/// Strict parsing rejects unknown fields (including secrets) at every object.
/// Strings are opaque, never executed. No reference is resolved.
pub const Instance = struct {
    contract: struct { name: []const u8, version: []const u8 },
    id: []const u8,
    profile_id: []const u8,
    host: []const u8,
    runtime: struct { type: []const u8, identity: []const u8 },
    ports: []const Port,
    paths: struct { data: []const []const u8, config: []const []const u8, world: []const []const u8 },
    game: struct { version: []const u8, update_channel: ?[]const u8 = null, mods: []const Mod },
    resources: struct { memory: struct { minimum: ?[]const u8 = null, maximum: ?[]const u8 = null } },
    backup: struct { policy_ref: ?[]const u8 = null },
    capabilities: struct {
        probe: ReadOnly,
        config: ReadOnly,
        logs: ReadOnly,
        lifecycle: struct { start: bool, stop: bool, restart: bool, update: bool },
        backup: struct { enabled: bool },
    },
};

/// Caller owns Parsed and must call deinit(). Errors are static, with no
/// submitted values. JSON parse/type errors and validate() errors propagate.
pub fn parseInstance(allocator: Allocator, input: []const u8) !std.json.Parsed(Instance) {
    const parsed = try std.json.parseFromSlice(Instance, allocator, input, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

/// Check an explicitly supplied JSON array. IDs are unique throughout this
/// set, even across hosts. This helper is not a production registry.
pub fn validateFixtureSet(allocator: Allocator, input: []const u8) !void {
    const parsed = try std.json.parseFromSlice([]Instance, allocator, input, .{});
    defer parsed.deinit();
    for (parsed.value, 0..) |instance, i| {
        try validate(instance);
        for (parsed.value[0..i]) |previous| {
            if (std.mem.eql(u8, previous.id, instance.id)) return error.DuplicateInstanceId;
        }
    }
}

fn validate(instance: Instance) !void {
    if (!std.mem.eql(u8, instance.contract.name, CONTRACT_NAME) or
        !std.mem.eql(u8, instance.contract.version, CONTRACT_VERSION)) return error.UnsupportedInstanceContract;
    if (!isId(instance.id) or !isId(instance.profile_id)) return error.InvalidIdentity;
    // id and profile_id have distinct meanings even when their text coincides.
    // Both must be supplied independently; neither is derived or filled in.
    if (!oneOf(instance.runtime.type, &.{ "systemd", "podman", "process" })) return error.InvalidEnumTag;
    inline for (.{ "probe", "config", "logs" }) |key| {
        if (!std.mem.eql(u8, @field(instance.capabilities, key).mode, "read-only")) return error.InvalidEnumTag;
    }
    if (instance.host.len == 0) return error.InvalidHost;
    if (instance.runtime.identity.len == 0) return error.InvalidRuntime;
    for (instance.ports) |port| {
        if (!oneOf(port.protocol, &.{ "tcp", "udp" })) return error.InvalidEnumTag;
        if (port.port < 1 or port.port > 65535 or port.purpose.len == 0) return error.InvalidPort;
    }
    inline for (.{ "data", "config", "world" }) |key| {
        for (@field(instance.paths, key)) |path| {
            if (path.len == 0 or path[0] != '/') return error.InvalidPath;
        }
    }
    if (instance.game.version.len == 0) return error.InvalidGameVersion;
    for (instance.game.mods) |mod| {
        if (!isId(mod.id) or mod.version.len == 0) return error.InvalidMod;
    }
    if (instance.resources.memory.minimum) |value| if (!isMemory(value)) return error.InvalidResourceLimit;
    if (instance.resources.memory.maximum) |value| if (!isMemory(value)) return error.InvalidResourceLimit;
    if (instance.backup.policy_ref) |value| if (!isId(value)) return error.InvalidPolicyReference;
}

fn oneOf(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn isId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

// Positive integer plus binary unit K/M/G/T; 1–15 digits. No fractions,
// signs, leading zeroes, unitless values or ambiguous units in 0.1.0.
fn isMemory(value: []const u8) bool {
    if (value.len < 2 or value.len > 16 or value[0] < '1' or value[0] > '9') return false;
    for (value[0 .. value.len - 1]) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return std.mem.indexOfScalar(u8, "KMGT", value[value.len - 1]) != null;
}

const fixture_root = "fixtures/deployment-instances/";
fn readFixture(path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024);
}
const valid_files = [_][]const u8{ "minecraft-survival", "minecraft-creative", "minecraft-modded", "barotrauma-coop", "minecraft-singleton", "unknown-limits", "partial-limits", "integer-decimal-port", "integer-exponent-port" };

test "deployment instances: valid fixtures and multi-Minecraft isolation" {
    const allocator = std.testing.allocator;
    var instances: [valid_files.len]std.json.Parsed(Instance) = undefined;
    var count: usize = 0;
    defer for (instances[0..count]) |parsed| parsed.deinit();
    for (valid_files, 0..) |name, i| {
        const path = try std.fmt.allocPrint(allocator, "{s}valid/{s}.json", .{ fixture_root, name });
        defer allocator.free(path);
        const input = try readFixture(path);
        defer allocator.free(input);
        instances[i] = try parseInstance(allocator, input);
        count += 1;
    }
    for (instances[0..3], 0..) |parsed, i| {
        const current = parsed.value;
        try std.testing.expectEqualStrings("minecraft-java", current.profile_id);
        for (instances[0..i]) |previous| {
            const other = previous.value;
            try std.testing.expect(!std.mem.eql(u8, current.id, other.id));
            try std.testing.expect(!std.mem.eql(u8, current.runtime.identity, other.runtime.identity));
            try std.testing.expect(current.ports[0].port != other.ports[0].port);
            try std.testing.expect(!std.mem.eql(u8, current.paths.data[0], other.paths.data[0]));
            try std.testing.expect(!std.mem.eql(u8, current.paths.world[0], other.paths.world[0]));
        }
    }
    var values: [valid_files.len]Instance = undefined;
    for (instances, 0..) |parsed, i| values[i] = parsed.value;
    const collection = try std.json.Stringify.valueAlloc(allocator, values, .{});
    defer allocator.free(collection);
    try validateFixtureSet(allocator, collection);
}

test "deployment instances: invalid fixtures fail for their documented reasons" {
    const allocator = std.testing.allocator;
    const manifest_json = try readFixture(fixture_root ++ "invalid-cases.json");
    defer allocator.free(manifest_json);
    const Case = struct { file: []const u8, zig_error: []const u8, collection: bool = false };
    const manifest = try std.json.parseFromSlice([]Case, allocator, manifest_json, .{ .ignore_unknown_fields = true });
    defer manifest.deinit();
    for (manifest.value) |case| {
        const path = try std.fmt.allocPrint(allocator, "{s}invalid/{s}", .{ fixture_root, case.file });
        defer allocator.free(path);
        const input = try readFixture(path);
        defer allocator.free(input);
        const result: anyerror!void = if (case.collection) validateFixtureSet(allocator, input) else blk: {
            const parsed = parseInstance(allocator, input) catch |err| break :blk err;
            parsed.deinit();
            break :blk {};
        };
        if (result) |_| {
            std.debug.print("Unexpected valid fixture: {s}\n", .{case.file});
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expectEqualStrings(case.zig_error, @errorName(err));
        }
    }
}

test "deployment instances: lifecycle declarations are inert data" {
    const allocator = std.testing.allocator;
    const input = try readFixture(fixture_root ++ "valid/minecraft-survival.json");
    defer allocator.free(input);
    const parsed = try parseInstance(allocator, input);
    defer parsed.deinit();
    var instance = parsed.value;
    instance.runtime.identity = "/nonexistent/gsa-fixture-command --must-never-execute";
    instance.capabilities.lifecycle = .{ .start = true, .stop = true, .restart = true, .update = true };
    instance.capabilities.backup.enabled = true;
    const data = try std.json.Stringify.valueAlloc(allocator, instance, .{});
    defer allocator.free(data);
    const checked = try parseInstance(allocator, data);
    defer checked.deinit();
    try std.testing.expect(checked.value.capabilities.lifecycle.start);
    // No execution callback/adapter exists. An unresolvable runtime identity
    // and enabled capabilities validate without invoking any operation.
}

test "deployment instances: port bounds and integral JSON numbers" {
    const allocator = std.testing.allocator;
    const fixture = try readFixture(fixture_root ++ "valid/minecraft-survival.json");
    defer allocator.free(fixture);
    const parsed = try parseInstance(allocator, fixture);
    defer parsed.deinit();
    const compact = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    defer allocator.free(compact);
    const original = "\"port\":25565";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, compact, original));
    for ([_][]const u8{ "\"port\":1", "\"port\":65535", "\"port\":25565.0", "\"port\":1e0" }) |replacement| {
        const input = try std.mem.replaceOwned(u8, allocator, compact, original, replacement);
        defer allocator.free(input);
        const checked = try parseInstance(allocator, input);
        defer checked.deinit();
    }
    for ([_][]const u8{ "\"port\":0", "\"port\":-1", "\"port\":65536" }) |replacement| {
        const input = try std.mem.replaceOwned(u8, allocator, compact, original, replacement);
        defer allocator.free(input);
        try std.testing.expectError(error.InvalidPort, parseInstance(allocator, input));
    }
    for ([_][]const u8{ "\"port\":false", "\"port\":null", "\"port\":\"25565\"" }) |replacement| {
        const input = try std.mem.replaceOwned(u8, allocator, compact, original, replacement);
        defer allocator.free(input);
        try std.testing.expectError(error.UnexpectedToken, parseInstance(allocator, input));
    }
}

test "deployment instances: strict JSON and scalar boundaries" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.DuplicateField, parseInstance(allocator, "{\"id\":\"one\",\"id\":\"two\"}"));
    try std.testing.expectError(error.DuplicateField, validateFixtureSet(allocator, "[{\"id\":\"one\",\"id\":\"two\"}]"));
    try std.testing.expectError(error.UnexpectedEndOfInput, parseInstance(allocator, "{"));
    try std.testing.expectError(error.UnexpectedToken, validateFixtureSet(allocator, "{}"));
    try std.testing.expect(isId(&(@as([128]u8, @splat('a')))));
    try std.testing.expect(!isId(&(@as([129]u8, @splat('a')))));
    for ([_][]const u8{ "", "bad id", "trailing\n", "-leading", "unicode-é" }) |id| try std.testing.expect(!isId(id));
    for ([_][]const u8{ "1K", "2M", "16G", "999999999999999T" }) |memory| try std.testing.expect(isMemory(memory));
    for ([_][]const u8{ "", "0G", "01G", "-1G", "1.5G", "1GB", "1GiB", "1g", "1", "1G\n", "1000000000000000T" }) |memory| try std.testing.expect(!isMemory(memory));
}

test "deployment instances: optional opaque channels and coincident identity strings" {
    const allocator = std.testing.allocator;
    const creative_json = try readFixture(fixture_root ++ "valid/minecraft-creative.json");
    defer allocator.free(creative_json);
    const creative = try parseInstance(allocator, creative_json);
    defer creative.deinit();
    try std.testing.expect(creative.value.game.update_channel == null);
    const modded_json = try readFixture(fixture_root ++ "valid/minecraft-modded.json");
    defer allocator.free(modded_json);
    const modded = try parseInstance(allocator, modded_json);
    defer modded.deinit();
    try std.testing.expectEqualStrings("fabric/snapshots/custom-track", modded.value.game.update_channel.?);
    const singleton_json = try readFixture(fixture_root ++ "valid/minecraft-singleton.json");
    defer allocator.free(singleton_json);
    const singleton = try parseInstance(allocator, singleton_json);
    defer singleton.deinit();
    try std.testing.expect(singleton.value.game.update_channel == null);
    try std.testing.expectEqualStrings(singleton.value.id, singleton.value.profile_id);
    const collection = try std.json.Stringify.valueAlloc(allocator, [_]Instance{ singleton.value, singleton.value }, .{});
    defer allocator.free(collection);
    try std.testing.expectError(error.DuplicateInstanceId, validateFixtureSet(allocator, collection));
}

test "deployment instances: unknown resource and policy metadata stays unknown" {
    const a = std.testing.allocator;
    const bytes = try readFixture(fixture_root ++ "valid/unknown-limits.json");
    defer a.free(bytes);
    const parsed = try parseInstance(a, bytes);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.resources.memory.minimum == null);
    try std.testing.expect(parsed.value.resources.memory.maximum == null);
    try std.testing.expect(parsed.value.backup.policy_ref == null);
    try std.testing.expect(!parsed.value.capabilities.backup.enabled);
    const partial = try readFixture(fixture_root ++ "valid/partial-limits.json");
    defer a.free(partial);
    const known = try parseInstance(a, partial);
    defer known.deinit();
    try std.testing.expect(known.value.resources.memory.minimum == null);
    try std.testing.expectEqualStrings("2G", known.value.resources.memory.maximum.?);
}
