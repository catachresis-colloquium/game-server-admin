// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
// Fixture/internal inspection adapter. No process, network, registry or ABI imports.
const std = @import("std");
const systemd = @import("systemd_inspect.zig");
const Allocator = std.mem.Allocator;
pub const Source = enum { target, collector_clock, systemd_show, active_transition_and_clock, process_argv, server_properties, version_json, fabric_mod_json, fabric_server_artifact };
pub const Basis = enum { supplied, observed, configured, derived };
pub const Evidence = struct { source: Source, field: []const u8, basis: Basis };
pub fn Field(comptime T: type) type {
    return struct { value: T, evidence: Evidence };
}
fn field(comptime T: type, value: T, source: Source, name: []const u8, basis: Basis) Field(T) {
    return .{ .value = value, .evidence = .{ .source = source, .field = name, .basis = basis } };
}
pub const Listener = struct { address: ?[]const u8, port: ?u16 };
pub const Mod = struct { id: Field([]const u8), version: Field([]const u8) };
pub const Report = struct {
    instance_id: Field([]const u8),
    observed_at_unix_seconds: Field(i64),
    unit: Field([]const u8),
    load_state: Field(systemd.LoadState),
    active_state: Field(systemd.ActiveState),
    service_uptime_us: ?Field(u64) = null,
    working_directory: ?Field([]const u8) = null,
    listener: ?Field(Listener) = null,
    java_executable: ?Field([]const u8) = null,
    jvm_arguments: ?Field([]const []const u8),
    withheld_argument_count: ?Field(usize),
    minecraft_version: ?Field([]const u8) = null,
    fabric_loader_version: ?Field([]const u8) = null,
    mods: ?[]const Mod,
    config_path: ?Field([]const u8) = null,
    world_path: ?Field([]const u8) = null,
};
pub const Observation = struct {
    arena: std.heap.ArenaAllocator,
    report: Report,
    pub fn deinit(self: *Observation) void {
        self.arena.deinit();
    }
};

/// These are explicit evidence inputs, not paths to open or commands to run.
/// A later collector must tie process_argv to the selected unit's MainPID,
/// read CLOCK_MONOTONIC on that same host/boot, and bound every input.
pub const Input = struct {
    instance_id: []const u8,
    unit: []const u8,
    observed_at_unix_seconds: i64,
    monotonic_now_us: ?u64 = null,
    systemctl_show: []const u8,
    process_argv: []const []const u8 = &.{},
    server_properties: ?[]const u8 = null,
    version_json: ?[]const u8 = null,
    fabric_loader_version: ?[]const u8 = null,
    mod_metadata_json: []const []const u8 = &.{},
    mod_metadata_known: bool = true,
};

/// Owns only an allowlisted report. Never retains raw output/config/argv.
/// Unknown JVM arguments are withheld, not echoed, even in errors.
pub fn inspect(allocator: Allocator, input: Input) !Observation {
    if (!identifier(input.instance_id) or input.observed_at_unix_seconds < 0) return error.InvalidTarget;
    if (input.process_argv.len > 256 or input.mod_metadata_json.len > 1024) return error.InputTooLarge;
    const unit = try systemd.parse(input.systemctl_show, input.unit);
    if ((unit.load != .loaded or unit.active != .active) and input.process_argv.len > 0) return error.StaleProcessEvidence;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var args: std.ArrayList([]const u8) = .empty;
    var withheld: usize = 0;
    var java: ?Field([]const u8) = null;
    var accepting_jvm_args = false;
    // argv is a collector-provided vector, never shell-split ExecStart text.
    for (input.process_argv, 0..) |arg, i| {
        if (arg.len > 4096) return error.InputTooLarge;
        if (i == 0 and safePath(arg) and std.mem.eql(u8, std.fs.path.basename(arg), "java")) {
            java = field([]const u8, try a.dupe(u8, arg), .process_argv, "argv[0]", .observed);
            accepting_jvm_args = true;
        } else if (accepting_jvm_args and safeJvmArg(arg)) {
            try args.append(a, try a.dupe(u8, arg));
        } else {
            // An unknown option may take a value, or may end JVM options.
            // Do not mislabel later game/application tokens as JVM flags.
            accepting_jvm_args = false;
            withheld += 1;
        }
    }
    var mods: std.ArrayList(Mod) = .empty;
    var loader: ?Field([]const u8) = null;
    for (input.mod_metadata_json) |json| {
        const parsed = try parseJson(allocator, json);
        defer parsed.deinit();
        const value = parsed.value;
        const id = try jsonString(value, "id");
        const version = try jsonString(value, "version");
        if (!identifier(id) or !versionText(version)) return error.MalformedModMetadata;
        for (mods.items) |mod| if (std.mem.eql(u8, mod.id.value, id)) return error.DuplicateMod;
        try mods.append(a, .{ .id = field([]const u8, try a.dupe(u8, id), .fabric_mod_json, "id", .observed), .version = field([]const u8, try a.dupe(u8, version), .fabric_mod_json, "version", .observed) });
        if (std.mem.eql(u8, id, "fabricloader")) loader = field([]const u8, try a.dupe(u8, version), .fabric_mod_json, "fabricloader.version", .observed);
    }
    if (loader == null) if (input.fabric_loader_version) |version| {
        if (!versionText(version)) return error.MalformedVersionMetadata;
        loader = field([]const u8, try a.dupe(u8, version), .fabric_server_artifact, "fabric loader artifact version", .observed);
    };
    var report = Report{
        .instance_id = field([]const u8, try a.dupe(u8, input.instance_id), .target, "instance_id", .supplied),
        .observed_at_unix_seconds = field(i64, input.observed_at_unix_seconds, .collector_clock, "unix_seconds", .supplied),
        .unit = field([]const u8, try a.dupe(u8, unit.unit), .systemd_show, "Id", .observed),
        .load_state = field(systemd.LoadState, unit.load, .systemd_show, "LoadState", .observed),
        .active_state = field(systemd.ActiveState, unit.active, .systemd_show, "ActiveState", .observed),
        .java_executable = java,
        .jvm_arguments = if (input.process_argv.len > 0) field([]const []const u8, try args.toOwnedSlice(a), .process_argv, "allowlisted JVM flags", .observed) else null,
        .withheld_argument_count = if (input.process_argv.len > 0) field(usize, withheld, .process_argv, "withheld count", .derived) else null,
        .fabric_loader_version = loader,
        .mods = if (input.mod_metadata_known) try mods.toOwnedSlice(a) else null,
    };
    if (unit.load == .loaded and unit.active == .active) {
        if (unit.active_enter_us) |entered| {
            if (input.monotonic_now_us) |now| {
                if (now < entered) return error.InvalidClockSample;
                report.service_uptime_us = field(u64, now - entered, .active_transition_and_clock, "ActiveEnterTimestampMonotonic", .derived);
            }
        }
    }
    if (unit.working_directory) |dir| {
        if (!safePath(dir)) return error.InvalidPath;
        report.working_directory = field([]const u8, try a.dupe(u8, dir), .systemd_show, "WorkingDirectory", .observed);
        // Vanilla convention, explicitly inferred rather than discovered on disk.
        report.config_path = field([]const u8, try std.fmt.allocPrint(a, "{s}/server.properties", .{dir}), .systemd_show, "WorkingDirectory + server.properties", .derived);
    }
    if (input.version_json) |json| {
        const parsed = try parseJson(allocator, json);
        defer parsed.deinit();
        const value = parsed.value;
        const version = try jsonString(value, "id");
        if (!versionText(version)) return error.MalformedVersionMetadata;
        report.minecraft_version = field([]const u8, try a.dupe(u8, version), .version_json, "id", .observed);
    }
    if (input.server_properties) |properties| try projectProperties(a, properties, &report);
    return .{ .arena = arena, .report = report };
}

fn projectProperties(a: Allocator, input: []const u8, report: *Report) !void {
    if (input.len > 65536) return error.InputTooLarge;
    var seen: [3]bool = @splat(false);
    var address: ?[]const u8 = null;
    var port: ?u16 = null;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '!') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        for ([_][]const u8{ "server-ip", "server-port", "level-name" }, 0..) |allowed, i| {
            if (!std.mem.eql(u8, key, allowed)) continue;
            if (seen[i]) return error.DuplicateProperty;
            seen[i] = true;
            switch (i) {
                0 => {
                    // Empty binding means game-defined wildcard; retain empty
                    // rather than pretending an observed socket exists.
                    if (value.len > 255) return error.InvalidListener;
                    for (value) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, ".:[]-", c) == null) return error.InvalidListener;
                    address = if (value.len == 0) null else try a.dupe(u8, value);
                },
                1 => {
                    port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidListener;
                    if (port.? == 0) return error.InvalidListener;
                },
                2 => {
                    if (!identifier(value)) return error.InvalidWorldPath;
                    if (report.working_directory) |dir| report.world_path = field([]const u8, try std.fmt.allocPrint(a, "{s}/{s}", .{ dir.value, value }), .server_properties, "level-name relative to WorkingDirectory", .derived);
                },
                else => unreachable,
            }
        }
    }
    if (seen[0] or seen[1]) report.listener = field(Listener, .{ .address = address, .port = port }, .server_properties, "server-ip/server-port (configured, not socket verified)", .configured);
}

fn parseJson(a: Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    if (json.len > 65536) return error.InputTooLarge;
    return std.json.parseFromSlice(std.json.Value, a, json, .{});
}
fn jsonString(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.MalformedMetadata;
    const member = value.object.get(key) orelse return error.MalformedMetadata;
    if (member != .string) return error.MalformedMetadata;
    return member.string;
}
fn identifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}
fn versionText(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, ".+_-", c) == null) return false;
    return true;
}
fn safePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096 or path[0] != '/') return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    for (path) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "/._-", c) == null) return false;
    return true;
}
fn safeJvmArg(arg: []const u8) bool {
    for ([_][]const u8{ "-XX:+UseG1GC", "-XX:+UseZGC", "-XX:+UseParallelGC", "-XX:+AlwaysPreTouch" }) |allowed| if (std.mem.eql(u8, arg, allowed)) return true;
    if (arg.len < 6 or (!std.mem.startsWith(u8, arg, "-Xms") and !std.mem.startsWith(u8, arg, "-Xmx"))) return false;
    const number = arg[4 .. arg.len - 1];
    if (number.len == 0 or number.len > 15 or number[0] < '1' or number[0] > '9') return false;
    for (number) |c| if (!std.ascii.isDigit(c)) return false;
    return std.mem.indexOfScalar(u8, "kKmMgG", arg[arg.len - 1]) != null;
}

fn readFixture(name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(std.testing.allocator, "fixtures/minecraft-systemd-readonly/{s}.json", .{name});
    defer std.testing.allocator.free(path);
    return std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024);
}

test "Minecraft inspection: active unit projects evidence and withholds secrets" {
    const a = std.testing.allocator;
    const bytes = try readFixture("active");
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Input, a, bytes, .{});
    defer parsed.deinit();
    var observation = try inspect(a, parsed.value);
    defer observation.deinit();
    const r = observation.report;
    try std.testing.expectEqual(.active, r.active_state.value);
    try std.testing.expectEqual(@as(u64, 10000000), r.service_uptime_us.?.value);
    try std.testing.expectEqualStrings("minecraft-survival.service", r.unit.value);
    try std.testing.expectEqualStrings("/srv/fixture/minecraft-survival", r.working_directory.?.value);
    try std.testing.expectEqual(@as(?u16, 25565), r.listener.?.value.port);
    try std.testing.expectEqualStrings("127.0.0.1", r.listener.?.value.address.?);
    try std.testing.expectEqual(.configured, r.listener.?.evidence.basis);
    try std.testing.expectEqualStrings("/usr/bin/java", r.java_executable.?.value);
    try std.testing.expectEqual(@as(usize, 3), r.jvm_arguments.?.value.len);
    try std.testing.expectEqual(@as(usize, 4), r.withheld_argument_count.?.value);
    try std.testing.expectEqualStrings("1.21.11", r.minecraft_version.?.value);
    try std.testing.expectEqualStrings("0.18.1", r.fabric_loader_version.?.value);
    try std.testing.expectEqual(@as(usize, 2), r.mods.?.len);
    try std.testing.expectEqualStrings("lithium", r.mods.?[1].id.value);
    try std.testing.expectEqual(.fabric_mod_json, r.mods.?[1].version.evidence.source);
    try std.testing.expectEqualStrings("/srv/fixture/minecraft-survival/server.properties", r.config_path.?.value);
    try std.testing.expectEqualStrings("/srv/fixture/minecraft-survival/world", r.world_path.?.value);
    const output = try std.json.Stringify.valueAlloc(a, r, .{});
    defer a.free(output);
    for ([_][]const u8{ "secret-canary", "rcon.password", "Environment", "resource-pack", "-Dpassword", "fabric-server-launch.jar" }) |secret| try std.testing.expect(std.mem.indexOf(u8, output, secret) == null);
    @memset(bytes, 'x');
    try std.testing.expectEqualStrings("1.21.11", r.minecraft_version.?.value);
}

test "Minecraft inspection: inactive, missing and absent optional evidence" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "inactive", "missing", "minimal" }) |name| {
        const bytes = try readFixture(name);
        defer a.free(bytes);
        const parsed = try std.json.parseFromSlice(Input, a, bytes, .{});
        defer parsed.deinit();
        var observation = try inspect(a, parsed.value);
        defer observation.deinit();
        const r = observation.report;
        if (std.mem.eql(u8, name, "missing")) try std.testing.expectEqual(.@"not-found", r.load_state.value);
        if (!std.mem.eql(u8, name, "minimal")) try std.testing.expectEqual(.inactive, r.active_state.value);
        try std.testing.expect(r.jvm_arguments == null and r.withheld_argument_count == null);
        try std.testing.expect(r.service_uptime_us == null and r.working_directory == null and r.listener == null and r.minecraft_version == null and r.fabric_loader_version == null and r.config_path == null and r.world_path == null);
        try std.testing.expectEqual(@as(usize, 0), r.mods.?.len);
    }
}

test "Minecraft inspection represents unavailable mod inventory as unknown" {
    var observation = try inspect(std.testing.allocator, .{
        .instance_id = "minecraft-survival",
        .unit = "minecraft.service",
        .observed_at_unix_seconds = 1,
        .systemctl_show = "Id=minecraft.service\nLoadState=loaded\nActiveState=inactive\n",
        .mod_metadata_known = false,
    });
    defer observation.deinit();
    try std.testing.expect(observation.report.mods == null);
}

test "Minecraft inspection keeps active process metadata unknown when proc evidence is absent" {
    var observation = try inspect(std.testing.allocator, .{
        .instance_id = "minecraft-survival",
        .unit = "minecraft.service",
        .observed_at_unix_seconds = 1,
        .systemctl_show = "Id=minecraft.service\nLoadState=loaded\nActiveState=active\nMainPID=746\nInvocationID=opaque\n",
        .mod_metadata_known = false,
    });
    defer observation.deinit();
    try std.testing.expectEqual(.active, observation.report.active_state.value);
    try std.testing.expect(observation.report.java_executable == null);
    try std.testing.expect(observation.report.jvm_arguments == null);
    try std.testing.expect(observation.report.mods == null);
}

test "Minecraft inspection preserves an unspecified configured bind address as unknown" {
    const a = std.testing.allocator;
    var observation = try inspect(a, .{
        .instance_id = "minecraft-survival",
        .unit = "minecraft.service",
        .observed_at_unix_seconds = 1,
        .systemctl_show = "Id=minecraft.service\nLoadState=loaded\nActiveState=inactive\nWorkingDirectory=/opt/minecraft-server\nActiveEnterTimestampMonotonic=0\n",
        .server_properties = "server-ip=\nserver-port=25565\nlevel-name=world\n",
    });
    defer observation.deinit();
    try std.testing.expect(observation.report.listener != null);
    try std.testing.expect(observation.report.listener.?.value.address == null);
    try std.testing.expectEqual(@as(?u16, 25565), observation.report.listener.?.value.port);
}

test "Minecraft inspection: malformed evidence fails without echoing raw input" {
    const a = std.testing.allocator;
    const valid = Input{ .instance_id = "mc", .unit = "mc.service", .observed_at_unix_seconds = 1792929600, .systemctl_show = "Id=mc.service\nLoadState=loaded\nActiveState=active\nWorkingDirectory=/srv/mc\nActiveEnterTimestampMonotonic=20" };
    var input = valid;
    input.systemctl_show = "malformed secret-canary";
    try std.testing.expectError(error.MalformedSystemdOutput, inspect(a, input));
    input = valid;
    input.monotonic_now_us = 10;
    try std.testing.expectError(error.InvalidClockSample, inspect(a, input));
    input = valid;
    input.mod_metadata_json = &.{"{\"id\":\"lithium\",\"version\":false}"};
    try std.testing.expectError(error.MalformedMetadata, inspect(a, input));
    input.mod_metadata_json = &.{ "{\"id\":\"lithium\",\"version\":\"1\"}", "{\"id\":\"lithium\",\"version\":\"2\"}" };
    try std.testing.expectError(error.DuplicateMod, inspect(a, input));
    input = valid;
    input.server_properties = "server-port=65536";
    try std.testing.expectError(error.InvalidListener, inspect(a, input));
    input.server_properties = "server-port=25565\nserver-port=25566";
    try std.testing.expectError(error.DuplicateProperty, inspect(a, input));
    input.server_properties = "level-name=../../secrets";
    try std.testing.expectError(error.InvalidWorldPath, inspect(a, input));
    input = valid;
    input.systemctl_show = "Id=mc.service\nLoadState=loaded\nActiveState=inactive";
    input.process_argv = &.{"/usr/bin/java"};
    try std.testing.expectError(error.StaleProcessEvidence, inspect(a, input));
}

test "Minecraft inspection: arbitrary JVM arguments never become commands or output" {
    var observation = try inspect(std.testing.allocator, .{
        .instance_id = "minecraft-survival",
        .unit = "mc.service",
        .observed_at_unix_seconds = 1792929600,
        .systemctl_show = "Id=mc.service\nLoadState=loaded\nActiveState=active",
        .process_argv = &.{ "/usr/bin/java", "-Xmx2G;touch /tmp/gsa-must-not-exist", "-javaagent:secret-canary", "-Dtoken=secret-canary", "start", "stop", "restart" },
    });
    defer observation.deinit();
    try std.testing.expectEqual(@as(usize, 0), observation.report.jvm_arguments.?.value.len);
    try std.testing.expectEqual(@as(usize, 6), observation.report.withheld_argument_count.?.value);
    // Neither this adapter nor the helper contains an executor or callback.
    const argv = try systemd.showArguments("mc.service");
    try std.testing.expectEqualStrings("show", argv[1]);
    var after_jar = try inspect(std.testing.allocator, .{
        .instance_id = "mc",
        .unit = "mc.service",
        .observed_at_unix_seconds = 1792929600,
        .systemctl_show = "Id=mc.service\nLoadState=loaded\nActiveState=active",
        .process_argv = &.{ "/usr/bin/java", "-jar", "server.jar", "-Xmx2G" },
    });
    defer after_jar.deinit();
    try std.testing.expectEqual(@as(usize, 0), after_jar.report.jvm_arguments.?.value.len);
}
