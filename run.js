// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// run.js — Homoiconic, fault-tolerant, platform-independent run script
// for Game Server Admin (GSA)
//
// Usage:
//   bun run.js          # auto-detect and launch
//   bun run.js --help   # show usage
//   bun run.js --reflect

// ─────────────────────────────────────────────────────────────────────────────
// REGISTRY — homoiconic data; the script reads this at runtime via reflect()
// ─────────────────────────────────────────────────────────────────────────────
const REGISTRY = {
  identity: {
    name:    "game-server-admin",
    display: "Game Server Admin (GSA)",
    version: "0.9.0",
    license: "AGPL-3.0-or-later",
    repo:    "https://github.com/catachresis-colloquium/game-server-admin",
  },
  launchers: {
    bash:    "play.sh",      // existing homoiconic bash launcher
    just:    "Justfile",
  },
  binary: {
    zig:     "src/interface/ffi/zig-out/bin/gsa",
  },
  git: {
    remote:  "origin",
    branch:  "main",
    mirrors: [],
  },
  capabilities: [
    "reflect",        // reads own source (homoiconic)
    "detectPlatform", // OS, arch, display server
    "checkGitSync",   // fetch + ahead/behind + dirty check
    "launchBash",     // delegates to play.sh (existing homoiconic launcher)
    "launchJust",     // delegates to just run
    "launchBinary",   // runs zig-out/bin/gsa directly
    "gitCycle",       // add, commit, push, mirror
  ],
};

// ─────────────────────────────────────────────────────────────────────────────
// REFLECTION
// ─────────────────────────────────────────────────────────────────────────────
async function reflect() {
  const path = new URL(import.meta.url).pathname;
  const src  = await Bun.file(path).text();
  return { path, lines: src.split("\n").length, capabilities: REGISTRY.capabilities };
}

// ─────────────────────────────────────────────────────────────────────────────
// PLATFORM DETECTION
// ─────────────────────────────────────────────────────────────────────────────
async function detectPlatform() {
  const os   = process.platform;
  const arch = process.arch;

  let display = "unknown";
  if (os === "linux") {
    if (process.env["WAYLAND_DISPLAY"])    display = "wayland";
    else if (process.env["DISPLAY"])       display = "x11";
    else                                    display = "headless";
  } else if (os === "darwin")  display = "quartz";
  else if (os === "windows")   display = "win32";

  const has = async (cmd) => {
    try {
      const p = new Bun.Command("which", { args: [cmd], stdout: "null", stderr: "null" });
      return (await p.output()).success;
    } catch { return false; }
  };

  return {
    os, arch, display,
    hasBash:  os !== "windows",
    hasJust:  await has("just"),
    hasBun:   await has("bun"),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED HELPERS
// ─────────────────────────────────────────────────────────────────────────────
async function run(cmd, args) {
  try {
    
    const p = Bun.spawn([cmd, ...args], { stdout: "pipe", stderr: "pipe" });
    const stdout = await new Response(p.stdout).text();
    const stderr = await new Response(p.stderr).text();
    const code = await p.exited;
    const td = { decode: x => x }; // Mock TextDecoder

    return {
      ok:  code === 0,
      out: stdout.trim(),
      err: stderr.trim(),
    };
  } catch (e) {
    return { ok: false, out: "", err: e.message };
  }
}

const c = { reset:"\x1b[0m", bold:"\x1b[1m", green:"\x1b[32m", yellow:"\x1b[33m", cyan:"\x1b[36m" };
const log  = (m) => console.log(`${c.green}▶${c.reset} ${m}`);
const warn = (m) => console.warn(`${c.yellow}⚠${c.reset} ${m}`);
const head = (m) => console.log(`\n${c.bold}${c.cyan}${m}${c.reset}`);

// ─────────────────────────────────────────────────────────────────────────────
// GIT SYNC
// ─────────────────────────────────────────────────────────────────────────────
async function checkGitSync() {
  const sync = { dirty: false, ahead: 0, behind: 0, branch: "main", fetchError: false };

  const branch = await run("git", ["rev-parse", "--abbrev-ref", "HEAD"]);
  if (branch.ok) sync.branch = branch.out;

  const fetch = await run("git", ["fetch", "--quiet", REGISTRY.git.remote]);
  if (!fetch.ok) { sync.fetchError = true; warn("git fetch failed — offline"); }

  const rl = await run("git", ["rev-list", "--left-right", "--count",
    `${REGISTRY.git.remote}/${sync.branch}...HEAD`]);
  if (rl.ok) {
    const [b, a] = rl.out.split(/\s+/);
    sync.behind = parseInt(b, 10) || 0;
    sync.ahead  = parseInt(a, 10) || 0;
  }

  const diff = await run("git", ["status", "--porcelain"]);
  if (diff.ok && diff.out) sync.dirty = true;

  const remotes = await run("git", ["remote", "-v"]);
  if (remotes.ok) {
    REGISTRY.git.mirrors = [...new Set(
      remotes.out.split("\n")
        .filter(l => l.includes("(push)") && !l.startsWith(REGISTRY.git.remote + "\t"))
        .map(l => l.split("\t")[0])
    )];
  }

  return sync;
}

// ─────────────────────────────────────────────────────────────────────────────
// LAUNCH
// ─────────────────────────────────────────────────────────────────────────────
async function launchBash() {
  try {
    if (!await Bun.file(REGISTRY.launchers.bash).exists()) throw new Error("not found");
    log(`Delegating to ${REGISTRY.launchers.bash} (homoiconic bash launcher)...`);
    
    const p = Bun.spawn(["bash", REGISTRY.launchers.bash, "run"], {
      stdin: "inherit", stdout: "inherit", stderr: "inherit",
    });
    await p.exited;

    return true;
  } catch { return false; }
}

async function launchJust(platform) {
  if (!platform.hasJust) return false;
  try {
    if (!await Bun.file(REGISTRY.launchers.just).exists()) throw new Error("not found");
    log("Launching via: just run");
    
    const p = Bun.spawn(["just", "run"], {
      stdin: "inherit", stdout: "inherit", stderr: "inherit",
    });
    await p.exited;

    return true;
  } catch { return false; }
}

async function launchBinary() {
  try {
    if (!await Bun.file(REGISTRY.binary.zig).exists()) throw new Error("not found");
    log(`Running binary: ${REGISTRY.binary.zig}`);
    
    const p = Bun.spawn([REGISTRY.binary.zig, "status"], {
      stdin: "inherit", stdout: "inherit", stderr: "inherit",
    });
    await p.exited;

    return true;
  } catch { return false; }
}

// ─────────────────────────────────────────────────────────────────────────────
// GIT CYCLE
// ─────────────────────────────────────────────────────────────────────────────
async function gitCycle(sync) {
  head("── Git cycle ──");

  const add = await run("git", ["add", "-A"]);
  if (!add.ok) { warn("git add failed: " + add.err); return; }

  const staged = await run("git", ["diff", "--cached", "--stat"]);
  if (staged.out) {
    const commit = await run("git", ["commit", "-m",
      "chore: run.js launch cycle — auto-detected platform, git cycle"]);
    if (commit.ok) log("Committed outstanding changes");
    else { warn("Commit failed: " + commit.err); return; }
  } else {
    log("Nothing to commit");
  }

  // Push current branch
  const pushBranch = await run("git", ["push", REGISTRY.git.remote, sync.branch]);
  if (pushBranch.ok) log(`Pushed ${sync.branch} → ${REGISTRY.git.remote}`);
  else warn("Push failed: " + pushBranch.err);

  // Merge to main if not already there
  const mainBranch = "main";
  if (sync.branch !== mainBranch) {
    log(`Merging ${sync.branch} → ${mainBranch}...`);
    const checkout = await run("git", ["checkout", mainBranch]);
    if (!checkout.ok) { warn("Could not switch to main: " + checkout.err); return; }

    const merge = await run("git", ["merge", "--ff-only", sync.branch]);
    if (merge.ok) {
      log(`Fast-forward merged ${sync.branch} → ${mainBranch}`);
    } else {
      const mergeRegular = await run("git", ["merge", sync.branch,
        "-m", `chore: merge ${sync.branch} → main`]);
      if (!mergeRegular.ok) { warn("Merge failed: " + mergeRegular.err); return; }
      log(`Merged ${sync.branch} → ${mainBranch}`);
    }

    const pushMain = await run("git", ["push", REGISTRY.git.remote, mainBranch]);
    if (pushMain.ok) log(`Pushed ${mainBranch} → ${REGISTRY.git.remote}`);
    else warn("Main push failed: " + pushMain.err);
  }

  // Push to mirrors
  for (const mirror of REGISTRY.git.mirrors) {
    const mp = await run("git", ["push", mirror, mainBranch]);
    if (mp.ok) log(`Pushed to mirror: ${mirror}`);
    else warn(`Mirror push failed (${mirror}): ${mp.err}`);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────
if (import.meta.main) {
  const args = process.argv.slice(2);

  if (args.includes("--help") || args.includes("-h")) {
    console.log(`
${c.bold}${REGISTRY.identity.display} — run.js${c.reset}
${REGISTRY.identity.license} | ${REGISTRY.identity.repo}

Usage: bun run.js [OPTIONS]

Options:
  --help, -h       Show this help
  --no-git         Skip git sync check and post-launch git cycle
  --no-launch      Git cycle only
  --reflect        Print reflection data and exit
`);
    process.exit(0);
  }

  if (args.includes("--reflect")) {
    const r = await reflect();
    console.log(JSON.stringify({ registry: REGISTRY, reflection: r }, null, 2));
    process.exit(0);
  }

  const skipGit = args.includes("--no-git");
  const doLaunch = !args.includes("--no-launch");

  head(`${REGISTRY.identity.display} v${REGISTRY.identity.version}`);

  const r = await reflect();
  log(`Reflected: ${r.lines} lines, ${r.capabilities.length} capabilities`);

  head("Platform");
  const platform = await detectPlatform();
  log(`OS: ${platform.os}/${platform.arch} / display: ${platform.display}`);
  log(`just: ${platform.hasJust ? "available" : "not found"} | bash: ${platform.hasBash ? "yes" : "no"}`);

  let sync = { dirty: false, ahead: 0, behind: 0, branch: "main", fetchError: false };
  if (!skipGit) {
    head("Git sync");
    sync = await checkGitSync();
    log(`Branch: ${sync.branch} | ahead: ${sync.ahead} | behind: ${sync.behind}`);
    if (sync.dirty) warn("Working tree has uncommitted changes");
    if (sync.behind > 0) warn(`${sync.behind} commit(s) behind remote`);
  }

  if (doLaunch) {
    head("Launch");
    let launched = false;
    // play.sh is the preferred launcher — it's already homoiconic bash
    launched = launched || await launchBash();
    launched = launched || await launchJust(platform);
    launched = launched || await launchBinary();
    if (!launched) warn("No launch method available — check build / install tools");
  }

  if (!skipGit) await gitCycle(sync);

  head("Done");
}
