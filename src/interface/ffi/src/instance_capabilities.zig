// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
const std = @import("std");
const registry = @import("deployment_registry.zig");
const actions = @import("server_actions.zig");

pub const Operation = actions.ActionKind;
pub const BackupMode = enum { unsupported, metadata_only, hot_application_consistent, clean_stop_required, externally_managed };
pub const Outcome = enum { eligible_not_executed, unsupported, unauthorized, backend_unavailable, unsafe, stale_observation, invalid_backend_identity, metadata_only, externally_managed, needs_clean_stop };
pub const GameAdapter = enum { generic, minecraft_fabric };

/// Trusted policy inputs are computed separately from the instance declaration.
/// Unknown/default values fail closed; this module has no execution callback.
pub const Facts = struct {
    caller_authorized: bool = false,
    backend_available: bool = false,
    game_safe: ?bool = null,
    adapter: GameAdapter = .generic,
    backup_mode: BackupMode = .unsupported,
    now_ms: i64,
    observation_max_age_ms: i64 = 30000,
    clean_stop_verified: bool = false,
    application_consistent_hook_verified: bool = false,
};
pub const Decision = struct {
    // Borrowed from the supplied snapshot and valid only while it remains alive.
    instance_id: []const u8,
    host: []const u8,
    runtime_identity: []const u8,
    operation: Operation,
    capability_supported: bool,
    caller_authorized: bool,
    backend_available: bool,
    game_safe: bool,
    backup_mode: ?BackupMode = null,
    outcome: Outcome,
    eligible: bool = false,
};

fn advertised(i: *const registry.Instance, operation: Operation) bool {
    return switch (operation) {
        .Start => i.capabilities.lifecycle.start,
        .Stop => i.capabilities.lifecycle.stop,
        .Restart => i.capabilities.lifecycle.restart,
        .Update => i.capabilities.lifecycle.update,
        .Backup => i.capabilities.backup.enabled,
        .Status => i.capabilities.probe.enabled,
        .Logs => i.capabilities.logs.enabled,
        .ValidateConfig => i.capabilities.config.enabled,
    };
}
const IdentityCheck = enum { valid, invalid, runtime_unsupported };
fn systemdUnitValid(name: []const u8) bool {
    if (name.len < 9 or name.len > 255 or !std.mem.endsWith(u8, name, ".service") or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == '@' or c == ':')) return false;
    return true;
}
fn podmanContainerValid(name: []const u8) bool {
    if (name.len == 0 or name.len > 255 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    return true;
}
fn identityCheck(i: *const registry.Instance) IdentityCheck {
    return switch (i.runtime.type) {
        .systemd => if (systemdUnitValid(i.runtime.identity)) .valid else .invalid,
        .podman => if (podmanContainerValid(i.runtime.identity)) .valid else .invalid,
        .process => .runtime_unsupported,
    };
}
fn observationFresh(snapshot: *const registry.Snapshot, id: []const u8, facts: Facts) !bool {
    if (facts.now_ms < 0 or facts.observation_max_age_ms < 0) return false;
    const observation = (try snapshot.evidence(id)) orelse return false;
    if (observation.captured_at_ms > facts.now_ms) return false;
    return facts.now_ms - observation.captured_at_ms <= facts.observation_max_age_ms;
}
fn backupMode(i: *const registry.Instance, facts: Facts) BackupMode {
    const fabric_mod = for (i.game.mods) |mod| {
        if (std.mem.eql(u8, mod.id, "fabric-loader")) break true;
    } else false;
    if (facts.adapter == .minecraft_fabric or (std.mem.eql(u8, i.profile_id, "minecraft-java") and fabric_mod)) return .clean_stop_required;
    return facts.backup_mode;
}

/// Resolve only by explicit immutable instance ID. Produces an eligibility
/// decision; it never dispatches, mutates registry state or performs I/O.
pub fn assess(snapshot: *const registry.Snapshot, instance_id: []const u8, operation: Operation, facts: Facts) !Decision {
    const instance = try snapshot.lookup(instance_id);
    const capability = advertised(instance, operation);
    const identity = identityCheck(instance);
    const fresh = try observationFresh(snapshot, instance_id, facts);
    const observation = (try snapshot.evidence(instance_id)) orelse null;
    const observed_safe = facts.game_safe == true and fresh and observation != null and observation.?.state != .unknown;
    var decision = Decision{
        .instance_id = instance.id,
        .host = instance.host,
        .runtime_identity = instance.runtime.identity,
        .operation = operation,
        .capability_supported = capability,
        .caller_authorized = facts.caller_authorized,
        .backend_available = facts.backend_available,
        .game_safe = observed_safe,
        .outcome = .unsupported,
    };
    if (!capability) return decision;
    if (!facts.caller_authorized) {
        decision.outcome = .unauthorized;
        return decision;
    }
    if (identity == .runtime_unsupported) {
        decision.backend_available = false;
        decision.outcome = .unsupported;
        return decision;
    }
    if (!facts.backend_available) {
        decision.outcome = .backend_unavailable;
        return decision;
    }
    if (identity == .invalid) {
        decision.outcome = .invalid_backend_identity;
        return decision;
    }
    if (operation == .Backup) {
        const mode = backupMode(instance, facts);
        decision.backup_mode = mode;
        switch (mode) {
            .unsupported => {
                decision.capability_supported = false;
                decision.outcome = .unsupported;
                return decision;
            },
            .metadata_only => {
                decision.outcome = .metadata_only;
                return decision;
            },
            .externally_managed => {
                decision.outcome = .externally_managed;
                return decision;
            },
            .hot_application_consistent => {
                if (!fresh or !observed_safe or !facts.application_consistent_hook_verified) {
                    decision.outcome = if (!fresh) .stale_observation else .unsafe;
                    return decision;
                }
            },
            .clean_stop_required => {
                if (!fresh) {
                    decision.outcome = .stale_observation;
                    return decision;
                }
                if (!observed_safe) {
                    decision.outcome = .unsafe;
                    return decision;
                }
                const latest = observation.?;
                if (latest.state != .inactive or !facts.clean_stop_verified) {
                    decision.outcome = .needs_clean_stop;
                    return decision;
                }
            },
        }
    } else if (!fresh) {
        decision.outcome = .stale_observation;
        return decision;
    } else if (!observed_safe) {
        decision.outcome = .unsafe;
        return decision;
    }
    decision.outcome = .eligible_not_executed;
    decision.eligible = true;
    return decision;
}

test {
    _ = @import("instance_capabilities_test.zig");
}
