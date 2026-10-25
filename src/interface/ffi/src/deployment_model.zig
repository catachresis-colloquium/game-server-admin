// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
// Typed declarations, independent of JSON persistence and runtime observations.
const std = @import("std");
pub const Runtime = enum { systemd, podman, process };
pub const Protocol = enum { tcp, udp };
pub const ReadCapability = struct { enabled: bool = false, mode: enum { @"read-only" } = .@"read-only" };
pub const Capabilities = struct {
    probe: ReadCapability = .{},
    config: ReadCapability = .{},
    logs: ReadCapability = .{},
    lifecycle: struct { start: bool = false, stop: bool = false, restart: bool = false, update: bool = false } = .{},
    backup: struct { enabled: bool = false } = .{},
};
pub const Port = struct { protocol: Protocol, port: u16, purpose: []const u8 };
pub const Mod = struct { id: []const u8, version: []const u8 };
pub const Instance = struct {
    id: []const u8,
    profile_id: []const u8,
    // Inventory key only. Never interpreted as a shell/SSH destination.
    host: []const u8,
    runtime: struct { type: Runtime, identity: []const u8 },
    ports: []const Port = &.{},
    paths: struct { data: []const []const u8 = &.{}, config: []const []const u8 = &.{}, world: []const []const u8 = &.{} } = .{},
    game: struct { version: []const u8, update_channel: ?[]const u8 = null, mods: []const Mod = &.{} },
    resources: struct { memory: struct { minimum: ?[]const u8 = null, maximum: ?[]const u8 = null } = .{} } = .{},
    backup: struct { policy_ref: ?[]const u8 = null } = .{},
    capabilities: Capabilities = .{},
};

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128 or !std.ascii.isAlphanumeric(id[0])) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}
fn memory(text: []const u8) bool {
    if (text.len < 2 or text.len > 16 or text[0] < '1' or text[0] > '9') return false;
    for (text[0 .. text.len - 1]) |c| if (!std.ascii.isDigit(c)) return false;
    return std.mem.indexOfScalar(u8, "KMGT", text[text.len - 1]) != null;
}
pub fn validate(i: Instance) !void {
    if (!validId(i.id) or !validId(i.profile_id)) return error.InvalidIdentity;
    if (i.host.len == 0 or i.host.len > 1024 or i.runtime.identity.len == 0 or i.runtime.identity.len > 4096) return error.InvalidDeclaration;
    if (i.game.version.len == 0) return error.InvalidDeclaration;
    for (i.ports) |p| if (p.port == 0 or p.purpose.len == 0) return error.InvalidPort;
    inline for (.{ "data", "config", "world" }) |key| for (@field(i.paths, key)) |p| {
        if (p.len == 0 or p[0] != '/') return error.InvalidPath;
    };
    for (i.game.mods) |m| if (!validId(m.id) or m.version.len == 0) return error.InvalidDeclaration;
    if (i.resources.memory.minimum) |v| if (!memory(v)) return error.InvalidResourceLimit;
    if (i.resources.memory.maximum) |v| if (!memory(v)) return error.InvalidResourceLimit;
    if (i.backup.policy_ref) |v| if (!validId(v)) return error.InvalidPolicyReference;
}
fn optional(a: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |s| try a.dupe(u8, s) else null;
}
pub fn copy(a: std.mem.Allocator, i: Instance) !Instance {
    var out = i;
    out.id = try a.dupe(u8, i.id);
    out.profile_id = try a.dupe(u8, i.profile_id);
    out.host = try a.dupe(u8, i.host);
    out.runtime.identity = try a.dupe(u8, i.runtime.identity);
    const ports = try a.alloc(Port, i.ports.len);
    for (i.ports, 0..) |p, index| {
        ports[index] = p;
        ports[index].purpose = try a.dupe(u8, p.purpose);
    }
    out.ports = ports;
    inline for (.{ "data", "config", "world" }) |key| {
        const source = @field(i.paths, key);
        const paths = try a.alloc([]const u8, source.len);
        for (source, 0..) |p, n| paths[n] = try a.dupe(u8, p);
        @field(out.paths, key) = paths;
    }
    out.game.version = try a.dupe(u8, i.game.version);
    out.game.update_channel = try optional(a, i.game.update_channel);
    const mods = try a.alloc(Mod, i.game.mods.len);
    for (i.game.mods, 0..) |m, n| mods[n] = .{ .id = try a.dupe(u8, m.id), .version = try a.dupe(u8, m.version) };
    out.game.mods = mods;
    out.resources.memory.minimum = try optional(a, i.resources.memory.minimum);
    out.resources.memory.maximum = try optional(a, i.resources.memory.maximum);
    out.backup.policy_ref = try optional(a, i.backup.policy_ref);
    return out;
}
