#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
# Stage the verified CryoFall dedicated-server tool anonymously into an isolated directory.
set -euo pipefail

APP_ID=1061710
INSTALL_DIR="/tmp/cryofall-dedicated-server"
STEAMCMD_DIR="${HOME}/.local/share/steamcmd"
DRY_RUN=0
NO_SYNC=0

usage() {
    cat <<'USAGE'
Usage: scripts/steam-stage.sh [--install-dir PATH] [--steamcmd-dir PATH] --no-sync [--dry-run]

Downloads CryoFall Dedicated Server AppID 1061710 using anonymous SteamCMD.
This staging command never syncs into a Podman volume or a deployment.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-id)
            [[ "${2:-}" == "1061710" ]] || { echo "Only verified CryoFall server AppID 1061710 is supported." >&2; exit 2; }
            shift 2
            ;;
        --install-dir) INSTALL_DIR="${2:?missing path}"; shift 2 ;;
        --steamcmd-dir) STEAMCMD_DIR="${2:?missing path}"; shift 2 ;;
        --no-sync) NO_SYNC=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "${NO_SYNC}" != "1" ]]; then
    echo "Refusing volume/remote sync: CryoFall's profile-ID-based Podman deployment is retired." >&2
    echo "Pass --no-sync to stage an isolated copy only." >&2
    exit 2
fi

if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'Would run: steamcmd +force_install_dir %q +login anonymous +app_update 1061710 +quit\n' "${INSTALL_DIR}"
    exit 0
fi

STEAMCMD_BIN="${STEAMCMD_DIR}/steamcmd.sh"
if [[ ! -x "${STEAMCMD_BIN}" ]]; then
    command -v curl >/dev/null || { echo "curl is required to install SteamCMD." >&2; exit 1; }
    command -v tar >/dev/null || { echo "tar is required to install SteamCMD." >&2; exit 1; }
    mkdir -p "${STEAMCMD_DIR}"
    archive="${STEAMCMD_DIR}/steamcmd-linux.tar.gz"
    curl --fail --silent --show-error --location \
        https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
        --output "${archive}"
    tar -xzf "${archive}" -C "${STEAMCMD_DIR}"
    rm -f "${archive}"
    (cd "${STEAMCMD_DIR}" && ./steamcmd.sh +quit)
fi

mkdir -p "${INSTALL_DIR}"
(cd "${STEAMCMD_DIR}" && ./steamcmd.sh \
    +force_install_dir "${INSTALL_DIR}" \
    +login anonymous \
    +app_update 1061710 \
    +quit)

SERVER_DLL="${INSTALL_DIR}/Binaries/Server/CryoFall_Server.dll"
[[ -f "${SERVER_DLL}" ]] || { echo "CryoFall_Server.dll was not installed at the expected path." >&2; exit 1; }
shopt -s nullglob
VERSION_FILES=("${INSTALL_DIR}"/Version\ *)
[[ "${#VERSION_FILES[@]}" -gt 0 ]] || { echo "CryoFall Version file is missing." >&2; exit 1; }
VERSION_FILE="${VERSION_FILES[0]}"
printf 'Installed CryoFall dedicated server: %s\n' "$(sed -n '1p' "${VERSION_FILE}" | tr -d '\r')"
printf 'Install directory: %s\n' "${INSTALL_DIR}"
