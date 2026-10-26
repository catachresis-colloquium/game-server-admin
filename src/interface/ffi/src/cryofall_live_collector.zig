// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
// Explicit-ID, bounded, read-only CryoFall/systemd collection.
const std = @import("std");
const registry = @import("deployment_registry.zig");
const model = @import("deployment_model.zig");
const systemd = @import("systemd_inspect.zig");
const process = @import("bounded_process.zig");

pub const MAX_OUTPUT = 65536;
pub const MAX_LOG_LINES = 200;
const MAX_LOG_SUFFIX_BYTES = 1024 * 1024;
pub const Socket = struct { port: u16, address: []const u8, pid: u32, source: []const u8 };
pub const Inspection = struct {
    arena: std.heap.ArenaAllocator,
    instance_id: []const u8,
    profile_id: []const u8,
    host: []const u8,
    unit: []const u8,
    load_state: []const u8,
    active_state: []const u8,
    main_pid: ?u32,
    invocation_id: ?[]const u8,
    working_directory: ?[]const u8,
    executable: ?[]const u8,
    command: ?[]const []const u8,
    process_start_ticks: ?u64,
    uptime_seconds: ?u64,
    boot_id: ?[]const u8,
    sampled_at_unix_seconds: struct { before: i64, after: i64 },
    configured_game_port: ?u16,
    game_socket_bound: ?bool,
    observed_sockets: []const Socket,
    world_activated: ?bool,
    ready: ?bool,
    readiness_evidence: ?[]const u8,
    client_reachable: ?bool,
    client_reachability_evidence: []const u8,
    game_version: ?[]const u8,
    game_version_source: ?[]const u8,
    data_path: []const u8,
    config_path: ?[]const u8,
    save_path: ?[]const u8,
    paths_source: []const u8,
    configured_port_source: ?[]const u8,
    backup_mode: []const u8,
    backup_evidence: []const u8,
    logs: ?[]const u8,
    pub fn deinit(self: *Inspection) void {
        self.arena.deinit();
    }
};

const Unit = struct {
    id: []const u8 = "",
    load: []const u8 = "",
    active: []const u8 = "",
    pid: []const u8 = "",
    invocation: []const u8 = "",
    cwd: []const u8 = "",
    active_enter_us: []const u8 = "",
};

fn run(a: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32) ![]const u8 {
    var cancel = process.Cancel{};
    const result = try process.run(a, argv, false, timeout_ms, &cancel);
    defer a.free(result.error_output);
    errdefer a.free(result.output);
    if (!result.success or result.exit_code != 0) return error.ReadCommandFailed;
    if (result.output.len > MAX_OUTPUT) return error.OutputTooLarge;
    return result.output;
}

fn parseUnit(output: []const u8, requested: []const u8) !Unit {
    if (!systemd.safeUnit(requested) or output.len > MAX_OUTPUT) return error.InvalidUnit;
    var value: Unit = .{};
    var seen = [_]bool{false} ** 7;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse return error.MalformedSystemdOutput;
        const key = line[0..equal];
        const data = line[equal + 1 ..];
        const keys = [_][]const u8{ "Id", "LoadState", "ActiveState", "MainPID", "InvocationID", "WorkingDirectory", "ActiveEnterTimestampMonotonic" };
        inline for (keys, 0..) |expected, index| if (std.mem.eql(u8, key, expected)) {
            if (seen[index]) return error.DuplicateProperty;
            seen[index] = true;
            switch (index) {
                0 => value.id = data,
                1 => value.load = data,
                2 => value.active = data,
                3 => value.pid = data,
                4 => value.invocation = data,
                5 => value.cwd = data,
                6 => value.active_enter_us = data,
                else => unreachable,
            }
        };
    }
    for (seen[0..3]) |present| if (!present) return error.MalformedSystemdOutput;
    if (!std.mem.eql(u8, value.id, requested)) return error.UnitMismatch;
    return value;
}

fn startTicks(stat: []const u8) !u64 {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.MalformedProcStat;
    if (close + 2 >= stat.len) return error.MalformedProcStat;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    var number: usize = 3;
    while (fields.next()) |field| : (number += 1) {
        if (number == 22) return std.fmt.parseInt(u64, field, 10) catch error.MalformedProcStat;
    }
    return error.MalformedProcStat;
}

pub fn parseConfiguredPort(xml: []const u8) !?u16 {
    if (xml.len > 65536) return error.InputTooLarge;
    const open = std.mem.indexOf(u8, xml, "<port>") orelse return null;
    const start = open + "<port>".len;
    const close = std.mem.indexOfPos(u8, xml, start, "</port>") orelse return error.MalformedConfig;
    const value = std.mem.trim(u8, xml[start..close], " \t\r\n");
    const port = std.fmt.parseInt(u16, value, 10) catch return error.MalformedConfig;
    if (port == 0) return error.MalformedConfig;
    return port;
}

fn lineHasPid(line: []const u8, pid: u32) bool {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, line, offset, "pid=")) |at| {
        const begin = at + 4;
        var end = begin;
        while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
        if (end > begin and (std.fmt.parseInt(u32, line[begin..end], 10) catch 0) == pid) return true;
        offset = @max(end, at + 1);
    }
    return false;
}

fn observedSockets(a: std.mem.Allocator, output: []const u8, pid: u32) ![]const Socket {
    if (output.len > MAX_OUTPUT) return error.OutputTooLarge;
    var list: std.ArrayList(Socket) = .empty;
    errdefer list.deinit(a);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (!lineHasPid(line, pid)) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue; // state
        _ = fields.next() orelse continue; // receive queue
        _ = fields.next() orelse continue; // send queue
        const local = fields.next() orelse continue;
        const colon = std.mem.lastIndexOfScalar(u8, local, ':') orelse continue;
        const port = std.fmt.parseInt(u16, local[colon + 1 ..], 10) catch continue;
        try list.append(a, .{ .port = port, .address = try a.dupe(u8, local[0..colon]), .pid = pid, .source = "ss UDP socket row matched systemd MainPID" });
    }
    return list.toOwnedSlice(a);
}

fn safeLogLine(line: []const u8) bool {
    const lower = std.ascii.allocLowerString(std.heap.page_allocator, line) catch return false;
    defer std.heap.page_allocator.free(lower);
    for ([_][]const u8{ "password", "secret", "token", "credential", "api_key", "apikey", "steam_guard" }) |marker| {
        if (std.mem.indexOf(u8, lower, marker) != null) return false;
    }
    return true;
}

pub fn sanitizeLogs(a: std.mem.Allocator, text: []const u8, requested_lines: u16) ![]const u8 {
    if (text.len > MAX_OUTPUT) return error.OutputTooLarge;
    const count: usize = @min(@as(usize, if (requested_lines == 0) 1 else requested_lines), MAX_LOG_LINES);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var retained: std.ArrayList([]const u8) = .empty;
    defer retained.deinit(a);
    while (lines.next()) |line| {
        if (safeLogLine(line)) try retained.append(a, line);
    }
    const start = retained.items.len -| count;
    var out: std.ArrayList(u8) = .empty;
    for (retained.items[start..], 0..) |line, index| {
        if (index != 0) try out.append(a, '\n');
        try out.appendSlice(a, line);
    }
    return out.toOwnedSlice(a);
}

fn readFile(a: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, limit);
}

fn latestServerLog(a: std.mem.Allocator, data_path: []const u8) !?[]const u8 {
    const directory_path = try std.fmt.allocPrint(a, "{s}/Logs", .{data_path});
    defer a.free(directory_path);
    var directory = std.fs.cwd().openDir(directory_path, .{ .iterate = true }) catch return null;
    defer directory.close();
    var iterator = directory.iterate();
    var latest: ?[]const u8 = null;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "Server_CryoFall_") or !std.mem.endsWith(u8, entry.name, ".log")) continue;
        if (latest) |previous| {
            const previous_name = std.fs.path.basename(previous);
            if (std.mem.order(u8, entry.name, previous_name) != .gt) continue;
        }
        const candidate = try std.fs.path.join(a, &.{ directory_path, entry.name });
        latest = candidate;
    }
    return latest;
}

fn validNumericVersion(version: []const u8) bool {
    if (version.len == 0) return false;
    var components = std.mem.splitScalar(u8, version, '.');
    var count: usize = 0;
    while (components.next()) |component| {
        if (component.len == 0) return false;
        for (component) |character| if (!std.ascii.isDigit(character)) return false;
        count += 1;
    }
    return count >= 2;
}

fn parseVersionFilename(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "Version ")) return null;
    const version = name["Version ".len..];
    if (!validNumericVersion(version)) return null;
    return version;
}

fn parseInstalledVersion(text: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, text, "\xef\xbb\xbf\r\n \t");
    const content = if (std.mem.startsWith(u8, line, "Version ")) line["Version ".len..] else line;
    const end = std.mem.indexOfScalar(u8, content, ' ') orelse content.len;
    const version = content[0..end];
    if (!validNumericVersion(version)) return null;
    if (end < content.len and !std.mem.eql(u8, content[end..], " (Server, NetCore)")) return null;
    return version;
}

fn installedVersion(a: std.mem.Allocator, data_path: []const u8) !?[]const u8 {
    const root_path = data_path;
    var directory = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch return null;
    defer directory.close();
    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        const filename_version = parseVersionFilename(entry.name) orelse continue;
        const path = try std.fs.path.join(a, &.{ root_path, entry.name });
        const bytes = readFile(a, path, 1024) catch continue;
        defer a.free(bytes);
        const version = parseInstalledVersion(bytes) orelse continue;
        if (!std.mem.eql(u8, filename_version, version)) continue;
        return try a.dupe(u8, filename_version);
    }
    return null;
}

fn currentRunActivated(log: []const u8) ?bool {
    const run_header = std.mem.lastIndexOf(u8, log, "CryoFall game server runtime") orelse return null;
    const activation = std.mem.lastIndexOf(u8, log, "Server world activated") orelse return false;
    return activation > run_header;
}

fn logTail(a: std.mem.Allocator, log: []const u8, lines: u16) ![]const u8 {
    const tail = if (log.len > MAX_OUTPUT) log[log.len - MAX_OUTPUT ..] else log;
    return sanitizeLogs(a, std.mem.trimEnd(u8, tail, "\r\n"), lines);
}

fn readLogSuffixFromFile(a: std.mem.Allocator, file: *std.fs.File) ![]u8 {
    const file_size = (try file.stat()).size;
    const read_size = @min(file_size, MAX_LOG_SUFFIX_BYTES);
    try file.seekTo(file_size - read_size);
    return file.readToEndAlloc(a, MAX_LOG_SUFFIX_BYTES);
}

fn readLogSuffix(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return readLogSuffixFromFile(a, &file);
}

fn findPort(sockets: []const Socket, expected: u16, pid: u32) bool {
    for (sockets) |socket| if (socket.port == expected and socket.pid == pid) return true;
    return false;
}

fn safeCommand(a: std.mem.Allocator, executable: []const u8, raw: []const u8) ![]const []const u8 {
    if (!std.mem.endsWith(u8, executable, "/dotnet") or raw.len > 4096) return error.UnexpectedRuntimeProcess;
    var parts = std.mem.splitScalar(u8, raw, 0);
    var parsed: std.ArrayList([]const u8) = .empty;
    defer parsed.deinit(a);
    while (parts.next()) |part| if (part.len > 0) {
        if (parsed.items.len >= 8) return error.UnexpectedRuntimeArguments;
        try parsed.append(a, part);
    };
    if (parsed.items.len < 3 or
        !(std.mem.eql(u8, parsed.items[1], "CryoFall_Server.dll") or std.mem.endsWith(u8, parsed.items[1], "/CryoFall_Server.dll")))
    {
        return error.UnexpectedRuntimeProcess;
    }
    const mode = parsed.items[2];
    if (!std.mem.eql(u8, mode, "load") and !std.mem.eql(u8, mode, "loadOrNew") and !std.mem.eql(u8, mode, "new")) return error.UnexpectedRuntimeArguments;
    if (parsed.items.len != 3) return error.UnexpectedRuntimeArguments;
    const command = try a.alloc([]const u8, 3);
    command[0] = try a.dupe(u8, executable);
    command[1] = try a.dupe(u8, "CryoFall_Server.dll");
    command[2] = try a.dupe(u8, mode);
    return command;
}

fn configPath(declaration: *const model.Instance) ?[]const u8 {
    for (declaration.paths.config) |path| if (std.mem.endsWith(u8, path, "/SettingsServer.xml")) return path;
    return null;
}

fn savePath(declaration: *const model.Instance) ?[]const u8 {
    for (declaration.paths.world) |path| if (std.mem.endsWith(u8, path, "/Saves")) return path;
    return null;
}

/// Read-only collection. All mutating operations are absent from this module.
pub fn collect(allocator: std.mem.Allocator, snapshot: *const registry.Snapshot, instance_id: []const u8, local_host_key: []const u8, requested_log_lines: ?u16) !Inspection {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const declaration = try snapshot.lookup(instance_id);
    try validateReadCapabilities(declaration, requested_log_lines);
    if (!std.mem.eql(u8, declaration.host, local_host_key)) return error.HostMismatch;
    if (declaration.runtime.type != .systemd) return error.UnsupportedRuntime;
    if (!std.mem.eql(u8, declaration.profile_id, "cryofall")) return error.UnsupportedProfile;
    if (!systemd.safeUnit(declaration.runtime.identity)) return error.InvalidUnit;
    const config = configPath(declaration);
    const saves = savePath(declaration);
    const data = if (declaration.paths.data.len > 0) declaration.paths.data[0] else return error.MissingDataPath;
    const show_argv = try systemd.showArguments(declaration.runtime.identity);
    const before_text = try run(a, &show_argv, 5000);
    defer a.free(before_text);
    const before = try parseUnit(before_text, declaration.runtime.identity);
    const timestamp_before = std.time.timestamp();
    const boot_before = readFile(a, "/proc/sys/kernel/random/boot_id", 128) catch null;
    const boot_id = if (boot_before) |bytes| try a.dupe(u8, std.mem.trim(u8, bytes, "\r\n")) else null;

    var pid: ?u32 = null;
    var invocation: ?[]const u8 = null;
    var cwd: ?[]const u8 = null;
    var executable: ?[]const u8 = null;
    var command: ?[]const []const u8 = null;
    var process_ticks: ?u64 = null;
    var uptime: ?u64 = null;
    var sockets: []const Socket = &.{};
    var world_activated: ?bool = null;
    var ready: ?bool = null;
    var game_socket_bound: ?bool = null;
    const active = std.mem.eql(u8, before.load, "loaded") and std.mem.eql(u8, before.active, "active");
    var log_text: ?[]const u8 = null;

    var configured_port: ?u16 = null;
    if (config) |path| if (readFile(a, path, 65536)) |xml| {
        defer a.free(xml);
        configured_port = try parseConfiguredPort(xml);
    } else |_| {};

    const version = try installedVersion(a, data);

    if (active) {
        const parsed_pid = std.fmt.parseInt(u32, before.pid, 10) catch return error.MissingMainPid;
        if (parsed_pid == 0 or before.invocation.len == 0 or before.cwd.len == 0) return error.MissingProcessIdentity;
        const stat_path = try std.fmt.allocPrint(a, "/proc/{d}/stat", .{parsed_pid});
        const cmdline_path = try std.fmt.allocPrint(a, "/proc/{d}/cmdline", .{parsed_pid});
        const cwd_path = try std.fmt.allocPrint(a, "/proc/{d}/cwd", .{parsed_pid});
        const exe_path = try std.fmt.allocPrint(a, "/proc/{d}/exe", .{parsed_pid});
        const stat_before = try readFile(a, stat_path, 8192);
        const ticks_before = try startTicks(stat_before);
        const raw_cmdline = try readFile(a, cmdline_path, 32768);
        var cwd_buffer: [4096]u8 = undefined;
        const read_cwd = try std.fs.cwd().readLink(cwd_path, &cwd_buffer);
        if (!std.mem.eql(u8, read_cwd, before.cwd)) return error.WorkingDirectoryMismatch;
        const expected_working_directory = try std.fs.path.join(a, &.{ declaration.paths.data[0], "Binaries/Server" });
        if (!std.mem.eql(u8, read_cwd, expected_working_directory)) return error.DeclaredWorkingDirectoryMismatch;
        var exe_buffer: [4096]u8 = undefined;
        const read_executable = try std.fs.cwd().readLink(exe_path, &exe_buffer);
        const safe_args = try safeCommand(a, read_executable, raw_cmdline);
        const stat_after = try readFile(a, stat_path, 8192);
        if (try startTicks(stat_after) != ticks_before) return error.ProcessChanged;
        pid = parsed_pid;
        invocation = before.invocation;
        cwd = try a.dupe(u8, read_cwd);
        executable = try a.dupe(u8, read_executable);
        command = safe_args;
        process_ticks = ticks_before;

        const uptime_text = readFile(a, "/proc/uptime", 128) catch null;
        if (uptime_text) |text| {
            defer a.free(text);
            const seconds_text = std.mem.sliceTo(text, ' ');
            const seconds = std.fmt.parseFloat(f64, seconds_text) catch return error.MalformedClock;
            const active_enter = std.fmt.parseInt(u64, before.active_enter_us, 10) catch 0;
            if (seconds >= @as(f64, @floatFromInt(active_enter)) / 1_000_000.0) {
                uptime = @intFromFloat(seconds - @as(f64, @floatFromInt(active_enter)) / 1_000_000.0);
            }
        }
        const ss_args = [_][]const u8{ "ss", "-H", "-lunp" };
        const ss_output = run(a, &ss_args, 5000) catch null;
        if (ss_output) |output| sockets = try observedSockets(a, output, parsed_pid);
        if (ss_output) |output| a.free(output);
    }

    const game_data = try std.fs.path.join(a, &.{ data, "Data" });
    if (declaration.capabilities.logs.enabled) {
        if (try latestServerLog(a, game_data)) |log_path| {
            if (readLogSuffix(a, log_path)) |raw| {
                defer a.free(raw);
                if (active) world_activated = currentRunActivated(raw);
                if (requested_log_lines) |count| log_text = try logTail(a, raw, count);
            } else |_| {}
        }
    }
    if (active) if (pid) |active_pid| if (configured_port) |port| {
        game_socket_bound = findPort(sockets, port, active_pid);
        if (world_activated) |activated| ready = activated and game_socket_bound.?;
    };

    const after_text = try run(a, &show_argv, 5000);
    defer a.free(after_text);
    const after = try parseUnit(after_text, declaration.runtime.identity);
    if (!std.mem.eql(u8, before.pid, after.pid) or !std.mem.eql(u8, before.invocation, after.invocation) or !std.mem.eql(u8, before.active, after.active) or !std.mem.eql(u8, before.load, after.load)) return error.UnitProcessChanged;
    if (pid) |main_pid| {
        const stat_path = try std.fmt.allocPrint(a, "/proc/{d}/stat", .{main_pid});
        const stat_final = try readFile(a, stat_path, 8192);
        if (try startTicks(stat_final) != process_ticks.?) return error.ProcessChanged;
    }
    const boot_after = readFile(a, "/proc/sys/kernel/random/boot_id", 128) catch null;
    if (boot_id) |before_id| if (boot_after) |after_bytes| {
        if (!std.mem.eql(u8, before_id, std.mem.trim(u8, after_bytes, "\r\n"))) return error.BootChanged;
    };
    const timestamp_after = std.time.timestamp();
    return .{
        .arena = arena,
        .instance_id = try a.dupe(u8, declaration.id),
        .profile_id = try a.dupe(u8, declaration.profile_id),
        .host = try a.dupe(u8, declaration.host),
        .unit = try a.dupe(u8, declaration.runtime.identity),
        .load_state = try a.dupe(u8, before.load),
        .active_state = try a.dupe(u8, before.active),
        .main_pid = pid,
        .invocation_id = if (invocation) |value| try a.dupe(u8, value) else null,
        .working_directory = cwd,
        .executable = executable,
        .command = command,
        .process_start_ticks = process_ticks,
        .uptime_seconds = uptime,
        .boot_id = boot_id,
        .sampled_at_unix_seconds = .{ .before = timestamp_before, .after = timestamp_after },
        .configured_game_port = configured_port,
        .game_socket_bound = game_socket_bound,
        .observed_sockets = sockets,
        .world_activated = world_activated,
        .ready = ready,
        .readiness_evidence = if (ready != null) "current Data/Logs runtime marker plus UDP socket row matched to selected systemd MainPID" else null,
        .client_reachable = null,
        .client_reachability_evidence = "not tested; no independent client/query protocol qualification",
        .game_version = version,
        .game_version_source = if (version != null) "installation Version <version> file" else null,
        .data_path = try a.dupe(u8, data),
        .config_path = if (config) |path| try a.dupe(u8, path) else null,
        .save_path = if (saves) |path| try a.dupe(u8, path) else null,
        .paths_source = "deployment-instance declaration",
        .configured_port_source = if (configured_port != null) "allowlisted <port> value from SettingsServer.xml" else null,
        .backup_mode = "clean_stop_required",
        .backup_evidence = "CryoFall stop 0 acknowledged and saved; SIGTERM exited 143 without checkpoint",
        .logs = log_text,
    };
}

fn validateReadCapabilities(declaration: *const model.Instance, requested_log_lines: ?u16) !void {
    if (!declaration.capabilities.probe.enabled) return error.ProbeCapabilityDisabled;
    // This inspection projection includes the configured port and config path. Decline
    // before I/O rather than reading config and suppressing its values afterward.
    if (!declaration.capabilities.config.enabled) return error.ConfigCapabilityDisabled;
    if (requested_log_lines != null and !declaration.capabilities.logs.enabled) return error.LogsCapabilityDisabled;
}

test "CryoFall fixture config reads only the allowlisted game port" {
    const a = std.testing.allocator;
    const xml = try std.fs.cwd().readFileAlloc(a, "fixtures/cryofall/SettingsServer.xml", 65536);
    defer a.free(xml);
    try std.testing.expectEqual(@as(?u16, 6000), try parseConfiguredPort(xml));
    const safe_projection = try std.json.Stringify.valueAlloc(a, .{ .configured_game_port = try parseConfiguredPort(xml) }, .{});
    defer a.free(safe_projection);
    try std.testing.expect(std.mem.indexOf(u8, safe_projection, "fixture-secret") == null);
    try std.testing.expectError(error.MalformedConfig, parseConfiguredPort("<server-settings><port>6000.5</port></server-settings>"));
    try std.testing.expectEqual(@as(?u16, null), try parseConfiguredPort("<server-settings/>"));
}

test "CryoFall collector fails closed before reads when probe capability is disabled" {
    var declaration: model.Instance = .{
        .id = "cryofall-test",
        .profile_id = "cryofall",
        .host = "local",
        .runtime = .{ .type = .systemd, .identity = "cryofall-test.service" },
        .game = .{ .version = "unknown" },
    };
    declaration.capabilities.config.enabled = true;
    declaration.capabilities.logs.enabled = true;
    declaration.capabilities.probe.enabled = false;
    try std.testing.expectError(error.ProbeCapabilityDisabled, validateReadCapabilities(&declaration, null));
}

test "CryoFall collector declines config projection before reading config when disabled" {
    var declaration: model.Instance = .{
        .id = "cryofall-test",
        .profile_id = "cryofall",
        .host = "local",
        .runtime = .{ .type = .systemd, .identity = "cryofall-test.service" },
        .game = .{ .version = "unknown" },
    };
    declaration.capabilities.probe.enabled = true;
    declaration.capabilities.logs.enabled = true;
    declaration.capabilities.config.enabled = false;
    try std.testing.expectError(error.ConfigCapabilityDisabled, validateReadCapabilities(&declaration, null));
}

test "CryoFall requested logs fail closed when logs capability is disabled" {
    const declaration: model.Instance = .{
        .id = "cryofall-test",
        .profile_id = "cryofall",
        .host = "local",
        .runtime = .{ .type = .systemd, .identity = "cryofall-test.service" },
        .game = .{ .version = "unknown" },
    };
    var enabled = declaration;
    enabled.capabilities.probe.enabled = true;
    enabled.capabilities.config.enabled = true;
    try std.testing.expectError(error.LogsCapabilityDisabled, validateReadCapabilities(&enabled, 10));
    try validateReadCapabilities(&enabled, null);
}

test "CryoFall sockets and startup markers are tied to the selected PID and game port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sockets = try std.fs.cwd().readFileAlloc(a, "fixtures/cryofall/ss.txt", 65536);
    const observed = try observedSockets(a, sockets, 4123);
    try std.testing.expect(findPort(observed, 6000, 4123));
    try std.testing.expect(!findPort(observed, 6000, 9999));
    try std.testing.expect(!findPort(observed, 6001, 4123));
    const startup = try std.fs.cwd().readFileAlloc(a, "fixtures/cryofall/server.log", 65536);
    try std.testing.expectEqual(@as(?bool, true), currentRunActivated(startup));
    try std.testing.expectEqual(@as(?bool, false), currentRunActivated("CryoFall game server runtime v1\nServer world activated\nCryoFall game server runtime v2\n"));
}

test "CryoFall logs are bounded and secret-bearing lines are omitted" {
    const a = std.testing.allocator;
    const raw = "startup ready\nserver password=do-not-print\nworld active\n";
    const safe = try sanitizeLogs(a, raw, 10);
    defer a.free(safe);
    try std.testing.expect(std.mem.indexOf(u8, safe, "do-not-print") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "startup ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "world active") != null);
    try std.testing.expectError(error.OutputTooLarge, sanitizeLogs(a, &[_]u8{'x'} ** (MAX_OUTPUT + 1), 10));
}

test "CryoFall large logs use a bounded suffix for activation and requested tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("large-server.log", .{ .read = true });
    defer file.close();
    const block = [_]u8{'x'} ** 65536;
    for (0..129) |_| try file.writeAll(&block);
    try file.writeAll("\nCryoFall game server runtime current\nServer world activated\nlate log line one\nlate log line two\n");

    const a = std.testing.allocator;
    const suffix = try readLogSuffixFromFile(a, &file);
    defer a.free(suffix);
    try std.testing.expect(suffix.len <= MAX_LOG_SUFFIX_BYTES);
    try std.testing.expect(suffix.len < 8 * 1024 * 1024);
    try std.testing.expectEqual(@as(?bool, true), currentRunActivated(suffix));
    const tail = try logTail(a, suffix, 2);
    defer a.free(tail);
    try std.testing.expectEqualStrings("late log line one\nlate log line two", tail);
}

test "CryoFall systemd parser rejects unit mismatch and malformed runtime state" {
    const good = "Id=cryofall-test.service\nLoadState=loaded\nActiveState=active\nMainPID=4123\nInvocationID=abc\nWorkingDirectory=/opt/cryofall-test/Binaries/Server\nActiveEnterTimestampMonotonic=1000000\n";
    const parsed = try parseUnit(good, "cryofall-test.service");
    try std.testing.expectEqualStrings("4123", parsed.pid);
    try std.testing.expectError(error.UnitMismatch, parseUnit("Id=other.service\nLoadState=loaded\nActiveState=active\n", "cryofall-test.service"));
    try std.testing.expectError(error.InvalidUnit, parseUnit(good, "cryofall-test.service;stop"));
}

test "CryoFall runtime allowlist accepts verified relative and absolute assembly forms only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const relative = try safeCommand(a, "/opt/gsa-dotnet-6/dotnet", "dotnet\x00CryoFall_Server.dll\x00load\x00");
    try std.testing.expectEqualStrings("load", relative[2]);
    try std.testing.expectError(error.UnexpectedRuntimeProcess, safeCommand(a, "/opt/gsa-dotnet-6/dotnet", "dotnet\x00Other.dll\x00load\x00"));
    try std.testing.expectError(error.UnexpectedRuntimeArguments, safeCommand(a, "/opt/gsa-dotnet-6/dotnet", "dotnet\x00CryoFall_Server.dll\x00load\x00--password=secret\x00"));
}

test "CryoFall install fixture records the verified server package and .NET runtime" {
    const a = std.testing.allocator;
    const tree = try std.fs.cwd().readFileAlloc(a, "fixtures/cryofall/install-tree.txt", 4096);
    defer a.free(tree);
    for ([_][]const u8{ "Binaries/Server/CryoFall_Server.dll", "Core/Core.cpk", "Data/SettingsServer.xml", "Data/Saves", "net6.0" }) |path| {
        try std.testing.expect(std.mem.indexOf(u8, tree, path) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, tree, "CryoFall_Server.x86_64") == null);
    try std.testing.expectEqualStrings("1.33.1.15", parseVersionFilename("Version 1.33.1.15").?);
    try std.testing.expectEqualStrings("1.33.1.15", parseInstalledVersion("1.33.1.15 (Server, NetCore)\r\n").?);
    try std.testing.expectEqualStrings("1.33.1.15", parseInstalledVersion("\xef\xbb\xbfVersion 1.33.1.15 (Server, NetCore)\r\n").?);
    try std.testing.expect(parseVersionFilename("Version 1..33.1.15") == null);
    try std.testing.expect(parseVersionFilename("Version 1.33.1.15-extra") == null);
    try std.testing.expect(parseInstalledVersion("CryoFall Dedicated Server 1.33.1.15") == null);
    try std.testing.expect(parseInstalledVersion("1.33.1.15 (Client, NetCore)") == null);
    try std.testing.expect(parseInstalledVersion("Version latest (Server)\n") == null);
}

test "CryoFall safety policy uses console checkpoint and keeps runtime independent of GSA" {
    const a = std.testing.allocator;
    const unit = try std.fs.cwd().readFileAlloc(a, "deployment-instances/wizardly-hellman/cryofall-test.service", 8192);
    defer a.free(unit);
    try std.testing.expect(std.mem.indexOf(u8, unit, "ExecStop=+/usr/bin/bash -c") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "echo stop 0 > /run/cryofall-test/console.fifo") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "while [ \"$(/usr/bin/systemctl show --property=MainPID") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "TimeoutStopSec=infinity") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Requires=gsa") == null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "verisimdb") == null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "WantedBy=") == null);
    const args = try systemd.showArguments("cryofall-test.service");
    try std.testing.expectEqualStrings("show", args[1]);
    try std.testing.expect(std.mem.indexOf(u8, args[3], "start") == null);
    try std.testing.expect(std.mem.indexOf(u8, args[3], "stop") == null);
}
