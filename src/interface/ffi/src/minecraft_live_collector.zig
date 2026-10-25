// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
// Explicit-ID, bounded, read-only local systemd/Minecraft collection.
const std = @import("std");
const registry = @import("deployment_registry.zig");
const model = @import("deployment_model.zig");
const inspect = @import("minecraft_systemd_inspect.zig");
const systemd = @import("systemd_inspect.zig");
const process = @import("bounded_process.zig");
const ProcessIdentity = struct { pid: u32, ticks: u64, invocation: []const u8 };
const ProcessRead = struct { argv: [][]const u8, identity: ProcessIdentity };
const ProcessEvidence = struct { pid: u32, start_ticks: u64, invocation_id: []const u8 };
const SocketEvidence = struct { listening: bool, address: ?[]const u8, port: u16, source: []const u8 };
const DerivedEvidence = struct { value: []const u8, source: []const u8, basis: []const u8 };

pub const MAX_OUTPUT = 65536;
pub const Inspection = struct {
    arena: std.heap.ArenaAllocator,
    instance_id: []const u8,
    profile_id: []const u8,
    host: []const u8,
    runtime_identity: []const u8,
    declared: model.Instance,
    boot_id: ?[]const u8,
    sampled_at_unix_seconds: struct { before: i64, after: i64 },
    systemd_main_pid: ?u32,
    process: ?ProcessEvidence,
    observed_socket: ?SocketEvidence,
    backup_mode: ?DerivedEvidence,
    report: inspect.Report,
    pub fn deinit(self: *Inspection) void {
        self.arena.deinit();
    }
};

const UnitEvidence = struct {
    unit: []const u8,
    load: []const u8,
    active: []const u8,
    pid: []const u8,
    invocation: []const u8,
    working_directory: []const u8,
    active_enter: []const u8,
};

fn run(a: std.mem.Allocator, argv: []const []const u8, timeout: u32) ![]const u8 {
    var cancel = process.Cancel{};
    const result = try process.run(a, argv, false, timeout, &cancel);
    defer a.free(result.error_output);
    errdefer a.free(result.output);
    if (!result.success or result.exit_code != 0) return error.ReadCommandFailed;
    if (result.output.len > MAX_OUTPUT) return error.OutputTooLarge;
    return result.output;
}

fn unitEvidence(output: []const u8, expected: []const u8) !UnitEvidence {
    if (!systemd.safeUnit(expected) or output.len > MAX_OUTPUT) return error.InvalidUnit;
    var result: UnitEvidence = .{ .unit = "", .load = "", .active = "", .pid = "", .invocation = "", .working_directory = "", .active_enter = "" };
    var seen: [7]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        const keys = [_][]const u8{ "Id", "LoadState", "ActiveState", "MainPID", "InvocationID", "WorkingDirectory", "ActiveEnterTimestampMonotonic" };
        inline for (keys, 0..) |wanted, index| if (std.mem.eql(u8, key, wanted)) {
            if (seen[index]) return error.DuplicateProperty;
            seen[index] = true;
            switch (index) {
                0 => result.unit = value,
                1 => result.load = value,
                2 => result.active = value,
                3 => result.pid = value,
                4 => result.invocation = value,
                5 => result.working_directory = value,
                6 => result.active_enter = value,
                else => unreachable,
            }
        };
    }
    for (seen[0..3]) |present| if (!present) return error.MalformedSystemdOutput;
    if (!std.mem.eql(u8, result.unit, expected)) return error.UnitMismatch;
    return result;
}

fn readBounded(a: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, max);
}

fn startTicks(stat: []const u8) !u64 {
    // comm is parenthesized and may itself contain spaces or parentheses.
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.MalformedProcStat;
    if (close + 2 >= stat.len) return error.MalformedProcStat;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' '); // begins with field 3 (state)
    var field_number: usize = 3;
    while (fields.next()) |value| : (field_number += 1) {
        if (field_number == 22) return std.fmt.parseInt(u64, value, 10) catch error.MalformedProcStat;
    }
    return error.MalformedProcStat;
}

fn argvVector(a: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    if (bytes.len > 32768) return error.InputTooLarge;
    var list: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, bytes, 0);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (part.len > 4096 or list.items.len == 256) return error.InputTooLarge;
        try list.append(a, part);
    }
    return list.toOwnedSlice(a);
}

fn parseUptimeMicros(bytes: []const u8) !u64 {
    const first = std.mem.sliceTo(bytes, ' ');
    const seconds = std.fmt.parseFloat(f64, first) catch return error.MalformedClock;
    if (!std.math.isFinite(seconds) or seconds < 0 or seconds > 1.0e12) return error.MalformedClock;
    return @intFromFloat(seconds * 1_000_000.0);
}

fn readProcess(a: std.mem.Allocator, evidence: UnitEvidence) !ProcessRead {
    const pid = try std.fmt.parseInt(u32, evidence.pid, 10);
    if (pid == 0 or evidence.invocation.len == 0) return error.MissingProcessIdentity;
    const stat_path = try std.fmt.allocPrint(a, "/proc/{d}/stat", .{pid});
    const argv_path = try std.fmt.allocPrint(a, "/proc/{d}/cmdline", .{pid});
    const cwd_path = try std.fmt.allocPrint(a, "/proc/{d}/cwd", .{pid});
    const exe_path = try std.fmt.allocPrint(a, "/proc/{d}/exe", .{pid});
    const stat_before = try readBounded(a, stat_path, 8192);
    const ticks_before = try startTicks(stat_before);
    const raw_argv = try argvVector(a, try readBounded(a, argv_path, 32768));
    var cwd_buf: [4096]u8 = undefined;
    const cwd = try std.fs.cwd().readLink(cwd_path, &cwd_buf);
    if (evidence.working_directory.len > 0 and !std.mem.eql(u8, cwd, evidence.working_directory)) return error.ProcessWorkingDirectoryMismatch;
    var exe_buf: [4096]u8 = undefined;
    const exe = try std.fs.cwd().readLink(exe_path, &exe_buf);
    const stat_after = try readBounded(a, stat_path, 8192);
    if (try startTicks(stat_after) != ticks_before) return error.ProcessChanged;
    var argv = raw_argv;
    if (raw_argv.len > 0 and safeJavaExecutable(exe)) {
        argv = try a.dupe([]const u8, raw_argv);
        argv[0] = try a.dupe(u8, exe);
    }
    return .{ .argv = argv, .identity = .{ .pid = pid, .ticks = ticks_before, .invocation = evidence.invocation } };
}

/// Collection uses an already-loaded snapshot and an explicit local inventory key.
/// A non-local host is intentionally unsupported until a separately authenticated
/// remote read-only transport exists.
pub fn collect(allocator: std.mem.Allocator, snapshot: *const registry.Snapshot, instance_id: []const u8, local_host_key: []const u8) !Inspection {
    var temporary = std.heap.ArenaAllocator.init(allocator);
    defer temporary.deinit();
    const a = temporary.allocator();
    const declaration = try snapshot.lookup(instance_id);
    if (!std.mem.eql(u8, declaration.host, local_host_key)) return error.HostMismatch;
    if (!declaration.capabilities.probe.enabled) return error.CapabilityUnsupported;
    if (declaration.runtime.type != .systemd) return error.UnsupportedRuntime;
    if (!systemd.safeUnit(declaration.runtime.identity)) return error.InvalidUnit;
    // The fixed property list contains only state/identity/process attribution.
    const show_argv = try systemd.showArguments(declaration.runtime.identity);
    const show_before = try run(a, &show_argv, 5000);
    defer a.free(show_before);
    const evidence = try unitEvidence(show_before, declaration.runtime.identity);

    const boot_before = readBounded(a, "/proc/sys/kernel/random/boot_id", 128) catch null;
    const uptime_before_bytes = readBounded(a, "/proc/uptime", 128) catch null;
    const realtime_before = std.time.timestamp();

    var argv: []const []const u8 = &.{};
    var process_identity: ?ProcessIdentity = null;
    const stable_boot_before = if (boot_before) |value| std.mem.trim(u8, value, "\r\n") else null;
    var monotonic: ?u64 = if (stable_boot_before != null and uptime_before_bytes != null) parseUptimeMicros(uptime_before_bytes.?) catch null else null;
    if (std.mem.eql(u8, evidence.load, "loaded") and std.mem.eql(u8, evidence.active, "active")) {
        if (readProcess(a, evidence)) |read| {
            process_identity = read.identity;
            argv = read.argv;
        } else |_| {}
    }

    // Allowlisted reads: only server-ip, server-port, level-name are projected;
    // the input bytes and JVM argv never enter the returned report.
    var props: ?[]u8 = null;
    defer if (props) |v| a.free(v);
    if (declaration.capabilities.config.enabled and declaration.paths.config.len > 0) props = readBounded(a, declaration.paths.config[0], 65536) catch null;

    // Fabric metadata is extracted from jar manifests with argv, never a shell.
    var metadata: std.ArrayList([]const u8) = .empty;
    var mod_metadata_known = false;
    if (declaration.paths.data.len > 0) {
        const mods_dir = try std.fmt.allocPrint(a, "{s}/mods", .{declaration.paths.data[0]});
        defer a.free(mods_dir);
        var dir = std.fs.cwd().openDir(mods_dir, .{ .iterate = true }) catch null;
        if (dir) |*d| {
            mod_metadata_known = true;
            defer d.close();
            var it = d.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jar") or !safeFilename(entry.name)) continue;
                if (metadata.items.len >= 1024) {
                    mod_metadata_known = false;
                    break;
                }
                const jar = try std.fmt.allocPrint(a, "{s}/{s}", .{ mods_dir, entry.name });
                defer a.free(jar);
                const jar_args = [_][]const u8{ "unzip", "-p", jar, "fabric.mod.json" };
                const json = run(a, &jar_args, 5000) catch {
                    mod_metadata_known = false;
                    continue;
                };
                if (json.len == 0 or json.len > 65536) {
                    mod_metadata_known = false;
                    a.free(json);
                    continue;
                }
                try metadata.append(a, json);
            }
        }
    }
    defer for (metadata.items) |json| a.free(json);
    var version_json: ?[]u8 = null;
    var loader_version: ?[]const u8 = null;
    var loader_ambiguous = false;
    var server_artifact_count: usize = 0;
    var server_version_ambiguous = false;
    defer if (version_json) |v| a.free(v);
    defer if (loader_version) |v| a.free(v);
    if (declaration.paths.data.len > 0) {
        const version_path = try std.fmt.allocPrint(a, "{s}/version.json", .{declaration.paths.data[0]});
        defer a.free(version_path);
        version_json = readBounded(a, version_path, 65536) catch null;
        const artifact_dir = try std.fmt.allocPrint(a, "{s}/.fabric/server", .{declaration.paths.data[0]});
        defer a.free(artifact_dir);
        var dir = std.fs.cwd().openDir(artifact_dir, .{ .iterate = true }) catch null;
        if (dir) |*d| {
            defer d.close();
            var it = d.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .file or !safeFilename(entry.name)) continue;
                if (std.mem.startsWith(u8, entry.name, "fabric-loader-server-") and std.mem.endsWith(u8, entry.name, ".jar")) {
                    const suffix = std.mem.indexOf(u8, entry.name["fabric-loader-server-".len..], "-minecraft-") orelse continue;
                    const candidate = entry.name["fabric-loader-server-".len .. "fabric-loader-server-".len + suffix];
                    if (validVersion(candidate)) {
                        if (loader_version) |previous| {
                            if (!std.mem.eql(u8, previous, candidate)) {
                                loader_version = null;
                                loader_ambiguous = true;
                            }
                        } else if (!loader_ambiguous) loader_version = try a.dupe(u8, candidate);
                    }
                }
                if (std.mem.endsWith(u8, entry.name, "-server.jar")) {
                    server_artifact_count += 1;
                    if (server_artifact_count > 1) {
                        server_version_ambiguous = true;
                        if (version_json != null) {
                            a.free(version_json.?);
                            version_json = null;
                        }
                        continue;
                    }
                    if (version_json != null) continue;
                    const jar = try std.fmt.allocPrint(a, "{s}/{s}", .{ artifact_dir, entry.name });
                    defer a.free(jar);
                    const jar_args = [_][]const u8{ "unzip", "-p", jar, "version.json" };
                    if (run(a, &jar_args, 5000)) |archive_json| {
                        version_json = try a.dupe(u8, archive_json);
                        a.free(archive_json);
                    } else |_| {}
                }
            }
        }
        if (server_version_ambiguous) version_json = null;
    }

    const uptime_after_bytes = readBounded(a, "/proc/uptime", 128) catch null;
    const boot_after = readBounded(a, "/proc/sys/kernel/random/boot_id", 128) catch null;
    const stable_boot_after = if (boot_after) |value| std.mem.trim(u8, value, "\r\n") else null;
    const boot_id: ?[]const u8 = if (stable_boot_before != null and stable_boot_after != null) blk: {
        if (!std.mem.eql(u8, stable_boot_before.?, stable_boot_after.?)) return error.BootChanged;
        break :blk stable_boot_before.?;
    } else null;
    if (boot_id == null) monotonic = null;
    if (uptime_after_bytes) |bytes| if (parseUptimeMicros(bytes)) |uptime_after| {
        if (monotonic) |m| if (uptime_after < m) return error.InvalidClockSample;
    } else |_| {};
    const realtime_after = std.time.timestamp();
    const show_after = try run(a, &show_argv, 5000);
    defer a.free(show_after);
    const evidence_after = try unitEvidence(show_after, declaration.runtime.identity);
    if (!std.mem.eql(u8, evidence.pid, evidence_after.pid) or
        !std.mem.eql(u8, evidence.invocation, evidence_after.invocation) or
        !std.mem.eql(u8, evidence.load, evidence_after.load) or
        !std.mem.eql(u8, evidence.active, evidence_after.active) or
        !std.mem.eql(u8, evidence.active_enter, evidence_after.active_enter)) return error.UnitProcessChanged;

    var socket: ?SocketEvidence = null;
    if (process_identity) |identity| {
        for (declaration.ports) |port| {
            if (port.protocol != .tcp) continue;
            socket = observeSocket(a, port.port, identity.pid) catch null;
            if (socket != null) break;
        }
    }

    var observation = try inspect.inspect(allocator, .{
        .instance_id = declaration.id,
        .unit = declaration.runtime.identity,
        .observed_at_unix_seconds = realtime_before,
        .monotonic_now_us = monotonic,
        .systemctl_show = show_before,
        .process_argv = argv,
        .server_properties = props,
        .version_json = version_json,
        .fabric_loader_version = loader_version,
        .mod_metadata_json = metadata.items,
        .mod_metadata_known = mod_metadata_known,
    });
    // The underlying inspector owns only its arena; wrap it in this result so
    // host/profile/runtime declarations remain associated with the evidence.
    const main_pid = std.fmt.parseInt(u32, evidence.pid, 10) catch 0;
    const outer = try allocatorInspection(&observation, declaration, realtime_before, realtime_after, boot_id, if (main_pid == 0) null else main_pid, process_identity, socket, loader_version != null);
    observation.arena = undefined;
    return outer;
}

fn allocatorInspection(
    observation: *inspect.Observation,
    declaration: *const model.Instance,
    sampled_before: i64,
    sampled_after: i64,
    boot: ?[]const u8,
    main_pid: ?u32,
    process_identity: ?ProcessIdentity,
    socket: ?SocketEvidence,
    fabric_confirmed: bool,
) !Inspection {
    errdefer observation.deinit();
    // Finish allocating in the arena before moving its allocator state.
    const arena_allocator = observation.arena.allocator();
    const instance_id = try arena_allocator.dupe(u8, declaration.id);
    const profile_id = try arena_allocator.dupe(u8, declaration.profile_id);
    const host = try arena_allocator.dupe(u8, declaration.host);
    const runtime_identity = try arena_allocator.dupe(u8, declaration.runtime.identity);
    const boot_id: ?[]const u8 = if (boot) |value| try arena_allocator.dupe(u8, value) else null;
    const process_evidence: ?ProcessEvidence = if (process_identity) |p| .{ .pid = p.pid, .start_ticks = p.ticks, .invocation_id = try arena_allocator.dupe(u8, p.invocation) } else null;
    const socket_evidence: ?SocketEvidence = if (socket) |s| .{
        .listening = s.listening,
        .address = if (s.address) |address| try arena_allocator.dupe(u8, address) else null,
        .port = s.port,
        .source = s.source,
    } else null;
    const backup_mode: ?DerivedEvidence = if (fabric_confirmed) .{
        .value = "clean_stop_required",
        .source = "Fabric server artifact + Minecraft backup adapter policy",
        .basis = "derived",
    } else null;
    const declared = try model.copy(arena_allocator, declaration.*);
    return .{
        .arena = observation.arena,
        .instance_id = instance_id,
        .profile_id = profile_id,
        .host = host,
        .runtime_identity = runtime_identity,
        .declared = declared,
        .boot_id = boot_id,
        .sampled_at_unix_seconds = .{ .before = sampled_before, .after = sampled_after },
        .systemd_main_pid = main_pid,
        .process = process_evidence,
        .observed_socket = socket_evidence,
        // This classifies backup consistency only. Backup remains disabled in
        // the declaration and no backup operation is available in this module.
        .backup_mode = backup_mode,
        .report = observation.report,
    };
}

fn safeJavaExecutable(path: []const u8) bool {
    if (path.len > 4096 or path.len == 0 or path[0] != '/') return false;
    for (path) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "/._+-", c) == null) return false;
    return std.mem.eql(u8, std.fs.path.basename(path), "java");
}

fn observeSocket(a: std.mem.Allocator, port: u16, expected_pid: u32) !SocketEvidence {
    const filter = try std.fmt.allocPrint(a, "sport = :{d}", .{port});
    defer a.free(filter);
    const argv = [_][]const u8{ "ss", "-H", "-ltnp", filter };
    const output = try run(a, &argv, 3000);
    defer a.free(output);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (!lineHasPid(line, expected_pid)) continue;
        var columns = std.mem.tokenizeScalar(u8, line, ' ');
        _ = columns.next(); // LISTEN
        _ = columns.next(); // receive queue
        _ = columns.next(); // send queue
        const local = columns.next() orelse continue;
        const split = std.mem.lastIndexOfScalar(u8, local, ':') orelse continue;
        const found_port = std.fmt.parseInt(u16, local[split + 1 ..], 10) catch continue;
        if (found_port != port) continue;
        return .{ .listening = true, .address = try a.dupe(u8, local[0..split]), .port = port, .source = "ss listener matched selected MainPID" };
    }
    return .{ .listening = false, .address = null, .port = port, .source = "ss query succeeded; no listener matched selected MainPID" };
}

fn lineHasPid(line: []const u8, pid: u32) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, "pid=")) |at| {
        const start = at + 4;
        var end = start;
        while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
        if (end > start and std.fmt.parseInt(u32, line[start..end], 10) catch 0 == pid) return true;
        i = end;
    }
    return false;
}

fn safeFilename(s: []const u8) bool {
    if (s.len == 0 or s.len > 255) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "._+-", c) == null) return false;
    return true;
}

fn validVersion(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, ".+_-", c) == null) return false;
    return true;
}

pub const LogResult = struct {
    arena: std.heap.ArenaAllocator,
    output: []const u8,
    truncated: bool,
    pub fn deinit(self: *LogResult) void {
        self.arena.deinit();
    }
};

/// Read bounded journal output for one explicit, registry-backed systemd unit.
/// Lines containing obvious credential markers are omitted before returning.
pub fn logs(a: std.mem.Allocator, snapshot: *const registry.Snapshot, instance_id: []const u8, local_host_key: []const u8, lines: u16) !LogResult {
    if (lines == 0 or lines > 500) return error.InvalidLineLimit;
    const instance = try snapshot.lookup(instance_id);
    if (!std.mem.eql(u8, instance.host, local_host_key)) return error.HostMismatch;
    if (!instance.capabilities.logs.enabled) return error.CapabilityUnsupported;
    if (instance.runtime.type != .systemd or !systemd.safeUnit(instance.runtime.identity)) return error.UnsupportedRuntime;
    const count = try std.fmt.allocPrint(a, "--lines={d}", .{lines});
    defer a.free(count);
    const argv = [_][]const u8{ "journalctl", "--no-pager", "--output=cat", "--unit", instance.runtime.identity, count };
    const raw = try run(a, &argv, 5000);
    defer a.free(raw);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const out = arena.allocator();
    var safe: std.ArrayList(u8) = .empty;
    var omitted = false;
    var split = std.mem.splitScalar(u8, raw, '\n');
    while (split.next()) |line| {
        if (sensitiveLine(line)) {
            omitted = true;
            continue;
        }
        if (safe.items.len + line.len + 1 > MAX_OUTPUT) {
            omitted = true;
            break;
        }
        try safe.appendSlice(out, line);
        try safe.append(out, '\n');
    }
    if (omitted) try safe.appendSlice(out, "[sensitive or excess log output omitted]\n");
    return .{ .arena = arena, .output = try safe.toOwnedSlice(out), .truncated = omitted };
}

fn sensitiveLine(line: []const u8) bool {
    for ([_][]const u8{ "password", "passwd", "rcon", "secret", "token", "credential", "authorization", "api_key", "apikey", "private key", "bearer", "cookie", "session" }) |marker| if (containsIgnoreCase(line, marker)) return true;
    if (containsIgnoreCase(line, "://")) return true;
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

test "live collector parses process starttime and binds systemd identity" {
    try std.testing.expectEqual(@as(u64, 98765), try startTicks("123 (java process) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 98765 20"));
    try std.testing.expectError(error.UnitMismatch, unitEvidence("Id=other.service\nLoadState=loaded\nActiveState=active\n", "minecraft.service"));
    try std.testing.expectError(error.DuplicateProperty, unitEvidence("Id=minecraft.service\nId=minecraft.service\nLoadState=loaded\nActiveState=active", "minecraft.service"));
    const evidence = try unitEvidence("Id=minecraft.service\nLoadState=loaded\nActiveState=active\nMainPID=42\nInvocationID=abc\n", "minecraft.service");
    try std.testing.expectEqualStrings("42", evidence.pid);
}

test "live collector log policy redacts credential-bearing lines and limits explicit selection" {
    try std.testing.expect(sensitiveLine("rcon.password=redacted-canary"));
    try std.testing.expect(sensitiveLine("Authorization: bearer canary"));
    try std.testing.expect(sensitiveLine("connecting to ws://10.0.0.2:7704/"));
    try std.testing.expect(!sensitiveLine("Starting Minecraft server"));
    try std.testing.expectError(error.InvalidLineLimit, logs(std.testing.allocator, undefined, "x", "h", 501));
}

test "live collector requires declared read capabilities before invoking a backend" {
    var declaration: model.Instance = .{
        .id = "mc",
        .profile_id = "minecraft-java",
        .host = "local",
        .runtime = .{ .type = .systemd, .identity = "mc.service" },
        .game = .{ .version = "unknown" },
    };
    declaration.capabilities.probe.enabled = false;
    declaration.capabilities.logs.enabled = false;
    var r = registry.Registry.init(std.testing.allocator);
    defer r.deinit();
    try r.register(declaration);
    var snapshot = try r.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectError(error.CapabilityUnsupported, collect(std.testing.allocator, &snapshot, "mc", "local"));
    try std.testing.expectError(error.CapabilityUnsupported, logs(std.testing.allocator, &snapshot, "mc", "local", 5));
}

test "live report transfers one owner for declaration and observed projection" {
    const a = std.testing.allocator;
    var observation = try inspect.inspect(a, .{
        .instance_id = "minecraft-survival",
        .unit = "minecraft.service",
        .observed_at_unix_seconds = 1,
        .systemctl_show = "Id=minecraft.service\nLoadState=loaded\nActiveState=inactive\nWorkingDirectory=/opt/minecraft-server\nActiveEnterTimestampMonotonic=0\n",
    });
    var declaration: model.Instance = .{
        .id = "minecraft-survival",
        .profile_id = "minecraft-java",
        .host = "wizardly-hellman",
        .runtime = .{ .type = .systemd, .identity = "minecraft.service" },
        .game = .{ .version = "1.21.11" },
    };
    declaration.paths.data = &.{"/opt/minecraft-server"};
    var result = try allocatorInspection(&observation, &declaration, 1, 2, "boot-id\n", null, null, null, false);
    observation.arena = undefined;
    defer result.deinit();
    try std.testing.expectEqualStrings("wizardly-hellman", result.host);
    try std.testing.expectEqualStrings("minecraft.service", result.report.unit.value);
    try std.testing.expectEqualStrings("/opt/minecraft-server", result.declared.paths.data[0]);
}
