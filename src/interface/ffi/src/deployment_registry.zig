// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
const std = @import("std");
pub const model = @import("deployment_model.zig");
pub const Instance = model.Instance;
const A = std.mem.Allocator;
pub const Observation = struct {
    captured_at_ms: i64,
    source: enum { systemd, probe, fixture },
    state: enum { active, inactive, failed, unknown },
    healthy: ?bool = null,
};
const Record = struct { arena: std.heap.ArenaAllocator, declaration: Instance, observation: ?Observation = null };
/// Caller-owned immutable-inventory view. Strings live until deinit; no pointer
/// aliases the registry. Declarations and observations are separate collections.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    generation: u64,
    declarations: []const Instance,
    observations: []const ?Observation,
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
    pub fn lookup(self: *const Snapshot, id: []const u8) !*const Instance {
        for (self.declarations) |*i| if (std.mem.eql(u8, i.id, id)) return i;
        return error.UnknownInstance;
    }
    pub fn evidence(self: *const Snapshot, id: []const u8) !?Observation {
        for (self.declarations, 0..) |i, n| if (std.mem.eql(u8, i.id, id)) return self.observations[n];
        return error.UnknownInstance;
    }
    pub fn resolveLegacy(self: *const Snapshot, profile_id: ?[]const u8) !*const Instance {
        var result: ?*const Instance = null;
        for (self.declarations) |*i| {
            if (profile_id) |profile| if (!std.mem.eql(u8, profile, i.profile_id)) continue;
            if (result != null) return error.AmbiguousInstance;
            result = i;
        }
        return result orelse error.UnknownInstance;
    }
};

/// One logical registry represents the whole managed estate, not a per-host
/// namespace. IDs are immutable: there is no upsert, rename or derived-ID API.
/// Persistence and authenticated host access are replaceable external boundaries.
pub const Registry = struct {
    allocator: A,
    mutex: std.Thread.Mutex = .{},
    records: std.StringHashMap(*Record),
    generation: u64 = 0,
    pub fn init(a: A) Registry {
        return .{ .allocator = a, .records = std.StringHashMap(*Record).init(a) };
    }
    // Caller must end concurrent use before destroying the registry.
    pub fn deinit(self: *Registry) void {
        var it = self.records.valueIterator();
        while (it.next()) |r| {
            r.*.arena.deinit();
            self.allocator.destroy(r.*);
        }
        self.records.deinit();
    }
    pub fn register(self: *Registry, declaration: Instance) !void {
        try model.validate(declaration);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.records.contains(declaration.id)) return error.DuplicateInstanceId;
        const generation = try std.math.add(u64, self.generation, 1);
        const record = try self.allocator.create(Record);
        errdefer self.allocator.destroy(record);
        record.* = .{ .arena = std.heap.ArenaAllocator.init(self.allocator), .declaration = undefined };
        errdefer record.arena.deinit();
        record.declaration = try model.copy(record.arena.allocator(), declaration);
        try self.records.put(record.declaration.id, record);
        self.generation = generation;
    }
    pub fn observe(self: *Registry, id: []const u8, observation: Observation) !void {
        if (observation.captured_at_ms < 0) return error.InvalidObservation;
        self.mutex.lock();
        defer self.mutex.unlock();
        const record = self.records.get(id) orelse return error.UnknownInstance;
        if (record.observation) |old| if (observation.captured_at_ms <= old.captured_at_ms) return error.StaleObservation;
        const generation = try std.math.add(u64, self.generation, 1);
        record.observation = observation;
        self.generation = generation;
    }
    pub fn snapshot(self: *Registry, allocator: A) !Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const declarations = try a.alloc(Instance, self.records.count());
        const observations = try a.alloc(?Observation, declarations.len);
        var it = self.records.valueIterator();
        var n: usize = 0;
        while (it.next()) |r| : (n += 1) {
            declarations[n] = try model.copy(a, r.*.declaration);
            observations[n] = r.*.observation;
        }
        return .{ .arena = arena, .generation = self.generation, .declarations = declarations, .observations = observations };
    }
};

fn testDeclaration(id: []const u8, profile: []const u8, host: []const u8, unit: []const u8) Instance {
    return .{ .id = id, .profile_id = profile, .host = host, .runtime = .{ .type = .systemd, .identity = unit }, .game = .{ .version = "fixture" } };
}
test "registry: explicit identity, profile multiplicity, global duplicates and singleton compatibility" {
    const a = std.testing.allocator;
    var r = Registry.init(a);
    defer r.deinit();
    var empty = try r.snapshot(a);
    defer empty.deinit();
    try std.testing.expectError(error.UnknownInstance, empty.resolveLegacy(null));
    try r.register(testDeclaration("survival", "minecraft-java", "local/inventory", "mc.service"));
    var single = try r.snapshot(a);
    defer single.deinit();
    try std.testing.expectEqualStrings("survival", (try single.resolveLegacy("minecraft-java")).id);
    try r.register(testDeclaration("creative", "minecraft-java", "remote/inventory", "creative.service"));
    try r.register(testDeclaration("minecraft-java", "minecraft-java", "other-host", "same-text.service"));
    try std.testing.expectError(error.DuplicateInstanceId, r.register(testDeclaration("survival", "other-profile", "other-host", "other.service")));
    var view = try r.snapshot(a);
    defer view.deinit();
    try std.testing.expectError(error.AmbiguousInstance, view.resolveLegacy("minecraft-java"));
    try std.testing.expectError(error.AmbiguousInstance, view.resolveLegacy(null));
    try std.testing.expectError(error.UnknownInstance, view.lookup("missing"));
    try std.testing.expectEqualStrings("local/inventory", (try view.lookup("survival")).host);
    try std.testing.expectEqualStrings("remote/inventory", (try view.lookup("creative")).host);
    try std.testing.expectEqualStrings("minecraft-java", (try view.lookup("minecraft-java")).profile_id);
    try std.testing.expectEqual(@as(usize, 3), view.declarations.len);
    // An earlier snapshot is coherent and does not grow with the registry.
    try std.testing.expectEqual(@as(usize, 1), single.declarations.len);
}
test "registry: owned declarations and timestamped observations never rewrite one another" {
    const a = std.testing.allocator;
    var r = Registry.init(a);
    defer r.deinit();
    var id = [_]u8{ 'm', 'c' };
    var version = [_]u8{ '1', '.', '0' };
    var input = testDeclaration(&id, "minecraft-java", "opaque host key", "mc.service");
    input.game.version = &version;
    input.paths.world = &.{"/srv/mc/world"};
    try r.register(input);
    @memset(&id, 'x');
    @memset(&version, 'x');
    try r.observe("mc", .{ .captured_at_ms = 100, .source = .fixture, .state = .active, .healthy = true });
    try std.testing.expectError(error.StaleObservation, r.observe("mc", .{ .captured_at_ms = 99, .source = .fixture, .state = .failed }));
    try std.testing.expectError(error.UnknownInstance, r.observe("unknown", .{ .captured_at_ms = 101, .source = .fixture, .state = .active }));
    var view = try r.snapshot(a);
    defer view.deinit();
    const i = try view.lookup("mc");
    try std.testing.expectEqualStrings("1.0", i.game.version);
    try std.testing.expectEqualStrings("/srv/mc/world", i.paths.world[0]);
    try std.testing.expect(i.resources.memory.minimum == null and i.resources.memory.maximum == null and i.backup.policy_ref == null);
    try std.testing.expectEqual(@as(i64, 100), (try view.evidence("mc")).?.captured_at_ms);
    try r.observe("mc", .{ .captured_at_ms = 101, .source = .systemd, .state = .inactive });
    try std.testing.expectEqual(.active, (try view.evidence("mc")).?.state);
}

test "registry: execute the eight reviewed selection scenarios against the typed API" {
    const a = std.testing.allocator;
    const bytes = try std.fs.cwd().readFileAlloc(a, "fixtures/instance-registry-design/cases.json", 1024 * 1024);
    defer a.free(bytes);
    const Entry = struct { id: []const u8, profile_id: []const u8, host: []const u8, runtime: struct { type: model.Runtime, identity: []const u8 } };
    const Case = struct {
        entries: []Entry,
        register: ?Entry = null,
        request: ?struct { instance_id: ?[]const u8 = null, profile_id: ?[]const u8 = null, legacy_profile_lookup: ?[]const u8 = null } = null,
        expected: struct { category: enum { found, not_found, ambiguous, duplicate, profile_found }, instance_id: ?[]const u8 = null, host: ?[]const u8 = null },
    };
    const parsed = try std.json.parseFromSlice(struct { cases: []Case }, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 8), parsed.value.cases.len);
    for (parsed.value.cases) |case| {
        var r = Registry.init(a);
        defer r.deinit();
        for (case.entries) |entry| try r.register(testDeclaration(entry.id, entry.profile_id, entry.host, entry.runtime.identity));
        if (case.register) |entry| {
            try std.testing.expectError(error.DuplicateInstanceId, r.register(testDeclaration(entry.id, entry.profile_id, entry.host, entry.runtime.identity)));
            var view = try r.snapshot(a);
            defer view.deinit();
            try std.testing.expectEqualStrings(case.entries[0].host, (try view.lookup(entry.id)).host);
            continue;
        }
        var view = try r.snapshot(a);
        defer view.deinit();
        const request = case.request.?;
        if (request.legacy_profile_lookup) |profile| {
            var profiles = @import("game_profiles.zig").ProfileRegistry.init(a);
            defer profiles.deinit();
            try std.testing.expectEqual(@as(u32, 18), try profiles.loadFromDirectory("profiles"));
            try std.testing.expect(profiles.getProfile(profile) != null);
            try std.testing.expectEqual(@as(usize, 2), view.declarations.len);
            continue;
        }
        const selection = if (request.instance_id) |id| view.lookup(id) else view.resolveLegacy(request.profile_id);
        switch (case.expected.category) {
            .found => {
                const selected = try selection;
                try std.testing.expectEqualStrings(case.expected.instance_id.?, selected.id);
                if (case.expected.host) |host| try std.testing.expectEqualStrings(host, selected.host);
            },
            .not_found => try std.testing.expectError(error.UnknownInstance, selection),
            .ambiguous => try std.testing.expectError(error.AmbiguousInstance, selection),
            else => return error.UnexpectedCase,
        }
    }
}
