// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
// Offline checker for the exact schema subset used here; NOT a full Draft engine.
const std = @import("std");
const contract = @import("deployment_instance_contract.zig");
const exact = @import("exact_json_number.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
const id_pattern = "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}(?![\\s\\S])";
const memory_pattern = "^[1-9][0-9]{0,14}[KMGT](?![\\s\\S])";

pub fn validate(schema: V, value: V) anyerror!void {
    if (schema.object.get("type")) |kind| {
        var matches = false;
        if (kind == .string) matches = isType(kind.string, value) else for (kind.array.items) |t| {
            if (isType(t.string, value)) matches = true;
        }
        if (!matches) return error.type;
    }
    if (schema.object.get("const")) |expected| if (!same(expected, value)) return error.@"const";
    if (schema.object.get("enum")) |choices| {
        var found = false;
        for (choices.array.items) |choice| if (same(choice, value)) {
            found = true;
        };
        if (!found) return error.@"enum";
    }
    if (value == .object) {
        if (schema.object.get("required")) |keys| for (keys.array.items) |key| {
            if (!value.object.contains(key.string)) return error.required;
        };
        const props = schema.object.get("properties");
        var it = value.object.iterator();
        while (it.next()) |entry| {
            if (props) |p| if (p.object.get(entry.key_ptr.*)) |child| {
                try validate(child, entry.value_ptr.*);
                continue;
            };
            if (schema.object.get("additionalProperties")) |allow| if (!allow.bool) return error.additionalProperties;
        }
    }
    if (value == .array) if (schema.object.get("items")) |item| {
        for (value.array.items) |child| try validate(item, child);
    };
    if (value == .string) {
        if (schema.object.get("minLength")) |n| {
            if (try std.unicode.utf8CountCodepoints(value.string) < exact.analyze(n.number_string).magnitude.?) return error.minLength;
        }
        if (schema.object.get("pattern")) |p| if (!matchesPattern(p.string, value.string)) return error.pattern;
    }
    if (value == .number_string) {
        const n = exact.analyze(value.number_string);
        if (schema.object.get("minimum")) |bound| {
            const b = exact.analyze(bound.number_string).magnitude.?;
            if (n.negative or (n.magnitude != null and n.magnitude.? < b)) return error.minimum;
        }
        if (schema.object.get("maximum")) |bound| {
            const b = exact.analyze(bound.number_string).magnitude.?;
            if (!n.negative and (n.magnitude == null or n.magnitude.? > b)) return error.maximum;
        }
    }
}

fn isType(name: []const u8, value: V) bool {
    if (std.mem.eql(u8, name, "object")) return value == .object;
    if (std.mem.eql(u8, name, "array")) return value == .array;
    if (std.mem.eql(u8, name, "string")) return value == .string;
    if (std.mem.eql(u8, name, "boolean")) return value == .bool;
    if (std.mem.eql(u8, name, "null")) return value == .null;
    if (std.mem.eql(u8, name, "integer")) return value == .number_string and exact.analyze(value.number_string).integral;
    return false;
}
fn same(x: V, y: V) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .string => std.mem.eql(u8, x.string, y.string),
        .bool => x.bool == y.bool,
        .null => true,
        else => false,
    };
}
fn matchesPattern(pattern: []const u8, text: []const u8) bool {
    if (std.mem.eql(u8, pattern, "^/")) return text.len > 0 and text[0] == '/';
    if (std.mem.eql(u8, pattern, id_pattern)) {
        if (text.len == 0 or text.len > 128 or !std.ascii.isAlphanumeric(text[0])) return false;
        for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
        return true;
    }
    if (std.mem.eql(u8, pattern, memory_pattern)) {
        if (text.len < 2 or text.len > 16 or text[0] < '1' or text[0] > '9') return false;
        for (text[0 .. text.len - 1]) |c| if (!std.ascii.isDigit(c)) return false;
        return std.mem.indexOfScalar(u8, "KMGT", text[text.len - 1]) != null;
    }
    return false;
}

/// Fail closed if the schema grows beyond this explicitly supported vocabulary.
fn checkSubset(schema: V) anyerror!void {
    if (schema != .object) return error.UnsupportedSchema;
    var it = schema.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "properties")) {
            if (v != .object) return error.UnsupportedSchema;
            for (v.object.values()) |child| try checkSubset(child);
        } else if (std.mem.eql(u8, key, "items")) {
            try checkSubset(v);
        } else if (std.mem.eql(u8, key, "pattern")) {
            if (v != .string or (!std.mem.eql(u8, v.string, id_pattern) and !std.mem.eql(u8, v.string, memory_pattern) and !std.mem.eql(u8, v.string, "^/"))) return error.UnsupportedSchema;
        } else {
            var known = false;
            for ([_][]const u8{ "$schema", "$id", "$comment", "title", "description", "type", "required", "additionalProperties", "enum", "const", "minLength", "minimum", "maximum" }) |allowed| {
                if (std.mem.eql(u8, key, allowed)) known = true;
            }
            if (!known) return error.UnsupportedSchema;
        }
    }
}
fn read(a: A, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1024 * 1024);
}
fn json(a: A, input: []const u8) !std.json.Parsed(V) {
    return std.json.parseFromSlice(V, a, input, .{ .parse_numbers = false });
}
pub fn checkFixtures(allocator: A) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = "fixtures/deployment-instances/";
    const schema = try json(a, try read(a, "schemas/deployment-instance-0.1.schema.json"));
    defer schema.deinit();
    try checkSubset(schema.value);
    var ids: std.ArrayList([]const u8) = .empty;
    var directory = try std.fs.cwd().openDir(root ++ "valid", .{ .iterate = true });
    defer directory.close();
    var it = directory.iterate();
    var valid_count: usize = 0;
    while (try it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const input = try read(a, try std.fmt.allocPrint(a, "{s}valid/{s}", .{ root, entry.name }));
        const value = try json(a, input);
        defer value.deinit();
        try validate(schema.value, value.value);
        const parsed = try contract.parseInstance(a, input);
        defer parsed.deinit();
        for (ids.items) |id| if (std.mem.eql(u8, id, parsed.value.id)) return error.DuplicateInstanceId;
        try ids.append(a, try a.dupe(u8, parsed.value.id));
        valid_count += 1;
    }
    var host_directory = try std.fs.cwd().openDir("deployment-instances/wizardly-hellman", .{ .iterate = true });
    defer host_directory.close();
    var host_iter = host_directory.iterate();
    var host_ids = std.StringHashMap(void).init(a);
    var host_count: usize = 0;
    while (try host_iter.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = try std.fmt.allocPrint(a, "deployment-instances/wizardly-hellman/{s}", .{entry.name});
        const input = try read(a, path);
        const value = try json(a, input);
        defer value.deinit();
        try validate(schema.value, value.value);
        const parsed = try contract.parseInstance(a, input);
        defer parsed.deinit();
        if (host_ids.contains(parsed.value.id)) return error.DuplicateInstanceId;
        try host_ids.put(try a.dupe(u8, parsed.value.id), {});
        host_count += 1;
    }
    if (host_count == 0) return error.MissingHostDeploymentInstances;
    const Case = struct { file: []const u8, zig_error: []const u8, schema_keyword: ?[]const u8 = null, collection: bool = false };
    const manifest = try std.json.parseFromSlice([]Case, a, try read(a, root ++ "invalid-cases.json"), .{ .ignore_unknown_fields = true });
    defer manifest.deinit();
    var seen = std.StringHashMap(void).init(a);
    for (manifest.value) |case| {
        if (seen.contains(case.file)) return error.DuplicateCase;
        try seen.put(case.file, {});
        const input = try read(a, try std.fmt.allocPrint(a, "{s}invalid/{s}", .{ root, case.file }));
        const value = try json(a, input);
        defer value.deinit();
        const schema_result: anyerror!void = if (case.collection) blk: {
            for (value.value.array.items) |child| try validate(schema.value, child);
            break :blk {};
        } else validate(schema.value, value.value);
        if (schema_result) |_| {
            if (case.schema_keyword != null) return error.UnexpectedSchemaAcceptance;
        } else |err| {
            if (case.schema_keyword == null or !std.mem.eql(u8, case.schema_keyword.?, @errorName(err))) {
                std.debug.print("Schema mismatch: {s}: {s}\n", .{ case.file, @errorName(err) });
                return error.UnexpectedSchemaError;
            }
        }
        const result: anyerror!void = if (case.collection) contract.validateFixtureSet(a, input) else blk: {
            const parsed = contract.parseInstance(a, input) catch |err| break :blk err;
            parsed.deinit();
            break :blk {};
        };
        if (result) |_| return error.UnexpectedContractAcceptance else |err| {
            if (!std.mem.eql(u8, case.zig_error, @errorName(err))) return error.UnexpectedContractError;
        }
    }
    var invalid_dir = try std.fs.cwd().openDir(root ++ "invalid", .{ .iterate = true });
    defer invalid_dir.close();
    var invalids = invalid_dir.iterate();
    var invalid_count: usize = 0;
    while (try invalids.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (!seen.contains(entry.name)) return error.UnlistedFixture;
        invalid_count += 1;
    }
    if (valid_count == 0 or invalid_count != manifest.value.len) return error.MissingFixture;
    std.debug.print("Zig schema subset and contract: {d} valid / {d} invalid fixtures and {d} host declarations passed\n", .{ valid_count, invalid_count, host_count });
}
pub fn main() !void {
    try checkFixtures(std.heap.page_allocator);
}
test "offline schema and contract agree on every fixture" {
    try checkFixtures(std.testing.allocator);
}
