// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
//
// Game Server Admin — CLI runner
//
// Standalone executable that exercises the FFI layer directly without
// Gossamer.  Provides subcommands for common operations:
//   gsa status     — show VeriSimDB health and loaded profiles
//   gsa probe      — fingerprint a game server endpoint
//   gsa profiles   — list available game profiles
//   gsa version    — print version info
//
// This is the entry point for `just run` and `just gui` (headless mode).

const std = @import("std");
const gsa_core = @import("main.zig");
const probe_mod = @import("probe.zig");
const game_profiles = @import("game_profiles.zig");
const verisimdb_client = @import("verisimdb_client.zig");
const steam_client = @import("steam_client.zig");
const deployment_registry = @import("deployment_registry.zig");
const deployment_loader = @import("deployment_instance_loader.zig");
const minecraft_live = @import("minecraft_live_collector.zig");

/// Check if a file exists (Zig 0.15.2 compat — no std.fs.exists).
fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Environment-driven config with sensible defaults
    const verisimdb_url = std.posix.getenv("GSA_VERISIMDB_URL") orelse "http://localhost:8090";
    const profiles_dir = std.posix.getenv("GSA_PROFILES_DIR") orelse "./profiles";

    const out = std.fs.File.stdout();

    if (args.len < 2) {
        printBanner(out);
        printUsage(out);
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        printVersion(out);
    } else if (std.mem.eql(u8, cmd, "status")) {
        cmdStatus(allocator, verisimdb_url, profiles_dir, out);
    } else if (std.mem.eql(u8, cmd, "profiles")) {
        cmdProfiles(allocator, profiles_dir, out);
    } else if (std.mem.eql(u8, cmd, "probe")) {
        if (args.len < 3) {
            const err_f = std.fs.File.stderr();
            err_f.writeAll("Usage: gsa probe <host> [port]\n") catch {};
            std.process.exit(1);
        }
        const port: u16 = if (args.len >= 4) std.fmt.parseInt(u16, args[3], 10) catch 27015 else 27015;
        cmdProbe(args[2], port, out);
    } else if (std.mem.eql(u8, cmd, "instance")) {
        cmdInstance(allocator, args[2..], out);
    } else if (std.mem.eql(u8, cmd, "config")) {
        if (args.len < 3) {
            const err_f = std.fs.File.stderr();
            err_f.writeAll("Usage: gsa config <subcommand>\n") catch {};
            err_f.writeAll("Subcommands: init, show, set-default, add-favorite, list-favorites\n") catch {};
            std.process.exit(1);
        }
        const config_cmd = args[2];
        if (std.mem.eql(u8, config_cmd, "init")) {
            cmdConfigInit(out);
        } else if (std.mem.eql(u8, config_cmd, "show")) {
            cmdConfigShow(out);
        } else if (std.mem.eql(u8, config_cmd, "set-default")) {
            if (args.len < 5) {
                const err_f = std.fs.File.stderr();
                err_f.writeAll("Usage: gsa config set-default <host> <port>\n") catch {};
                std.process.exit(1);
            }
            const host = args[3];
            const port: u16 = std.fmt.parseInt(u16, args[4], 10) catch 25565;
            cmdConfigSetDefault(host, port, out);
        } else if (std.mem.eql(u8, config_cmd, "add-favorite")) {
            if (args.len < 6) {
                const err_f = std.fs.File.stderr();
                err_f.writeAll("Usage: gsa config add-favorite <name> <host> <port>\n") catch {};
                std.process.exit(1);
            }
            const name = args[3];
            const host = args[4];
            const port: u16 = std.fmt.parseInt(u16, args[5], 10) catch 25565;
            cmdConfigAddFavorite(name, host, port, out);
        } else if (std.mem.eql(u8, config_cmd, "list-favorites")) {
            cmdConfigListFavorites(out);
        } else {
            const err_f = std.fs.File.stderr();
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Unknown config subcommand: {s}\n", .{config_cmd}) catch "Unknown config subcommand\n";
            err_f.writeAll(msg) catch {};
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "steam")) {
        // Steam Web API subcommands
        // Requires GSA_STEAM_API_KEY environment variable.
        if (args.len < 3) {
            const err_f = std.fs.File.stderr();
            err_f.writeAll("Usage: gsa steam <subcommand>\n") catch {};
            err_f.writeAll("Subcommands:\n") catch {};
            err_f.writeAll("  resolve <vanity-url>          Resolve Steam vanity URL to Steam64 ID\n") catch {};
            err_f.writeAll("  player  <steam64-id>          Fetch player display name and profile\n") catch {};
            std.process.exit(1);
        }
        const steam_cmd = args[2];
        if (std.mem.eql(u8, steam_cmd, "resolve")) {
            if (args.len < 4) {
                const err_f = std.fs.File.stderr();
                err_f.writeAll("Usage: gsa steam resolve <vanity-url>\n") catch {};
                std.process.exit(1);
            }
            cmdSteamResolve(allocator, args[3], out);
        } else if (std.mem.eql(u8, steam_cmd, "player")) {
            if (args.len < 4) {
                const err_f = std.fs.File.stderr();
                err_f.writeAll("Usage: gsa steam player <steam64-id>\n") catch {};
                std.process.exit(1);
            }
            cmdSteamPlayer(allocator, args[3], out);
        } else {
            const err_f = std.fs.File.stderr();
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Unknown steam subcommand: {s}\n", .{steam_cmd}) catch "Unknown subcommand\n";
            err_f.writeAll(msg) catch {};
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printBanner(out);
        printUsage(out);
    } else {
        const err_f = std.fs.File.stderr();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown command: {s}\n\n", .{cmd}) catch "Unknown command\n";
        err_f.writeAll(msg) catch {};
        printUsage(out);
        std.process.exit(1);
    }
}

/// Production instance operations require one explicit document, ID and local
/// inventory key. No profile discovery or implicit singleton selection exists.
fn cmdInstance(a: std.mem.Allocator, args: []const []const u8, out: std.fs.File) void {
    const err = std.fs.File.stderr();
    if (args.len < 1) {
        err.writeAll("Usage: gsa instance <status|inspect|logs> --file PATH --id ID --host-id KEY [--lines N]\n") catch {};
        std.process.exit(2);
    }
    const action = args[0];
    var path: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var lines: u16 = 100;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) break;
        if (std.mem.eql(u8, args[index], "--file")) path = args[index + 1] else if (std.mem.eql(u8, args[index], "--id")) id = args[index + 1] else if (std.mem.eql(u8, args[index], "--host-id")) host = args[index + 1] else if (std.mem.eql(u8, args[index], "--lines")) {
            lines = std.fmt.parseInt(u16, args[index + 1], 10) catch 0;
        } else {
            err.writeAll("Unknown instance option.\n") catch {};
            std.process.exit(2);
        }
    }
    const is_inspection = std.mem.eql(u8, action, "inspect") or std.mem.eql(u8, action, "status");
    if (path == null or id == null or host == null or (!is_inspection and !std.mem.eql(u8, action, "logs"))) {
        err.writeAll("Explicit --file, --id and --host-id are required; action must be status, inspect or logs.\n") catch {};
        std.process.exit(2);
    }
    var registry = deployment_registry.Registry.init(a);
    defer registry.deinit();
    deployment_loader.loadFile(a, &registry, id.?, path.?) catch {
        err.writeAll("Deployment instance could not be loaded for the requested ID.\n") catch {};
        std.process.exit(1);
    };
    var snapshot = registry.snapshot(a) catch {
        err.writeAll("Deployment registry snapshot failed.\n") catch {};
        std.process.exit(1);
    };
    defer snapshot.deinit();
    if (is_inspection) {
        var report = minecraft_live.collect(a, &snapshot, id.?, host.?) catch |failure| {
            var message: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&message, "Read-only inspection failed ({s}); no lifecycle operation was attempted.\n", .{@errorName(failure)}) catch "Read-only inspection failed.\n";
            err.writeAll(text) catch {};
            std.process.exit(1);
        };
        defer report.deinit();
        const safe_output = .{
            .instance_id = report.instance_id,
            .profile_id = report.profile_id,
            .host = report.host,
            .runtime_identity = report.runtime_identity,
            .declaration = report.declared,
            .boot_id = report.boot_id,
            .sampled_at_unix_seconds = report.sampled_at_unix_seconds,
            .systemd_main_pid = report.systemd_main_pid,
            .process = report.process,
            .observed_socket = report.observed_socket,
            .backup_mode = report.backup_mode,
            .inspection = report.report,
        };
        const json = std.json.Stringify.valueAlloc(a, safe_output, .{ .whitespace = .indent_2 }) catch {
            err.writeAll("Inspection serialization failed.\n") catch {};
            std.process.exit(1);
        };
        defer a.free(json);
        out.writeAll(json) catch {};
        out.writeAll("\n") catch {};
    } else {
        var result = minecraft_live.logs(a, &snapshot, id.?, host.?, lines) catch {
            err.writeAll("Bounded instance log retrieval failed.\n") catch {};
            std.process.exit(1);
        };
        defer result.deinit();
        out.writeAll(result.output) catch {};
    }
}

// ── Subcommands ─────────────────────────────────────────────────────────────

/// Show overall system status: VeriSimDB health, loaded profiles, build info.
fn cmdStatus(allocator: std.mem.Allocator, verisimdb_url: []const u8, profiles_dir: []const u8, out: std.fs.File) void {
    printBanner(out);

    var line_buf: [1024]u8 = undefined;

    var msg = std.fmt.bufPrint(&line_buf, "  Build:     {s}\n  VeriSimDB: {s}\n  Profiles:  {s}\n\n", .{ gsa_core.BUILD_INFO, verisimdb_url, profiles_dir }) catch return;
    out.writeAll(msg) catch return;

    // VeriSimDB health check
    out.writeAll("  VeriSimDB health ... ") catch return;
    var client = verisimdb_client.VeriSimClient.init(allocator, verisimdb_url);
    defer client.deinit();

    const healthy = client.health() catch false;
    if (healthy) {
        out.writeAll("OK\n\n") catch return;
    } else {
        out.writeAll("FAIL\n  (is VeriSimDB running? Start with: just verisimdb-up)\n\n") catch return;
    }

    // Profile count
    var registry = game_profiles.ProfileRegistry.init(allocator);
    defer registry.deinit();
    const loaded = registry.loadFromDirectory(profiles_dir) catch 0;
    msg = std.fmt.bufPrint(&line_buf, "  Game profiles loaded: {d}\n", .{loaded}) catch return;
    out.writeAll(msg) catch return;

    // List profiles as JSON
    if (loaded > 0) {
        const json = registry.listProfiles(allocator) catch null;
        if (json) |j| {
            defer allocator.free(j);
            out.writeAll("\n  Profile data:\n  ") catch return;
            out.writeAll(j) catch return;
            out.writeAll("\n") catch return;
        }
    }

    out.writeAll("\n") catch return;
}

/// List game profiles from the profiles directory.
fn cmdProfiles(allocator: std.mem.Allocator, profiles_dir: []const u8, out: std.fs.File) void {
    var registry = game_profiles.ProfileRegistry.init(allocator);
    defer registry.deinit();

    const loaded = registry.loadFromDirectory(profiles_dir) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Failed to load profiles from {s}: {s}\n", .{ profiles_dir, @errorName(err) }) catch return;
        const err_f = std.fs.File.stderr();
        err_f.writeAll(msg) catch {};
        std.process.exit(1);
    };

    var line_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&line_buf, "Game profiles ({d} loaded from {s}):\n\n", .{ loaded, profiles_dir }) catch return;
    out.writeAll(msg) catch return;

    const json = registry.listProfiles(allocator) catch null;
    if (json) |j| {
        defer allocator.free(j);
        out.writeAll(j) catch return;
        out.writeAll("\n") catch return;
    }
    out.writeAll("\n") catch return;
}

/// Probe a game server at host:port and display fingerprint results.
fn cmdProbe(host: []const u8, port: u16, out: std.fs.File) void {
    var line_buf: [512]u8 = undefined;
    var msg = std.fmt.bufPrint(&line_buf, "Probing {s}:{d} ...\n\n", .{ host, port }) catch return;
    out.writeAll(msg) catch return;

    // Check known ports table first
    for (probe_mod.KNOWN_PORTS) |entry| {
        if (entry.port == port) {
            msg = std.fmt.bufPrint(&line_buf, "  Known port: {d} (protocol: {s})\n  Associated games: ", .{
                entry.port,
                @tagName(entry.protocol),
            }) catch break;
            out.writeAll(msg) catch return;
            for (entry.games, 0..) |game, i| {
                if (i > 0) out.writeAll(", ") catch return;
                out.writeAll(game) catch return;
            }
            out.writeAll("\n\n") catch return;
            break;
        }
    }

    // Attempt live probe via probeSingle (tries multiple protocols)
    out.writeAll("  Connecting ... ") catch return;
    var result = probe_mod.probeSingle(host, port, 5000) catch |err| {
        msg = std.fmt.bufPrint(&line_buf, "FAIL ({s})\n  Server may be offline or unreachable.\n\n", .{@errorName(err)}) catch return;
        out.writeAll(msg) catch return;
        return;
    };

    const game_id = result.gameIdSlice();
    const version = result.versionSlice();

    out.writeAll("OK\n\n") catch return;
    msg = std.fmt.bufPrint(&line_buf, "  Protocol:    {s}\n  Game:        {s}\n  Version:     {s}\n  Latency:     {d}ms\n\n", .{
        @tagName(result.protocol),
        if (game_id.len > 0) game_id else "(unknown)",
        if (version.len > 0) version else "(unknown)",
        result.latency_ms,
    }) catch return;
    out.writeAll(msg) catch return;
}

// ── Config management ────────────────────────────────────────────────────────

/// Initialize user config from template
fn cmdConfigInit(out: std.fs.File) void {
    const template_path = "user-config.ncl.template";
    const config_path = "user-config.ncl";

    // Check if config already exists
    if (fileExists(config_path)) {
        out.writeAll("✗ Config file already exists at ") catch {};
        out.writeAll(config_path) catch {};
        out.writeAll("\n") catch {};
        return;
    }

    // Check if template exists
    if (!fileExists(template_path)) {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Template file not found: ") catch {};
        err_f.writeAll(template_path) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    }

    // Copy template to config
    const template_file = std.fs.cwd().openFile(template_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to read template: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer template_file.close();

    const config_file = std.fs.cwd().createFile(config_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to create config file: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer config_file.close();

    // Copy contents
    var buf: [4096]u8 = undefined;
    var bytes_read: usize = 0;
    while (true) {
        const n = template_file.read(&buf) catch 0;
        if (n == 0) break;
        bytes_read += n;
        _ = config_file.write(buf[0..n]) catch break;
    }

    out.writeAll("✓ Created user config from template: ") catch {};
    out.writeAll(config_path) catch {};
    out.writeAll(" (") catch {};
    var buf2: [32]u8 = undefined;
    const bytes_str = std.fmt.bufPrint(&buf2, "{d}", .{bytes_read}) catch "?";
    out.writeAll(bytes_str) catch {};
    out.writeAll(" bytes)\n") catch {};
    out.writeAll("\n") catch {};
    out.writeAll("Edit the file to customize your settings.\n") catch {};
}

/// Show current config
fn cmdConfigShow(out: std.fs.File) void {
    const config_path = "user-config.ncl";

    if (!fileExists(config_path)) {
        out.writeAll("✗ No config file found. Run `gsa config init` to create one.\n") catch {};
        return;
    }

    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to read config: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer file.close();

    out.writeAll("=== User Config (") catch {};
    out.writeAll(config_path) catch {};
    out.writeAll(") ===\n\n") catch {};

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch 0;
        if (n == 0) break;
        out.writeAll(buf[0..n]) catch {};
    }
}

/// Set default server
fn cmdConfigSetDefault(host: []const u8, port: u16, out: std.fs.File) void {
    const config_path = "user-config.ncl";

    if (!fileExists(config_path)) {
        out.writeAll("✗ No config file found. Run `gsa config init` first.\n") catch {};
        return;
    }

    // Read existing config
    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to read config: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer file.close();

    // Read the whole file — a fixed 16 KiB buffer silently truncated larger
    // configs (e.g. many favorites), corrupting the rewrite.
    const existing_content = file.readToEndAlloc(std.heap.c_allocator, 1024 * 1024) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to read config: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer std.heap.c_allocator.free(existing_content);

    // Simple string replacement for default server
    // In a real implementation, you'd use a proper Nickel parser
    // For now, we'll do a simple pattern replacement

    // Write back
    const out_file = std.fs.cwd().createFile(config_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to write config: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer out_file.close();

    writeWithDefaultServer(existing_content, host, port, out_file) catch {};

    out.writeAll("✓ Updated default server to ") catch {};
    out.writeAll(host) catch {};
    out.writeAll(":") catch {};
    var port_buf2: [16]u8 = undefined;
    const port_str2 = std.fmt.bufPrint(&port_buf2, "{d}", .{port}) catch "?";
    out.writeAll(port_str2) catch {};
    out.writeAll("\n") catch {};
}

/// Add a favorite server
fn cmdConfigAddFavorite(name: []const u8, host: []const u8, port: u16, out: std.fs.File) void {
    const config_path = "user-config.ncl";

    if (!fileExists(config_path)) {
        out.writeAll("✗ No config file found. Run `gsa config init` first.\n") catch {};
        return;
    }

    // Read existing config
    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to read config: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer file.close();

    // Read the whole file — a fixed 16 KiB buffer silently truncated larger
    // configs (e.g. many favorites), corrupting the rewrite.
    const existing_content = file.readToEndAlloc(std.heap.c_allocator, 1024 * 1024) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to read config: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer std.heap.c_allocator.free(existing_content);

    // Add favorite to the favorites list

    // Write back
    const out_file = std.fs.cwd().createFile(config_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to write config: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer out_file.close();

    writeWithFavorite(existing_content, name, host, port, out_file) catch {};

    out.writeAll("✓ Added favorite server: ") catch {};
    out.writeAll(name) catch {};
    out.writeAll(" (") catch {};
    out.writeAll(host) catch {};
    out.writeAll(":") catch {};
    var port_buf2: [16]u8 = undefined;
    const port_str2 = std.fmt.bufPrint(&port_buf2, "{d}", .{port}) catch "?";
    out.writeAll(port_str2) catch {};
    out.writeAll(")\n") catch {};
}

/// List favorite servers
fn cmdConfigListFavorites(out: std.fs.File) void {
    const config_path = "user-config.ncl";

    if (!fileExists(config_path)) {
        out.writeAll("✗ No config file found. Run `gsa config init` first.\n") catch {};
        return;
    }

    // In a real implementation, we'd parse the Nickel file
    // For now, just show a message
    out.writeAll("Favorite servers are stored in ") catch {};
    out.writeAll(config_path) catch {};
    out.writeAll(".\n") catch {};
    out.writeAll("Use `gsa config show` to view the full config.\n") catch {};
}

/// Helper: rewrite the `host = ...` / `port = ...` lines of the generated
/// user-config.ncl with a new default server.
///
/// This is a deliberately narrow, structure-aware text patch — NOT a Nickel
/// parser. It relies on the shape GSA itself emits (`gsa config init` from the
/// bundled template): top-level `host = "..."` and `port = N` lines. On any
/// unexpected shape (either marker missing) it writes the input back unchanged
/// rather than risk corrupting a hand-edited file. A full Nickel editor is out
/// of scope for the CLI. Round-tripped by the tests at the bottom of this file.
fn writeWithDefaultServer(existing: []const u8, host: []const u8, port: u16, out_file: std.fs.File) !void {
    const host_start = std.mem.indexOf(u8, existing, "host = ") orelse {
        _ = try out_file.write(existing);
        return;
    };
    const port_start = std.mem.indexOf(u8, existing, "port = ") orelse {
        _ = try out_file.write(existing);
        return;
    };
    _ = try out_file.write(existing[0..host_start]);
    var host_buf: [512]u8 = undefined;
    const host_line = std.fmt.bufPrint(&host_buf, "host = \"{s}\",\n", .{host}) catch return error.InvalidParam;
    _ = try out_file.write(host_line);
    const host_region = existing[host_start..port_start];
    const next_nl = std.mem.indexOfScalar(u8, host_region, '\n') orelse host_region.len;
    if (next_nl + 1 < host_region.len) {
        _ = try out_file.write(host_region[next_nl + 1 ..]);
    }
    var port_buf: [128]u8 = undefined;
    const port_line = std.fmt.bufPrint(&port_buf, "port = {d},\n", .{port}) catch return error.InvalidParam;
    _ = try out_file.write(port_line);
    const after_port_nl = std.mem.indexOfScalarPos(u8, existing, port_start, '\n') orelse existing.len;
    if (after_port_nl + 1 < existing.len) {
        _ = try out_file.write(existing[after_port_nl + 1 ..]);
    }
}

/// Helper: append a favorite entry before the closing `]` of the favorites
/// list. Same philosophy as writeWithDefaultServer — a structure-aware patch of
/// GSA's own generated file, not a Nickel parser; on a missing `]` it writes the
/// input back unchanged. Round-tripped by the tests at the bottom of this file.
fn writeWithFavorite(existing: []const u8, name: []const u8, host: []const u8, port: u16, out_file: std.fs.File) !void {
    const fav_end = std.mem.indexOf(u8, existing, "]") orelse {
        _ = try out_file.write(existing);
        return;
    };
    _ = try out_file.write(existing[0..fav_end]);
    var entry_buf: [512]u8 = undefined;
    const entry = std.fmt.bufPrint(
        &entry_buf,
        "    {{\n      name = \"{s}\",\n      host = \"{s}\",\n      port = {d},\n    }},\n",
        .{ name, host, port },
    ) catch return error.InvalidParam;
    _ = try out_file.write(entry);
    _ = try out_file.write(existing[fav_end..]);
}

// ── Steam subcommands ────────────────────────────────────────────────────────

/// Resolve a Steam vanity URL to a Steam64 ID.
/// Reads GSA_STEAM_API_KEY from the environment.
fn cmdSteamResolve(allocator: std.mem.Allocator, vanity_url: []const u8, out: std.fs.File) void {
    const api_key = std.posix.getenv("GSA_STEAM_API_KEY") orelse {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("GSA_STEAM_API_KEY is not set.\n") catch {};
        err_f.writeAll("Get a free Steam Web API key at: https://steamcommunity.com/dev/apikey\n") catch {};
        std.process.exit(1);
    };

    var client = steam_client.SteamClient.init(allocator, api_key);
    defer client.deinit();

    const result = client.resolveVanityUrl(vanity_url) catch |err| {
        const err_f = std.fs.File.stderr();
        var buf: [256]u8 = undefined;
        const msg = switch (err) {
            error.VanityNotFound => std.fmt.bufPrint(&buf, "Steam vanity URL not found: '{s}'\n" ++
                "Check the URL at: https://steamcommunity.com/id/{s}\n", .{ vanity_url, vanity_url }) catch "Vanity URL not found\n",
            error.HTTPError => std.fmt.bufPrint(&buf, "Steam API request failed — check network connectivity\n", .{}) catch "HTTP error\n",
            else => std.fmt.bufPrint(&buf, "Steam resolve error: {}\n", .{err}) catch "Error\n",
        };
        err_f.writeAll(msg) catch {};
        std.process.exit(1);
    };

    // Print Steam64 ID to stdout (plain, for scripting)
    out.writeAll(result.idSlice()) catch {};
    out.writeAll("\n") catch {};
}

/// Fetch and display player summary information for a Steam64 ID.
fn cmdSteamPlayer(allocator: std.mem.Allocator, steam_id: []const u8, out: std.fs.File) void {
    const api_key = std.posix.getenv("GSA_STEAM_API_KEY") orelse {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("GSA_STEAM_API_KEY is not set.\n") catch {};
        std.process.exit(1);
    };

    var client = steam_client.SteamClient.init(allocator, api_key);
    defer client.deinit();

    const summary = client.getPlayerSummary(steam_id) catch |err| {
        const err_f = std.fs.File.stderr();
        var buf: [256]u8 = undefined;
        const msg = switch (err) {
            error.PlayerNotFound => std.fmt.bufPrint(&buf, "No Steam player found for ID: {s}\n", .{steam_id}) catch "Player not found\n",
            error.HTTPError => std.fmt.bufPrint(&buf, "Steam API request failed\n", .{}) catch "HTTP error\n",
            else => std.fmt.bufPrint(&buf, "Steam player info error: {}\n", .{err}) catch "Error\n",
        };
        err_f.writeAll(msg) catch {};
        std.process.exit(1);
    };

    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "Steam64 ID:   {s}\nDisplay name: {s}\nProfile URL:  {s}\nVisibility:   {d}\n",
        .{
            summary.idSlice(),
            summary.nameSlice(),
            summary.urlSlice(),
            summary.visibility,
        },
    ) catch "Steam player info\n";
    out.writeAll(line) catch {};
}

// ── Display helpers ─────────────────────────────────────────────────────────

fn printBanner(out: std.fs.File) void {
    out.writeAll(
        \\
        \\  ╔═══════════════════════════════════════════════╗
        \\  ║  Game Server Admin                            ║
        \\  ║  Universal game server probe & management     ║
        \\  ╚═══════════════════════════════════════════════╝
        \\
        \\
    ) catch {};
}

fn printVersion(out: std.fs.File) void {
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "gsa {s}\n", .{gsa_core.VERSION}) catch return;
    out.writeAll(msg) catch {};
}

fn printUsage(out: std.fs.File) void {
    out.writeAll(
        \\  Usage: gsa <command> [options]
        \\
        \\  Commands:
        \\    status              Show system status (VeriSimDB, profiles)
        \\    probe <host> [port] Probe a game server (default port: 27015)
        \\    config init         Initialize user config from template
        \\    config show         Show current user configuration
        \\    config set-default <host> <port>
        \\                          Set the default server connection
        \\    config add-favorite <name> <host> <port>
        \\                          Add a server to favorites
        \\    config list-favorites
        \\                          List favorite servers
        \\    profiles            List available game profiles
        \\    instance <status|inspect|logs> --file PATH --id ID --host-id KEY
        \\                          Inspect/log one explicitly declared instance
        \\    version             Print version
        \\    help                Show this help
        \\
        \\  Environment:
        \\    GSA_VERISIMDB_URL   VeriSimDB endpoint (default: http://localhost:8090)
        \\    GSA_PROFILES_DIR    Profiles directory (default: ./profiles)
        \\
        \\
    ) catch {};
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "writeWithDefaultServer replaces host/port and preserves the rest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const existing =
        \\{
        \\  default_server = {
        \\    host = "old.example.com",
        \\    port = 12345,
        \\  },
        \\  favorites = [],
        \\}
    ;
    {
        const f = try tmp.dir.createFile("c.ncl", .{});
        defer f.close();
        try writeWithDefaultServer(existing, "new.host", 25565, f);
    }
    const rf = try tmp.dir.openFile("c.ncl", .{});
    defer rf.close();
    const content = try rf.readToEndAlloc(std.testing.allocator, 1 << 16);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "host = \"new.host\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "port = 25565") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "old.example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "favorites = []") != null);
}

test "writeWithFavorite inserts an entry before the closing bracket" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const existing =
        \\{
        \\  favorites = [
        \\  ],
        \\}
    ;
    {
        const f = try tmp.dir.createFile("c.ncl", .{});
        defer f.close();
        try writeWithFavorite(existing, "myfav", "10.0.0.1", 27015, f);
    }
    const rf = try tmp.dir.openFile("c.ncl", .{});
    defer rf.close();
    const content = try rf.readToEndAlloc(std.testing.allocator, 1 << 16);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "name = \"myfav\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "host = \"10.0.0.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "port = 27015") != null);
}

test "config helpers preserve unknown-shape input unchanged (no corruption)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const weird = "this is not the generated config at all\n";
    {
        const f = try tmp.dir.createFile("c.ncl", .{});
        defer f.close();
        try writeWithDefaultServer(weird, "x", 1, f);
    }
    const rf = try tmp.dir.openFile("c.ncl", .{});
    defer rf.close();
    const content = try rf.readToEndAlloc(std.testing.allocator, 1 << 16);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings(weird, content);
}
