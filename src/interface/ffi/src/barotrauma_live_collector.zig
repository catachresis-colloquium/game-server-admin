// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
// Explicit-ID, read-only Podman collection for a declared Barotrauma instance.
const std = @import("std");
const registry = @import("deployment_registry.zig");
const model = @import("deployment_model.zig");
const process = @import("bounded_process.zig");

pub const MAX_OUTPUT = 65536;
pub const MAX_LOG_LINES = 200;

pub const Inspection = struct {
    arena: *std.heap.ArenaAllocator,
    owner: std.mem.Allocator,
    instance_id: []const u8,
    profile_id: []const u8,
    host: []const u8,
    container: []const u8,
    container_id: []const u8,
    image_id: []const u8,
    state: []const u8,
    container_init_pid: ?u32,
    sampled_at_unix_seconds: i64,
    evidence_source: []const u8,
    configured_ports: []const u16,
    observed_udp_ports: []const u16,
    data_paths: []const []const u8,
    config_paths: []const []const u8,
    world_paths: []const []const u8,
    declared_game_version: ?[]const u8,
    readiness: ?bool,
    readiness_source: ?[]const u8,
    logs: ?[]const u8,

    pub fn deinit(self: *Inspection) void {
        self.arena.deinit();
        self.owner.destroy(self.arena);
    }
};

const RawInspect = struct {
    name: []const u8,
    id: []const u8,
    image_id: []const u8,
    state: []const u8,
    pid: []const u8,
};

fn validContainerName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_.-", c) == null) return false;
    return true;
}

fn run(a: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32) ![]const u8 {
    var cancel = process.Cancel{};
    const result = try process.run(a, argv, false, timeout_ms, &cancel);
    defer a.free(result.error_output);
    errdefer a.free(result.output);
    if (!result.success or result.exit_code != 0) return error.ReadCommandFailed;
    if (result.output.len > MAX_OUTPUT) return error.OutputTooLarge;
    return result.output;
}

fn parseInspect(text: []const u8, expected_name: []const u8) !RawInspect {
    if (text.len > 2048) return error.OutputTooLarge;
    var fields = std.mem.splitScalar(u8, text, '|');
    const name = std.mem.trim(u8, fields.next() orelse return error.MalformedInspect, " \r\n/");
    const id = fields.next() orelse return error.MalformedInspect;
    const image_id = fields.next() orelse return error.MalformedInspect;
    const state = fields.next() orelse return error.MalformedInspect;
    const pid = std.mem.trim(u8, fields.next() orelse return error.MalformedInspect, " \r\n");
    if (fields.next() != null or !validContainerName(name) or !std.mem.eql(u8, name, expected_name)) return error.ContainerMismatch;
    if (id.len < 12 or id.len > 64 or image_id.len < 12 or image_id.len > 64) return error.MalformedInspect;
    if (!oneOf(state, &.{ "configured", "created", "initialized", "running", "stopped", "paused", "exited", "stopping", "restarting", "removing", "dead", "unknown" })) return error.MalformedInspect;
    return .{ .name = name, .id = id, .image_id = image_id, .state = state, .pid = pid };
}

fn sameContainer(before: RawInspect, after: RawInspect) bool {
    return std.mem.eql(u8, before.id, after.id) and
        std.mem.eql(u8, before.image_id, after.image_id) and
        std.mem.eql(u8, before.state, after.state) and
        std.mem.eql(u8, before.pid, after.pid);
}

fn oneOf(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, value, option)) return true;
    return false;
}

fn copyStrings(a: std.mem.Allocator, source: []const []const u8) ![]const []const u8 {
    const result = try a.alloc([]const u8, source.len);
    for (source, 0..) |value, index| result[index] = try a.dupe(u8, value);
    return result;
}

fn validateRequest(declaration: *const model.Instance, id: []const u8, host_key: []const u8, requested_logs: ?u16) !void {
    if (!std.mem.eql(u8, declaration.id, id)) return error.InstanceMismatch;
    if (!std.mem.eql(u8, declaration.host, host_key)) return error.HostMismatch;
    if (!declaration.capabilities.probe.enabled) return error.ProbeUnsupported;
    if (requested_logs != null and !declaration.capabilities.logs.enabled) return error.LogsUnsupported;
    if (declaration.runtime.type != .podman) return error.UnsupportedRuntime;
    if (!validContainerName(declaration.runtime.identity)) return error.InvalidContainer;
}

const SettingsPorts = struct { game: ?u16 = null, query: ?u16 = null };

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == ':';
}

fn isNameChar(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c) or c == '-' or c == '.';
}

fn skipSpace(xml: []const u8, index: *usize) void {
    while (index.* < xml.len and std.ascii.isWhitespace(xml[index.*])) : (index.* += 1) {}
}

fn skipMarkup(xml: []const u8, index: *usize) !void {
    var quote: ?u8 = null;
    while (index.* < xml.len) : (index.* += 1) {
        const c = xml[index.*];
        if (quote) |q| {
            if (c == q) quote = null;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') {
            index.* += 1;
            return;
        }
    }
    return error.MalformedXml;
}

fn skipUntil(xml: []const u8, index: *usize, terminator: []const u8) !void {
    const end = std.mem.indexOfPos(u8, xml, index.*, terminator) orelse return error.MalformedXml;
    index.* = end + terminator.len;
}

fn parsePortValue(value: []const u8) !u16 {
    if (value.len == 0) return error.InvalidPort;
    for (value) |c| if (!std.ascii.isDigit(c)) return error.InvalidPort;
    const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}

fn parseSettingsStartTag(xml: []const u8, index: *usize) !SettingsPorts {
    // `index` points just after the exact element name `serversettings`.
    var ports = SettingsPorts{};
    while (true) {
        skipSpace(xml, index);
        if (index.* >= xml.len) return error.MalformedSettingsElement;
        if (xml[index.*] == '>') {
            index.* += 1;
            return ports;
        }
        if (xml[index.*] == '/' and index.* + 1 < xml.len and xml[index.* + 1] == '>') {
            index.* += 2;
            return ports;
        }
        if (!isNameStart(xml[index.*])) return error.MalformedSettingsAttribute;
        const name_start = index.*;
        index.* += 1;
        while (index.* < xml.len and isNameChar(xml[index.*])) : (index.* += 1) {}
        const name = xml[name_start..index.*];
        skipSpace(xml, index);
        if (index.* >= xml.len or xml[index.*] != '=') return error.MalformedSettingsAttribute;
        index.* += 1;
        skipSpace(xml, index);
        if (index.* >= xml.len or (xml[index.*] != '"' and xml[index.*] != '\'')) return error.MalformedSettingsAttribute;
        const quote = xml[index.*];
        index.* += 1;
        const value_start = index.*;
        while (index.* < xml.len and xml[index.*] != quote) : (index.* += 1) {
            if (xml[index.*] == '<') return error.MalformedSettingsAttribute;
        }
        if (index.* >= xml.len) return error.MalformedSettingsAttribute;
        const value = xml[value_start..index.*];
        index.* += 1;
        if (std.mem.eql(u8, name, "port")) {
            if (ports.game != null) return error.DuplicatePortAttribute;
            ports.game = try parsePortValue(value);
        } else if (std.mem.eql(u8, name, "queryport")) {
            if (ports.query != null) return error.DuplicatePortAttribute;
            ports.query = try parsePortValue(value);
        }
    }
}

fn parseServerSettingsPorts(xml: []const u8) !SettingsPorts {
    if (xml.len > MAX_OUTPUT) return error.InputTooLarge;
    var index: usize = 0;
    var found: ?SettingsPorts = null;
    while (index < xml.len) {
        const start = std.mem.indexOfScalarPos(u8, xml, index, '<') orelse break;
        index = start + 1;
        if (std.mem.startsWith(u8, xml[start..], "<!--")) {
            try skipUntil(xml, &index, "-->");
            continue;
        }
        if (std.mem.startsWith(u8, xml[start..], "<?")) {
            try skipUntil(xml, &index, "?>");
            continue;
        }
        if (std.mem.startsWith(u8, xml[start..], "<![CDATA[")) {
            try skipUntil(xml, &index, "]]>");
            continue;
        }
        if (index >= xml.len) return error.MalformedXml;
        if (xml[index] == '!' or xml[index] == '/') {
            try skipMarkup(xml, &index);
            continue;
        }
        if (!isNameStart(xml[index])) return error.MalformedXml;
        const name_start = index;
        index += 1;
        while (index < xml.len and isNameChar(xml[index])) : (index += 1) {}
        const name = xml[name_start..index];
        if (std.mem.eql(u8, name, "serversettings")) {
            if (found != null) return error.DuplicateSettingsElement;
            found = try parseSettingsStartTag(xml, &index);
        } else {
            try skipMarkup(xml, &index);
        }
    }
    return found orelse error.SettingsElementMissing;
}

fn configuredPorts(a: std.mem.Allocator, declaration: *const model.Instance) ![]const u16 {
    if (!declaration.capabilities.config.enabled) return &.{};
    if (declaration.paths.config.len == 0) return &.{};
    const xml = std.fs.cwd().readFileAlloc(a, declaration.paths.config[0], MAX_OUTPUT) catch return &.{};
    defer a.free(xml);
    const settings_ports = try parseServerSettingsPorts(xml);
    var ports: std.ArrayList(u16) = .empty;
    if (settings_ports.game) |port| try ports.append(a, port);
    if (settings_ports.query) |port| {
        if (ports.items.len == 0 or ports.items[0] != port) try ports.append(a, port);
    }
    return ports.toOwnedSlice(a);
}

fn parseUdpTable(a: std.mem.Allocator, text: []const u8) ![]const u16 {
    if (text.len > MAX_OUTPUT) return error.OutputTooLarge;
    var ports: std.ArrayList(u16) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var columns = std.mem.tokenizeAny(u8, line, " \t\r");
        _ = columns.next() orelse continue;
        const local = columns.next() orelse continue;
        const colon = std.mem.lastIndexOfScalar(u8, local, ':') orelse continue;
        const port = std.fmt.parseInt(u16, local[colon + 1 ..], 16) catch continue;
        var found = false;
        for (ports.items) |prior| if (prior == port) {
            found = true;
            break;
        };
        if (!found) try ports.append(a, port);
    }
    return ports.toOwnedSlice(a);
}

fn observedPorts(a: std.mem.Allocator, host_pid: ?u32) ![]const u16 {
    const pid = host_pid orelse return &.{};
    var ports: std.ArrayList(u16) = .empty;
    for ([_][]const u8{ "udp", "udp6" }) |table_name| {
        const path = try std.fmt.allocPrint(a, "/proc/{d}/net/{s}", .{ pid, table_name });
        defer a.free(path);
        const text = try std.fs.cwd().readFileAlloc(a, path, MAX_OUTPUT);
        defer a.free(text);
        const parsed = try parseUdpTable(a, text);
        defer a.free(parsed);
        for (parsed) |port| {
            var found = false;
            for (ports.items) |prior| if (prior == port) {
                found = true;
                break;
            };
            if (!found) try ports.append(a, port);
        }
    }
    return ports.toOwnedSlice(a);
}

fn sanitizeLogs(a: std.mem.Allocator, input: []const u8, requested: u16) ![]const u8 {
    const count: usize = @min(@as(usize, if (requested == 0) 1 else requested), MAX_LOG_LINES);
    var safe: std.ArrayList([]const u8) = .empty;
    defer safe.deinit(a);
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const lower = try std.ascii.allocLowerString(a, line);
        defer a.free(lower);
        var redact = false;
        for ([_][]const u8{ "password", "secret", "token", "credential", "api_key", "apikey", "steamid", "accountid", "private key" }) |needle| {
            if (std.mem.indexOf(u8, lower, needle) != null) redact = true;
        }
        // ANSI cursor/control lines can carry terminal queries or obscure a
        // secret marker; dropping these lines keeps the text projection plain.
        if (!redact and line.len > 0 and std.mem.indexOfScalar(u8, line, 0x1b) == null) try safe.append(a, line);
    }
    const start = safe.items.len -| count;
    var output: std.ArrayList(u8) = .empty;
    for (safe.items[start..], 0..) |line, index| {
        if (index > 0) try output.append(a, '\n');
        const amount = @min(line.len, MAX_OUTPUT -| output.items.len);
        try output.appendSlice(a, line[0..amount]);
        if (output.items.len == MAX_OUTPUT) break;
    }
    return output.toOwnedSlice(a);
}

fn combineLogStreams(a: std.mem.Allocator, stdout: []const u8, stderr: []const u8) ![]const u8 {
    if (stdout.len > MAX_OUTPUT or stderr.len > MAX_OUTPUT or stdout.len + stderr.len > MAX_OUTPUT) return error.OutputTooLarge;
    var combined: std.ArrayList(u8) = .empty;
    errdefer combined.deinit(a);
    try combined.appendSlice(a, stdout);
    if (stdout.len > 0 and stderr.len > 0 and stdout[stdout.len - 1] != '\n' and stderr[0] != '\n') try combined.append(a, '\n');
    if (combined.items.len + stderr.len > MAX_OUTPUT) return error.OutputTooLarge;
    try combined.appendSlice(a, stderr);
    return combined.toOwnedSlice(a);
}

fn runLogs(a: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32) ![]const u8 {
    var cancel = process.Cancel{};
    const result = try process.run(a, argv, false, timeout_ms, &cancel);
    defer a.free(result.output);
    defer a.free(result.error_output);
    // Podman may return a useful diagnostic on stderr with a nonzero exit.
    // Timeout, cancellation, transport, and output-limit failures remain errors.
    if ((result.status != .completed and result.status != .failed) or result.exit_code == null) return error.ReadCommandFailed;
    return combineLogStreams(a, result.output, result.error_output);
}

/// Collects from one locally accessible, explicitly selected Podman identity.
/// This performs reads only and never invokes a lifecycle command.
pub fn collect(a: std.mem.Allocator, snapshot: *const registry.Snapshot, id: []const u8, host_key: []const u8, requested_logs: ?u16) !Inspection {
    var temporary = std.heap.ArenaAllocator.init(a);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    const declaration = try snapshot.lookup(id);
    try validateRequest(declaration, id, host_key, requested_logs);
    const identity = declaration.runtime.identity;

    const template = "{{.Name}}|{{.Id}}|{{.Image}}|{{.State.Status}}|{{.State.Pid}}";
    const argv = [_][]const u8{ "podman", "inspect", "--format", template, identity };
    const raw = try run(scratch, &argv, 5000);
    defer scratch.free(raw);
    const evidence = try parseInspect(raw, identity);
    const pid: ?u32 = if (std.mem.eql(u8, evidence.state, "running")) try std.fmt.parseInt(u32, evidence.pid, 10) else null;
    const config_ports = try configuredPorts(scratch, declaration);
    const observed = try observedPorts(scratch, pid);
    var logs: ?[]const u8 = null;
    if (requested_logs) |line_count| {
        const lines = try std.fmt.allocPrint(scratch, "{d}", .{@min(@as(usize, if (line_count == 0) 1 else line_count), MAX_LOG_LINES)});
        const log_argv = [_][]const u8{ "podman", "logs", "--tail", lines, identity };
        const full = try runLogs(scratch, &log_argv, 5000);
        defer scratch.free(full);
        logs = try sanitizeLogs(scratch, full, line_count);
    }
    const final_raw = try run(scratch, &argv, 5000);
    defer scratch.free(final_raw);
    const final_evidence = try parseInspect(final_raw, identity);
    if (!sameContainer(evidence, final_evidence)) return error.ContainerChanged;

    const result_arena = try a.create(std.heap.ArenaAllocator);
    result_arena.* = std.heap.ArenaAllocator.init(a);
    const dest = result_arena.allocator();
    errdefer {
        result_arena.deinit();
        a.destroy(result_arena);
    }
    return .{
        .arena = result_arena,
        .owner = a,
        .instance_id = try dest.dupe(u8, declaration.id),
        .profile_id = try dest.dupe(u8, declaration.profile_id),
        .host = try dest.dupe(u8, declaration.host),
        .container = try dest.dupe(u8, evidence.name),
        .container_id = try dest.dupe(u8, evidence.id),
        .image_id = try dest.dupe(u8, evidence.image_id),
        .state = try dest.dupe(u8, evidence.state),
        .container_init_pid = pid,
        .sampled_at_unix_seconds = std.time.timestamp(),
        .evidence_source = "Podman inspect of declared container; IPv4 and IPv6 UDP tables read from /proc/<container MainPID>/net",
        .configured_ports = try dest.dupe(u16, config_ports),
        .observed_udp_ports = try dest.dupe(u16, observed),
        .data_paths = try copyStrings(dest, declaration.paths.data),
        .config_paths = try copyStrings(dest, declaration.paths.config),
        .world_paths = try copyStrings(dest, declaration.paths.world),
        .declared_game_version = try dest.dupe(u8, declaration.game.version),
        .readiness = null,
        .readiness_source = null,
        .logs = if (logs) |text| try dest.dupe(u8, text) else null,
    };
}

test "Barotrauma collector checks selected identity and capabilities before runtime reads" {
    const declaration: model.Instance = .{
        .id = "barotrauma-test",
        .profile_id = "barotrauma",
        .host = "wizardly-hellman",
        .runtime = .{ .type = .podman, .identity = "barotrauma-test" },
        .game = .{ .version = "1.12.7.0" },
        .capabilities = .{ .probe = .{ .enabled = true }, .config = .{ .enabled = true }, .logs = .{ .enabled = true } },
    };
    try validateRequest(&declaration, "barotrauma-test", "wizardly-hellman", null);
    try std.testing.expectError(error.InstanceMismatch, validateRequest(&declaration, "barotrauma-coop", "wizardly-hellman", null));
    try std.testing.expectError(error.HostMismatch, validateRequest(&declaration, "barotrauma-test", "elsewhere", null));
    var disabled_probe = declaration;
    disabled_probe.capabilities.probe.enabled = false;
    try std.testing.expectError(error.ProbeUnsupported, validateRequest(&disabled_probe, "barotrauma-test", "wizardly-hellman", null));
    var disabled_logs = declaration;
    disabled_logs.capabilities.logs.enabled = false;
    try std.testing.expectError(error.LogsUnsupported, validateRequest(&disabled_logs, "barotrauma-test", "wizardly-hellman", 20));
    try validateRequest(&disabled_logs, "barotrauma-test", "wizardly-hellman", null);
    try std.testing.expect(!validContainerName("--help"));
    try std.testing.expect(!validContainerName("container;id"));
    try std.testing.expect(validContainerName("barotrauma-test"));
    const text = "barotrauma-test|0123456789ab|0123456789ab|running|42";
    try std.testing.expectEqual(@as(u32, 42), try std.fmt.parseInt(u32, (try parseInspect(text, "barotrauma-test")).pid, 10));
    try std.testing.expectError(error.ContainerMismatch, parseInspect("other|0123456789ab|0123456789ab|running|42", "barotrauma-test"));
    for ([_][]const u8{ "configured", "created", "initialized", "running", "stopped", "paused", "exited", "stopping", "restarting", "removing", "dead", "unknown" }) |state| {
        const state_line = try std.fmt.allocPrint(std.testing.allocator, "barotrauma-test|0123456789ab|0123456789ab|{s}|42", .{state});
        defer std.testing.allocator.free(state_line);
        _ = try parseInspect(state_line, "barotrauma-test");
    }
    try std.testing.expectError(error.MalformedInspect, parseInspect("barotrauma-test|0123456789ab|0123456789ab|garbage|42", "barotrauma-test"));
    try std.testing.expectError(error.MalformedInspect, parseInspect("barotrauma-test|0123456789ab|0123456789ab|stopping-now|42", "barotrauma-test"));
    const before = try parseInspect("barotrauma-test|0123456789ab|0123456789ab|running|42", "barotrauma-test");
    const after = try parseInspect("barotrauma-test|0123456789ab|0123456789ab|exited|0", "barotrauma-test");
    try std.testing.expect(!sameContainer(before, after));
}

test "Barotrauma config projects configured UDP ports without exposing XML" {
    const xml = "<!-- port=\"1234\" --><root note=\"unrelated\">unrelated port=\"3456\"<other port=\"4567\"/><serversettings port=\"27015\" queryport='27016' password=\"must-not-leak\"/></root>";
    const ports_found = try parseServerSettingsPorts(xml);
    try std.testing.expectEqual(@as(?u16, 27015), ports_found.game);
    try std.testing.expectEqual(@as(?u16, 27016), ports_found.query);
    try std.testing.expectError(error.InvalidPort, parseServerSettingsPorts("<serversettings port=\"bad\"/>"));
    try std.testing.expectError(error.MalformedSettingsAttribute, parseServerSettingsPorts("<serversettings port=27015/>"));
    try std.testing.expectError(error.DuplicatePortAttribute, parseServerSettingsPorts("<serversettings port=\"27015\" port=\"25565\"/>"));
    try std.testing.expectError(error.DuplicateSettingsElement, parseServerSettingsPorts("<serversettings port=\"27015\"/><serversettings port=\"25565\"/>"));
    const a = std.testing.allocator;
    const disabled: model.Instance = .{
        .id = "barotrauma-test",
        .profile_id = "barotrauma",
        .host = "wizardly-hellman",
        .runtime = .{ .type = .podman, .identity = "barotrauma-test" },
        .paths = .{ .config = &.{"/definitely/missing/serversettings.xml"} },
        .game = .{ .version = "1.12.7.0" },
    };
    // A disabled config capability returns before opening even a missing path.
    const ports = try configuredPorts(a, &disabled);
    try std.testing.expectEqual(@as(usize, 0), ports.len);
}

test "Barotrauma logs are tail-bounded and secret-marked lines are omitted" {
    const safe = try sanitizeLogs(std.testing.allocator, "ready\nserver password=hidden\nSteamInternal_SetMinidumpSteamID=private\n\x1b[6n\nround ended\n", 2);
    defer std.testing.allocator.free(safe);
    try std.testing.expectEqualStrings("ready\nround ended", safe);
}

test "Barotrauma log projection keeps sanitized stderr diagnostics within the shared cap" {
    const a = std.testing.allocator;
    const stderr_only = try runLogs(a, &.{ "/bin/sh", "-c", "printf 'podman stderr-only diagnostic\\npassword=hidden\\nSteamID=private\\n' >&2; exit 1" }, 1000);
    defer a.free(stderr_only);
    const safe_stderr_only = try sanitizeLogs(a, stderr_only, 20);
    defer a.free(safe_stderr_only);
    try std.testing.expectEqualStrings("podman stderr-only diagnostic", safe_stderr_only);
    const combined = try combineLogStreams(a, "ordinary stdout", "podman stderr diagnostic\npassword=hidden\nSteamID=private");
    defer a.free(combined);
    const safe = try sanitizeLogs(a, combined, 20);
    defer a.free(safe);
    try std.testing.expectEqualStrings("ordinary stdout\npodman stderr diagnostic", safe);
    try std.testing.expectError(error.OutputTooLarge, combineLogStreams(a, &([_]u8{'a'} ** MAX_OUTPUT), "b"));
}

test "Barotrauma observed UDP evidence parses the selected container network namespace" {
    const table = "   sl  local_address rem_address   st\n 1128: 00000000000000000000000000000000:6987 00000000000000000000000000000000:0000 07\n";
    const ports = try parseUdpTable(std.testing.allocator, table);
    defer std.testing.allocator.free(ports);
    try std.testing.expectEqual(@as(usize, 1), ports.len);
    try std.testing.expectEqual(@as(u16, 27015), ports[0]);
    const table6 = "  sl  local_address                         remote_address                        st\n  374: 00000000000000000000000000000000:6987 00000000000000000000000000000000:0000 07\n";
    const ports6 = try parseUdpTable(std.testing.allocator, table6);
    defer std.testing.allocator.free(ports6);
    try std.testing.expectEqual(@as(usize, 1), ports6.len);
    try std.testing.expectEqual(@as(u16, 27015), ports6[0]);
}
