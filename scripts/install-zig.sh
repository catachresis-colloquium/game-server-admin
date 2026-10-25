#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Install a pinned, hash-verified Zig toolchain for CI — no third-party action.
#
# Why this exists: the repo's Actions policy admits only GitHub-owned and
# Marketplace-verified-creator actions. mlugg/setup-zig is neither, so every
# workflow that used it ended in startup_failure before running a single step
# (game-server-admin#103). This script needs no action at all.
#
# Trust chain: the tarball is fetched from ziglang.org over HTTPS and must
# match the sha256 pinned below, or the step fails. At pin time (2026-09-30)
# the tarball's minisign signature was verified against the Zig Software
# Foundation release key
#   RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
# (file signature and trusted-comment signature, timestamp:1760215991), and a
# one-byte-altered digest was rejected as a negative control. The committed
# sha256 carries that binding into CI.
#
# To bump: change ZIG_VERSION and ZIG_SHA256 together, taking the shasum from
# https://ziglang.org/download/index.json and re-verifying the .minisig.
#
# Usage: bash scripts/install-zig.sh
# Puts `zig` on PATH for subsequent steps via $GITHUB_PATH.

set -euo pipefail

ZIG_VERSION="0.15.2"
ZIG_SHA256_X86_64_LINUX="02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239"

os="$(uname -s)"
arch="$(uname -m)"
if [[ "$os" != "Linux" ]] || [[ "$arch" != "x86_64" ]]; then
  echo "::error::install-zig.sh pins only x86_64-linux; got ${os}/${arch}. Add a pinned sha256 for this platform." >&2
  exit 1
fi

tarball="zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
url="https://ziglang.org/download/${ZIG_VERSION}/${tarball}"

if [ -n "${RUNNER_TEMP:-}" ]; then
  dest_root="$RUNNER_TEMP"
elif [ -n "${TMPDIR:-}" ]; then
  dest_root="$TMPDIR"
else
  dest_root="/tmp"
fi
work="${dest_root}/zig-download"
if [ -n "${RUNNER_TEMP:-}" ]; then
  dest="${dest_root}/zig-${ZIG_VERSION}"
else
  dest="${HOME:-/tmp}/.local/zig-${ZIG_VERSION}"
fi
mkdir -p "$work" "$dest"

curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-delay 5 \
  -o "${work}/${tarball}" "$url" || {
    echo "::warning::Primary ziglang.org fetch failed — trying GitHub mirror"
    gh_url="https://github.com/ziglang/zig/releases/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz"
    # Fallback name may differ; try the ziglang.org tarball name via codeload if needed
    curl -fsSL --retry 3 -o "${work}/${tarball}" "$gh_url" || {
      echo "::error::Failed to fetch Zig ${ZIG_VERSION} from both ziglang.org and GitHub mirror" >&2
      exit 1
    }
  }

echo "${ZIG_SHA256_X86_64_LINUX}  ${work}/${tarball}" | sha256sum -c -

tar -xJf "${work}/${tarball}" -C "$dest" --strip-components=1
rm -rf "$work"

got="$("${dest}/zig" version)"
if [[ "$got" != "$ZIG_VERSION" ]]; then
  echo "::error::installed zig reports '${got}', expected '${ZIG_VERSION}'" >&2
  exit 1
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$dest" >> "$GITHUB_PATH"
  echo "Installed zig ${got} at ${dest} (added to GITHUB_PATH)"
else
  # Local / non-Actions install: ensure on PATH via symlink
  mkdir -p "${HOME:-/tmp}/.local/bin"
  ln -sf "${dest}/zig" "${HOME:-/tmp}/.local/bin/zig"
  export PATH="${HOME:-/tmp}/.local/bin:$PATH"
  echo "Installed zig ${got} at ${dest} (symlinked to ${HOME:-/tmp}/.local/bin/zig)"
fi
