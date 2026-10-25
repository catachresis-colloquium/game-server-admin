// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
// Explicit operator-owned deployment-instance document loader.
const std = @import("std");
const contract = @import("deployment_instance_contract.zig");
const model = @import("deployment_model.zig");
const registry = @import("deployment_registry.zig");

pub const MAX_DOCUMENT_BYTES = 256 * 1024;

/// Parse and register exactly one document. `expected_id` is mandatory at the
/// call boundary; it must equal the document's independently declared ID.
pub fn loadDocument(a: std.mem.Allocator, target: *registry.Registry, expected_id: []const u8, bytes: []const u8) !void {
    if (expected_id.len == 0) return error.InstanceIdRequired;
    if (bytes.len > MAX_DOCUMENT_BYTES) return error.DocumentTooLarge;
    const parsed = try contract.parseInstance(a, bytes);
    defer parsed.deinit();
    const declared = parsed.value;
    if (!std.mem.eql(u8, expected_id, declared.id)) return error.InstanceIdMismatch;
    var temporary = std.heap.ArenaAllocator.init(a);
    defer temporary.deinit();
    const scratch = temporary.allocator();

    const runtime = std.meta.stringToEnum(model.Runtime, declared.runtime.type) orelse return error.InvalidRuntime;
    const ports = try scratch.alloc(model.Port, declared.ports.len);
    for (declared.ports, 0..) |source, index| {
        const protocol = std.meta.stringToEnum(model.Protocol, source.protocol) orelse return error.InvalidPort;
        ports[index] = .{ .protocol = protocol, .port = @intCast(source.port), .purpose = source.purpose };
    }
    const mods = try scratch.alloc(model.Mod, declared.game.mods.len);
    for (declared.game.mods, 0..) |source, index| mods[index] = .{ .id = source.id, .version = source.version };
    const declaration: model.Instance = .{
        .id = declared.id,
        .profile_id = declared.profile_id,
        .host = declared.host,
        .runtime = .{ .type = runtime, .identity = declared.runtime.identity },
        .ports = ports,
        .paths = .{ .data = declared.paths.data, .config = declared.paths.config, .world = declared.paths.world },
        .game = .{ .version = declared.game.version, .update_channel = declared.game.update_channel, .mods = mods },
        .resources = .{ .memory = .{ .minimum = declared.resources.memory.minimum, .maximum = declared.resources.memory.maximum } },
        .backup = .{ .policy_ref = declared.backup.policy_ref },
        .capabilities = .{
            .probe = .{ .enabled = declared.capabilities.probe.enabled },
            .config = .{ .enabled = declared.capabilities.config.enabled },
            .logs = .{ .enabled = declared.capabilities.logs.enabled },
            .lifecycle = .{
                .start = declared.capabilities.lifecycle.start,
                .stop = declared.capabilities.lifecycle.stop,
                .restart = declared.capabilities.lifecycle.restart,
                .update = declared.capabilities.lifecycle.update,
            },
            .backup = .{ .enabled = declared.capabilities.backup.enabled },
        },
    };
    try target.register(declaration);
}

/// Load one explicitly named instance from an operator-controlled file.
/// No directory scan, profile lookup, or fallback is performed.
pub fn loadFile(a: std.mem.Allocator, target: *registry.Registry, expected_id: []const u8, path: []const u8) !void {
    const bytes = try std.fs.cwd().readFileAlloc(a, path, MAX_DOCUMENT_BYTES);
    defer a.free(bytes);
    try loadDocument(a, target, expected_id, bytes);
}

test "instance loader registers only the requested explicit document" {
    const a = std.testing.allocator;
    const bytes = try std.fs.cwd().readFileAlloc(a, "fixtures/deployment-instances/valid/minecraft-survival.json", MAX_DOCUMENT_BYTES);
    defer a.free(bytes);
    var r = registry.Registry.init(a);
    defer r.deinit();
    try std.testing.expectError(error.InstanceIdRequired, loadDocument(a, &r, "", bytes));
    try std.testing.expectError(error.InstanceIdMismatch, loadDocument(a, &r, "minecraft-creative", bytes));
    try loadDocument(a, &r, "minecraft-survival", bytes);
    try std.testing.expectError(error.DuplicateInstanceId, loadDocument(a, &r, "minecraft-survival", bytes));
    var view = try r.snapshot(a);
    defer view.deinit();
    const instance = try view.lookup("minecraft-survival");
    try std.testing.expectEqualStrings("minecraft-java", instance.profile_id);
    try std.testing.expect(!instance.capabilities.lifecycle.start and !instance.capabilities.lifecycle.stop);
}

test "instance loader preserves strict unknown-field rejection and size limit" {
    var r = registry.Registry.init(std.testing.allocator);
    defer r.deinit();
    try std.testing.expectError(error.DocumentTooLarge, loadDocument(std.testing.allocator, &r, "minecraft-survival", &[_]u8{0} ** (MAX_DOCUMENT_BYTES + 1)));
    try std.testing.expectError(error.MissingField, loadDocument(std.testing.allocator, &r, "minecraft-survival", "{}"));
}

test "instance loader accepts the operator-owned production instance definition" {
    const a = std.testing.allocator;
    var r = registry.Registry.init(a);
    defer r.deinit();
    try loadFile(a, &r, "minecraft-survival", "deployment-instances/wizardly-hellman/minecraft-survival.json");
    var view = try r.snapshot(a);
    defer view.deinit();
    const i = try view.lookup("minecraft-survival");
    try std.testing.expectEqualStrings("wizardly-hellman", i.host);
    try std.testing.expectEqualStrings("minecraft.service", i.runtime.identity);
    try std.testing.expectEqual(@as(usize, 5), i.game.mods.len);
    try std.testing.expect(i.resources.memory.minimum != null and i.resources.memory.maximum != null);
    try std.testing.expectEqualStrings("1G", i.resources.memory.minimum.?);
    try std.testing.expectEqualStrings("2G", i.resources.memory.maximum.?);
    try std.testing.expect(!i.capabilities.lifecycle.start and !i.capabilities.backup.enabled);
}
