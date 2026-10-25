// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
const std = @import("std");
const policy = @import("instance_capabilities.zig");
const registry = @import("deployment_registry.zig");

fn declaration(id: []const u8, profile: []const u8, backup_enabled: bool) registry.Instance {
    return .{
        .id = id,
        .profile_id = profile,
        .host = "opaque-host-key",
        .runtime = .{ .type = .systemd, .identity = "minecraft.service" },
        .game = .{ .version = "1.21.11", .mods = &.{.{ .id = "fabric-loader", .version = "0.18.1" }} },
        .backup = .{ .policy_ref = if (backup_enabled) "world-policy" else null },
        .capabilities = .{ .probe = .{ .enabled = true }, .lifecycle = .{ .start = true }, .backup = .{ .enabled = backup_enabled } },
    };
}
fn inventoryWith(i: registry.Instance, state: anytype) !registry.Snapshot {
    var inventory = registry.Registry.init(std.testing.allocator);
    defer inventory.deinit();
    try inventory.register(i);
    try inventory.observe(i.id, .{ .captured_at_ms = 1000, .source = .fixture, .state = state });
    return inventory.snapshot(std.testing.allocator);
}
fn facts() policy.Facts {
    return .{ .caller_authorized = true, .backend_available = true, .game_safe = true, .now_ms = 1100, .observation_max_age_ms = 1000 };
}

test "instance policy: four independent gates deny and then allow explicit selection" {
    var snapshot = try inventoryWith(declaration("minecraft-java", "minecraft-java", false), .active);
    defer snapshot.deinit();
    var f = facts();
    f.game_safe = null;
    var d = try policy.assess(&snapshot, "minecraft-java", .Start, f);
    try std.testing.expectEqual(policy.Outcome.unsafe, d.outcome);
    try std.testing.expect(d.capability_supported and d.caller_authorized and d.backend_available and !d.game_safe);
    f = facts();
    f.caller_authorized = false;
    d = try policy.assess(&snapshot, "minecraft-java", .Start, f);
    try std.testing.expectEqual(policy.Outcome.unauthorized, d.outcome);
    f = facts();
    f.backend_available = false;
    d = try policy.assess(&snapshot, "minecraft-java", .Start, f);
    try std.testing.expectEqual(policy.Outcome.backend_unavailable, d.outcome);
    f = facts();
    d = try policy.assess(&snapshot, "minecraft-java", .Start, f);
    try std.testing.expectEqual(policy.Outcome.eligible_not_executed, d.outcome);
    try std.testing.expect(d.eligible);
    try std.testing.expectEqualStrings("minecraft-java", d.instance_id);
    try std.testing.expectEqualStrings("opaque-host-key", d.host);
    try std.testing.expectEqualStrings("minecraft.service", d.runtime_identity);
}

test "instance policy: capability is independent from identity and same profile IDs" {
    var snapshot = try inventoryWith(declaration("minecraft-java", "minecraft-java", false), .active);
    defer snapshot.deinit();
    const denied = try policy.assess(&snapshot, "minecraft-java", .Restart, facts());
    try std.testing.expectEqual(policy.Outcome.unsupported, denied.outcome);
    const selected = try policy.assess(&snapshot, "minecraft-java", .Start, facts());
    try std.testing.expectEqualStrings("minecraft-java", selected.instance_id);
    try std.testing.expectEqualStrings("minecraft-java", (try snapshot.lookup(selected.instance_id)).profile_id);
}

test "instance policy: Minecraft Fabric backup is clean-stop-required, never inferred hot" {
    var active = try inventoryWith(declaration("mc-live", "minecraft-java", true), .active);
    defer active.deinit();
    var f = facts();
    // The typed instance/profile/mod declaration itself enforces the current
    // Minecraft/Fabric clean-stop rule; no caller may request a hot override.
    f.backup_mode = .hot_application_consistent;
    f.application_consistent_hook_verified = true;
    var d = try policy.assess(&active, "mc-live", .Backup, f);
    try std.testing.expectEqual(policy.BackupMode.clean_stop_required, d.backup_mode.?);
    try std.testing.expectEqual(policy.Outcome.needs_clean_stop, d.outcome);
    try std.testing.expect(!d.eligible);

    var stopped = try inventoryWith(declaration("mc-stopped", "minecraft-java", true), .inactive);
    defer stopped.deinit();
    d = try policy.assess(&stopped, "mc-stopped", .Backup, f);
    try std.testing.expectEqual(policy.Outcome.needs_clean_stop, d.outcome);
    f.clean_stop_verified = true;
    f.game_safe = false;
    d = try policy.assess(&stopped, "mc-stopped", .Backup, f);
    try std.testing.expectEqual(policy.Outcome.unsafe, d.outcome);
    try std.testing.expect(!d.game_safe and !d.eligible);
    f.game_safe = null;
    d = try policy.assess(&stopped, "mc-stopped", .Backup, f);
    try std.testing.expectEqual(policy.Outcome.unsafe, d.outcome);
    try std.testing.expect(!d.game_safe and !d.eligible);
    f.game_safe = true;
    d = try policy.assess(&stopped, "mc-stopped", .Backup, f);
    try std.testing.expectEqual(policy.Outcome.eligible_not_executed, d.outcome);
    try std.testing.expect(d.eligible and d.game_safe);
}

test "instance policy: unit identity validation follows the selected runtime backend" {
    var systemd_decl = declaration("unit-template", "game", false);
    systemd_decl.runtime.identity = "minecraft@main.service";
    var systemd_snapshot = try inventoryWith(systemd_decl, .active);
    defer systemd_snapshot.deinit();
    const valid_unit = try policy.assess(&systemd_snapshot, "unit-template", .Start, facts());
    try std.testing.expectEqual(policy.Outcome.eligible_not_executed, valid_unit.outcome);

    var podman_decl = declaration("podman-good", "game", false);
    podman_decl.runtime.type = .podman;
    podman_decl.runtime.identity = "minecraft_server-2";
    var podman_snapshot = try inventoryWith(podman_decl, .active);
    defer podman_snapshot.deinit();
    const valid_container = try policy.assess(&podman_snapshot, "podman-good", .Start, facts());
    try std.testing.expectEqual(policy.Outcome.eligible_not_executed, valid_container.outcome);

    podman_decl.id = "podman-invalid";
    podman_decl.runtime.identity = "minecraft@server";
    var invalid_snapshot = try inventoryWith(podman_decl, .active);
    defer invalid_snapshot.deinit();
    const invalid_container = try policy.assess(&invalid_snapshot, "podman-invalid", .Start, facts());
    try std.testing.expectEqual(policy.Outcome.invalid_backend_identity, invalid_container.outcome);

    var process_decl = declaration("raw-process", "game", false);
    process_decl.runtime.type = .process;
    process_decl.runtime.identity = "/usr/bin/java";
    var process_snapshot = try inventoryWith(process_decl, .active);
    defer process_snapshot.deinit();
    const unsupported_process = try policy.assess(&process_snapshot, "raw-process", .Start, facts());
    try std.testing.expectEqual(policy.Outcome.unsupported, unsupported_process.outcome);
    try std.testing.expect(unsupported_process.capability_supported);
    try std.testing.expect(!unsupported_process.backend_available);
}

test "instance policy: unknown observation state cannot satisfy game safety" {
    var snapshot = try inventoryWith(declaration("unknown-safe", "minecraft-java", true), .unknown);
    defer snapshot.deinit();
    var f = facts();
    f.adapter = .minecraft_fabric;
    f.clean_stop_verified = true;
    const decision = try policy.assess(&snapshot, "unknown-safe", .Backup, f);
    try std.testing.expectEqual(policy.Outcome.unsafe, decision.outcome);
    try std.testing.expect(!decision.game_safe and !decision.eligible);
}

test "instance policy: hot backups require a verified application hook and fresh evidence" {
    var snapshot = try inventoryWith(declaration("generic-world", "generic-game", true), .active);
    defer snapshot.deinit();
    var f = facts();
    f.backup_mode = .hot_application_consistent;
    var d = try policy.assess(&snapshot, "generic-world", .Backup, f);
    try std.testing.expectEqual(policy.Outcome.unsafe, d.outcome);
    f.application_consistent_hook_verified = true;
    d = try policy.assess(&snapshot, "generic-world", .Backup, f);
    try std.testing.expectEqual(policy.Outcome.eligible_not_executed, d.outcome);
    f.now_ms = 5000;
    d = try policy.assess(&snapshot, "generic-world", .Backup, f);
    try std.testing.expectEqual(policy.Outcome.stale_observation, d.outcome);
}

test "instance policy: metadata-only, externally managed and unsupported backup modes" {
    var snapshot = try inventoryWith(declaration("external-world", "generic-game", true), .inactive);
    defer snapshot.deinit();
    var f = facts();
    f.backup_mode = .metadata_only;
    var d = try policy.assess(&snapshot, "external-world", .Backup, f);
    try std.testing.expectEqual(policy.Outcome.metadata_only, d.outcome);
    try std.testing.expect(!d.eligible);
    f.backup_mode = .externally_managed;
    d = try policy.assess(&snapshot, "external-world", .Backup, f);
    try std.testing.expectEqual(policy.Outcome.externally_managed, d.outcome);
    try std.testing.expect(!d.eligible);
    f.backup_mode = .unsupported;
    d = try policy.assess(&snapshot, "external-world", .Backup, f);
    try std.testing.expectEqual(policy.Outcome.unsupported, d.outcome);
    try std.testing.expect(!d.capability_supported);
}

test "instance policy: rejects invalid runtime identity and unknown or future observations" {
    var i = declaration("bad-unit", "game", false);
    i.runtime.identity = "unit;bad.service";
    var bad = try inventoryWith(i, .active);
    defer bad.deinit();
    const invalid = try policy.assess(&bad, "bad-unit", .Start, facts());
    try std.testing.expectEqual(policy.Outcome.invalid_backend_identity, invalid.outcome);
    try std.testing.expectError(error.UnknownInstance, policy.assess(&bad, "missing", .Start, facts()));
    var f = facts();
    f.now_ms = 500;
    var valid = try inventoryWith(declaration("future", "game", false), .active);
    defer valid.deinit();
    const future = try policy.assess(&valid, "future", .Start, f);
    try std.testing.expectEqual(policy.Outcome.stale_observation, future.outcome);
}

test "instance policy: decisions do not mutate declaration or observation generation" {
    var inventory = registry.Registry.init(std.testing.allocator);
    defer inventory.deinit();
    try inventory.register(declaration("minecraft-survival", "minecraft-java", false));
    try inventory.observe("minecraft-survival", .{ .captured_at_ms = 1000, .source = .fixture, .state = .active });
    var before = try inventory.snapshot(std.testing.allocator);
    defer before.deinit();
    const before_id = (try before.lookup("minecraft-survival")).id;
    const decision = try policy.assess(&before, "minecraft-survival", .Start, facts());
    try std.testing.expect(decision.eligible);
    var after = try inventory.snapshot(std.testing.allocator);
    defer after.deinit();
    try std.testing.expectEqual(before.generation, after.generation);
    try std.testing.expectEqualStrings(before_id, (try after.lookup("minecraft-survival")).id);
    try std.testing.expectEqual(.active, (try after.evidence("minecraft-survival")).?.state);
}

test "instance policy: reviewed scenario fixture is complete and explicitly execution-free" {
    const a = std.testing.allocator;
    const bytes = try std.fs.cwd().readFileAlloc(a, "fixtures/backup-lifecycle-design/decisions.json", 1024 * 1024);
    defer a.free(bytes);
    const Fixture = struct { status: []const u8, cases: []struct { name: []const u8, dispatches_in_this_task: ?u8 = null, gsa_execution_authorized: ?bool = null } };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.status, "no execution") != null);
    try std.testing.expectEqual(@as(usize, 10), parsed.value.cases.len);
    for (parsed.value.cases) |case| {
        if (case.dispatches_in_this_task) |count| try std.testing.expectEqual(@as(u8, 0), count);
        if (case.gsa_execution_authorized) |allowed| try std.testing.expect(!allowed);
    }
}
