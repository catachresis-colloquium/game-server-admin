// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
//
// Game Server Admin — Core lifecycle, error handling, and exported C ABI entry
// points.  Implements the FFI surface declared in src/interface/abi/Foreign.idr.
//
// Thread-local error storage, result codes, and the GsaHandle type live here.
// Every other module imports this as its root dependency.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── sibling modules ──────────────────────────────────────────────────────────
// These are `pub const` so their `pub export fn` declarations are included
// in the shared library's symbol table.
pub const probe = @import("probe.zig");
pub const config_extract = @import("config_extract.zig");
pub const a2ml_emit = @import("a2ml_emit.zig");
pub const verisimdb_client = @import("verisimdb_client.zig");
pub const server_actions = @import("server_actions.zig");
pub const game_profiles = @import("game_profiles.zig");
pub const deployment_registry = @import("deployment_registry.zig");
pub const fleet_dispatch = @import("fleet_dispatch.zig");
pub const instance_capabilities = @import("instance_capabilities.zig");
pub const profile_contract = @import("profile_contract.zig"); // draft fixture validator; not part of the C ABI or legacy registry

test {
    // Include the fixture validator's test declarations in the normal unit-test root.
    _ = @import("profile_contract.zig");
    _ = @import("deployment_registry.zig");
    _ = @import("fleet_dispatch.zig");
    _ = @import("instance_capabilities.zig");
    _ = @import("deployment_schema_check.zig");
    _ = @import("deployment_instance_contract.zig"); // strict contract parser used by fixtures and operator loader
    _ = @import("minecraft_systemd_inspect.zig"); // allowlisted projection shared by fixture/live collector
    _ = @import("deployment_instance_loader.zig");
    _ = @import("minecraft_live_collector.zig");
    _ = @import("cryofall_live_collector.zig");
}
pub const groove_client = @import("groove_client.zig");
pub const steam_client = @import("steam_client.zig");
pub const abi_layout = @import("abi_layout.zig"); // canonical wire structs + Zig↔Idris cross-check
pub const abi_serde = @import("abi_serde.zig"); // binary ABI emitters + offset readers
pub const http_capability = @import("http_capability.zig"); // outbound HTTP capability gateway (deadlines)

// Force the linker to include all exported functions from submodules.
// Without these references, Zig's linker may dead-strip the `pub export fn`
// declarations since nothing in main.zig calls them directly.
comptime {
    _ = &probe.gossamer_gsa_probe;
    _ = &probe.gossamer_gsa_fingerprint;
    _ = &config_extract.gossamer_gsa_extract_config;
    _ = &a2ml_emit.gossamer_gsa_a2ml_emit;
    _ = &a2ml_emit.gossamer_gsa_a2ml_parse;
    _ = &verisimdb_client.gossamer_gsa_verisimdb_store;
    _ = &verisimdb_client.gossamer_gsa_verisimdb_query;
    _ = &verisimdb_client.gossamer_gsa_verisimdb_health;
    _ = &verisimdb_client.gossamer_gsa_verisimdb_drift;
    _ = &server_actions.gossamer_gsa_server_action;
    _ = &server_actions.gossamer_gsa_get_logs;
    _ = &server_actions.gossamer_gsa_run_script;
    _ = &server_actions.gossamer_gsa_write_server_config;
    _ = &game_profiles.gossamer_gsa_load_profiles;
    _ = &game_profiles.gossamer_gsa_list_profiles;
    _ = &game_profiles.gossamer_gsa_add_profile;
    _ = &groove_client.gossamer_gsa_groove_discover;
    _ = &groove_client.gossamer_gsa_groove_status;
    _ = &groove_client.gossamer_gsa_groove_alert;
    _ = &groove_client.gossamer_gsa_groove_tts_alert;
    _ = &steam_client.gossamer_gsa_steam_resolve_vanity;
    _ = &steam_client.gossamer_gsa_steam_player_info;
    _ = &steam_client.gossamer_gsa_steam_get_result;
    // Binary ABI: offset readers + array/pointer helpers consumed by GSA.ABI.Foreign.
    _ = &abi_serde.gossamer_gsa_read_int;
    _ = &abi_serde.gossamer_gsa_read_double;
    _ = &abi_serde.gossamer_gsa_read_ptr;
    _ = &abi_serde.gossamer_gsa_read_string;
    _ = &abi_serde.gossamer_gsa_array_len;
    _ = &abi_serde.gossamer_gsa_array_get_string;
    _ = &abi_serde.gossamer_gsa_is_null;
    _ = &abi_serde.gossamer_gsa_free;
    _ = &abi_serde.gossamer_gsa_apply_config;
    _ = &abi_serde.gossamer_gsa_close_handle;
    _ = &abi_serde.gossamer_gsa_drift_struct;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════════

/// Semantic version of the FFI layer — keep in sync with build.zig
pub const VERSION: [:0]const u8 = "0.9.0";

/// Human-readable build tag
pub const BUILD_INFO: [:0]const u8 = "libgsa 0.9.0 (Zig " ++ @import("builtin").zig_version_string ++ ")";

// ═══════════════════════════════════════════════════════════════════════════════
// Result codes — must match GameServerAdmin.ABI.Types.Result (Idris2)
// ═══════════════════════════════════════════════════════════════════════════════

/// FFI result codes.  The integer values are contractual; the Idris2 ABI layer
/// converts between these and the dependent-type Result via `resultToInt`.
///
/// Codes 0-12 mirror the original (stable) Idris constructors; 13-17 are the
/// Zig-side failure modes added to `Types.idr` in the same change.  The
/// mapping is machine-checked: `scripts/gen_result_codes.zig` parses
/// `Types.idr` into `result_codes_expected.zig`, and the comptime block below
/// the enum turns any name/value/cardinality drift into a compile error.
pub const GsaResult = enum(c_int) {
    ok = 0,
    err = 1,
    invalid_param = 2,
    out_of_memory = 3,
    null_pointer = 4,
    /// A linear resource was used after consumption.
    already_consumed = 5,
    /// A linear resource went out of scope without being consumed.
    resource_leaked = 6,
    /// A handle was closed more than once.
    double_free = 7,
    probe_timeout = 8,
    connection_refused = 9,
    auth_failed = 10,
    config_parse_error = 11,
    /// VeriSimDB instance is unreachable or not running.
    verisimdb_unavailable = 12,
    not_initialized = 13,
    protocol_error = 14,
    io_error = 15,
    permission_denied = 16,
    not_found = 17,
    unsupported_operation = 18,
};

// Cross-language contract check: every (constructor, code) pair extracted from
// Types.idr must exist here with the same value, and the counts must match.
// See scripts/gen_result_codes.zig (regenerate after editing Types.idr).
const result_codes_expected = @import("result_codes_expected.zig");
comptime {
    const fields = @typeInfo(GsaResult).@"enum".fields;
    if (fields.len != result_codes_expected.all.len) {
        @compileError(std.fmt.comptimePrint(
            "GsaResult has {d} variants but Types.idr declares {d} — regenerate result_codes_expected.zig and reconcile",
            .{ fields.len, result_codes_expected.all.len },
        ));
    }
    for (result_codes_expected.all) |entry| {
        if (!@hasField(GsaResult, entry.zig_field)) {
            @compileError("GsaResult is missing variant '" ++ entry.zig_field ++
                "' declared in Types.idr as '" ++ entry.idris_ctor ++ "'");
        }
        const actual = @intFromEnum(@field(GsaResult, entry.zig_field));
        if (actual != entry.code) {
            @compileError(std.fmt.comptimePrint(
                "GsaResult.{s} = {d} but Types.idr declares {s} = {d}",
                .{ entry.zig_field, actual, entry.idris_ctor, entry.code },
            ));
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Thread-local error buffer
// ═══════════════════════════════════════════════════════════════════════════════

/// Fixed-size thread-local buffer for the last error message.
/// Callers retrieve it via `gossamer_gsa_last_error`.
threadlocal var last_error_buf: [512:0]u8 = [_:0]u8{0} ** 512;
threadlocal var last_error_len: usize = 0;

/// Write an error message into the thread-local buffer.
pub fn setError(comptime fmt: []const u8, args: anytype) void {
    var buf_stream = std.io.fixedBufferStream(&last_error_buf);
    buf_stream.writer().print(fmt, args) catch {};
    last_error_len = buf_stream.pos;
    // ensure NUL terminator
    if (last_error_len < last_error_buf.len) {
        last_error_buf[last_error_len] = 0;
    }
}

/// Write a plain string error.
pub fn setErrorStr(msg: []const u8) void {
    const copy_len = @min(msg.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..copy_len], msg[0..copy_len]);
    last_error_buf[copy_len] = 0;
    last_error_len = copy_len;
}

/// Clear the thread-local error.
pub fn clearError() void {
    last_error_buf[0] = 0;
    last_error_len = 0;
}

// ═══════════════════════════════════════════════════════════════════════════════
// GsaHandle — opaque library state
// ═══════════════════════════════════════════════════════════════════════════════

/// Connection state for a single tracked server.
pub const ConnectionState = struct {
    host: []const u8,
    port: u16,
    protocol: probe.ProbeProtocol,
    last_seen_ms: i64,
    healthy: bool,
};

/// First value ever returned as a probe handle id. Deliberately disjoint from
/// the GsaResult code space (0-17) so a success value can never be mistaken
/// for an error code by an FFI consumer.
pub const FIRST_HANDLE_ID: c_int = 1000;

/// Number of recently-closed handle ids remembered for double-close
/// detection. Bounded: once more than this many closes have happened, the
/// oldest tombstones are forgotten and a very late double-close reports
/// `not_found` instead of `double_free` (still an error, just less specific).
pub const CLOSED_HANDLE_TOMBSTONES: usize = 64;

/// Outcome of consuming or inspecting a per-probe handle id.
pub const HandleUse = enum { live, consumed, unknown };

/// Core handle carrying all mutable state.
pub const GsaHandle = struct {
    initialized: bool,
    allocator: Allocator,
    profile_registry: game_profiles.ProfileRegistry,
    deployments: deployment_registry.Registry,
    verisimdb_url: []const u8,
    active_connections: std.StringHashMap(ConnectionState),
    /// Per-probe linear handles: id -> owned server-id string. This is what
    /// makes the Idris ServerHandle linearity real on the Zig side.
    open_handles: std.AutoHashMap(c_int, []const u8),
    next_handle_id: c_int,
    /// Ring buffer of recently closed ids (double-close detection).
    closed_ring: [CLOSED_HANDLE_TOMBSTONES]c_int,
    closed_count: usize,

    /// Create a new GsaHandle.  Caller owns the returned pointer.
    pub fn create(
        allocator: Allocator,
        verisimdb_url: []const u8,
        profiles_dir: []const u8,
    ) !*GsaHandle {
        const self = try allocator.create(GsaHandle);
        errdefer allocator.destroy(self);

        self.* = .{
            .initialized = false,
            .allocator = allocator,
            .profile_registry = game_profiles.ProfileRegistry.init(allocator),
            .deployments = deployment_registry.Registry.init(allocator),
            .verisimdb_url = try allocator.dupe(u8, verisimdb_url),
            .active_connections = std.StringHashMap(ConnectionState).init(allocator),
            .open_handles = std.AutoHashMap(c_int, []const u8).init(allocator),
            .next_handle_id = FIRST_HANDLE_ID,
            .closed_ring = [_]c_int{0} ** CLOSED_HANDLE_TOMBSTONES,
            .closed_count = 0,
        };

        // Load game profiles from the supplied directory
        if (profiles_dir.len > 0) {
            _ = self.profile_registry.loadFromDirectory(profiles_dir) catch |load_err| {
                setError("profile load failed: {s}", .{@errorName(load_err)});
                // non-fatal — we can still operate without profiles
            };
        }

        self.initialized = true;
        return self;
    }

    /// Release all owned memory.
    pub fn destroy(self: *GsaHandle) void {
        const alloc = self.allocator;
        self.profile_registry.deinit();
        self.deployments.deinit();
        alloc.free(self.verisimdb_url);

        var it = self.active_connections.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.host);
        }
        self.active_connections.deinit();

        var hit = self.open_handles.valueIterator();
        while (hit.next()) |server_id| {
            alloc.free(server_id.*);
        }
        self.open_handles.deinit();

        self.initialized = false;
        alloc.destroy(self);
    }

    /// Allocate a fresh probe handle id bound to `server_id`.
    pub fn openHandle(self: *GsaHandle, server_id: []const u8) !c_int {
        const id_owned = try self.allocator.dupe(u8, server_id);
        errdefer self.allocator.free(id_owned);

        const id = self.next_handle_id;
        try self.open_handles.put(id, id_owned);
        self.next_handle_id += 1;
        return id;
    }

    /// Close a probe handle. Distinguishes a double-close from a handle that
    /// never existed (within the bounded tombstone window).
    pub fn closeHandle(self: *GsaHandle, id: c_int) HandleUse {
        if (self.open_handles.fetchRemove(id)) |kv| {
            self.allocator.free(kv.value);
            self.closed_ring[self.closed_count % CLOSED_HANDLE_TOMBSTONES] = id;
            self.closed_count += 1;
            return .live;
        }
        return self.lookupClosed(id);
    }

    /// Inspect a handle id without consuming it.
    pub fn useHandle(self: *GsaHandle, id: c_int) HandleUse {
        if (self.open_handles.contains(id)) return .live;
        return self.lookupClosed(id);
    }

    /// Server id bound to a live handle, or null.
    pub fn handleServerId(self: *GsaHandle, id: c_int) ?[]const u8 {
        return self.open_handles.get(id);
    }

    fn lookupClosed(self: *GsaHandle, id: c_int) HandleUse {
        const remembered = @min(self.closed_count, CLOSED_HANDLE_TOMBSTONES);
        for (self.closed_ring[0..remembered]) |closed_id| {
            if (closed_id == id) return .consumed;
        }
        return .unknown;
    }

    /// Register or update a server connection.
    pub fn trackServer(self: *GsaHandle, server_id: []const u8, state: ConnectionState) !void {
        const id_owned = try self.allocator.dupe(u8, server_id);
        errdefer self.allocator.free(id_owned);

        const host_owned = try self.allocator.dupe(u8, state.host);
        errdefer self.allocator.free(host_owned);

        var owned_state = state;
        owned_state.host = host_owned;

        if (self.active_connections.getPtr(server_id)) |existing| {
            self.allocator.free(existing.host);
            existing.* = owned_state;
            self.allocator.free(id_owned);
        } else {
            try self.active_connections.put(id_owned, owned_state);
        }
    }

    /// Retrieve tracked connection state for a server.
    pub fn getConnection(self: *GsaHandle, server_id: []const u8) ?ConnectionState {
        return self.active_connections.get(server_id);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Global singleton (one per process; guarded by a mutex for multi-threaded use)
// ═══════════════════════════════════════════════════════════════════════════════

var global_handle: ?*GsaHandle = null;
var global_mutex: std.Thread.Mutex = .{};

/// Obtain the global handle, or null if not initialised.
pub fn getGlobalHandle() ?*GsaHandle {
    global_mutex.lock();
    defer global_mutex.unlock();
    return global_handle;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Exported C ABI functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Initialise the library.
///
/// `verisimdb_url` — base URL of the dedicated VeriSimDB instance (e.g.
///     "http://localhost:7820").
/// `profiles_dir` — filesystem path to directory containing .a2ml game
///     profiles.
///
/// Returns 0 on success, a positive GsaResult code on failure.
pub export fn gossamer_gsa_init(
    verisimdb_url: [*:0]const u8,
    profiles_dir: [*:0]const u8,
) callconv(.c) c_int {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_handle != null) {
        setErrorStr("already initialized");
        return @intFromEnum(GsaResult.err);
    }

    const allocator = std.heap.c_allocator;
    const url_slice = std.mem.span(verisimdb_url);
    const dir_slice = std.mem.span(profiles_dir);

    const handle = GsaHandle.create(allocator, url_slice, dir_slice) catch |e| {
        setError("init failed: {s}", .{@errorName(e)});
        return @intFromEnum(GsaResult.out_of_memory);
    };

    global_handle = handle;
    clearError();
    return @intFromEnum(GsaResult.ok);
}

/// Shut down the library and release all resources.
///
/// Returns 0 on success, a positive GsaResult code on failure.
pub export fn gossamer_gsa_shutdown() callconv(.c) c_int {
    global_mutex.lock();
    defer global_mutex.unlock();

    const handle = global_handle orelse {
        setErrorStr("not initialized");
        return @intFromEnum(GsaResult.not_initialized);
    };

    handle.destroy();
    global_handle = null;
    clearError();
    return @intFromEnum(GsaResult.ok);
}

/// Retrieve the last error message.
///
/// Returns a NUL-terminated string in thread-local storage.  The pointer
/// remains valid until the next FFI call on the same thread.
pub export fn gossamer_gsa_last_error() callconv(.c) [*:0]const u8 {
    return &last_error_buf;
}

/// Library version string (e.g. "0.1.0").
pub export fn gossamer_gsa_version() callconv(.c) [*:0]const u8 {
    return VERSION.ptr;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Unit tests
// ═══════════════════════════════════════════════════════════════════════════════

test "GsaResult sanity (cross-language check is the comptime block above)" {
    // The authoritative Idris2 cross-check is the comptime block after the
    // enum definition, driven by result_codes_expected.zig.  This test only
    // pins the two values other modules rely on unconditionally.
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(GsaResult.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(GsaResult.err));
    try std.testing.expectEqual(@as(usize, 19), @typeInfo(GsaResult).@"enum".fields.len);
}

test "error buffer round-trip" {
    setErrorStr("test error 42");
    const msg = std.mem.span(gossamer_gsa_last_error());
    try std.testing.expectEqualStrings("test error 42", msg);

    clearError();
    const empty = std.mem.span(gossamer_gsa_last_error());
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "version string" {
    const ver = std.mem.span(gossamer_gsa_version());
    try std.testing.expectEqualStrings(VERSION, ver);
}

test "GsaHandle create and destroy" {
    const allocator = std.testing.allocator;
    const handle = try GsaHandle.create(allocator, "http://localhost:7820", "");
    defer handle.destroy();

    try std.testing.expect(handle.initialized);
    try std.testing.expectEqualStrings("http://localhost:7820", handle.verisimdb_url);
}

test "GsaHandle track server" {
    const allocator = std.testing.allocator;
    const handle = try GsaHandle.create(allocator, "http://localhost:7820", "");
    defer handle.destroy();

    try handle.trackServer("mc-1", .{
        .host = "192.168.1.10",
        .port = 25565,
        .protocol = .MinecraftQuery,
        .last_seen_ms = 1000,
        .healthy = true,
    });

    const conn = handle.getConnection("mc-1") orelse return error.NotFound;
    try std.testing.expectEqual(@as(u16, 25565), conn.port);
    try std.testing.expect(conn.healthy);
}

test "handle lifecycle: open, use, close, double-close, unknown" {
    const allocator = std.testing.allocator;
    const handle = try GsaHandle.create(allocator, "http://localhost:7820", "");
    defer handle.destroy();

    const id = try handle.openHandle("mc-1");
    try std.testing.expect(id >= FIRST_HANDLE_ID);
    try std.testing.expectEqual(HandleUse.live, handle.useHandle(id));
    try std.testing.expectEqualStrings("mc-1", handle.handleServerId(id).?);

    // ids are never reused within a process
    const id2 = try handle.openHandle("mc-2");
    try std.testing.expect(id2 != id);

    try std.testing.expectEqual(HandleUse.live, handle.closeHandle(id));
    try std.testing.expectEqual(HandleUse.consumed, handle.useHandle(id));
    try std.testing.expectEqual(HandleUse.consumed, handle.closeHandle(id));
    try std.testing.expectEqual(HandleUse.unknown, handle.closeHandle(424242));

    try std.testing.expectEqual(HandleUse.live, handle.closeHandle(id2));
}

test "handle lifecycle: tombstone ring is bounded, not leaky" {
    const allocator = std.testing.allocator;
    const handle = try GsaHandle.create(allocator, "http://localhost:7820", "");
    defer handle.destroy();

    const first = try handle.openHandle("srv");
    try std.testing.expectEqual(HandleUse.live, handle.closeHandle(first));

    // Push more closes than the ring holds; the first tombstone is evicted.
    var i: usize = 0;
    while (i < CLOSED_HANDLE_TOMBSTONES) : (i += 1) {
        const id = try handle.openHandle("srv");
        try std.testing.expectEqual(HandleUse.live, handle.closeHandle(id));
    }
    try std.testing.expectEqual(HandleUse.unknown, handle.useHandle(first));
}
