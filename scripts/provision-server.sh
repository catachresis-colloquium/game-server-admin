#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
#
# GSA Server Provisioner — schema-driven game server minter
#
# Reads from a game's A2ML profile (profiles/<game>.a2ml) and the
# container definition (container/<game>/) to provision a complete
# running server on the target host:
#
#   1. Pre-flight  — verify toolchain + VPS connectivity
#   2. Build       — build the container image
#   3. Volumes     — create named Podman volumes
#   4. Firewall    — open UDP/TCP ports (firewall-cmd or ufw)
#   5. Quadlet     — install systemd container unit
#   6. Start       — enable + start the service
#   7. Verify      — wait for health check to pass
#   8. Register    — write server record to VeriSimDB
#   9. Report      — print connection info and admin instructions
#
# Usage:
#   ./scripts/provision-server.sh <game-profile-id>
#   CryoFall is excluded; it requires the instance-aware disposable flow.
#
# Run via Justfile:
#   just game-deploy GAME=<supported-profile>
#
# Remote (Verpex VPS):
#   just verpex-deploy GAME=<supported-profile>
#
# Environment variables (override defaults):
#   GSA_VERISIMDB_URL     VeriSimDB HTTP endpoint (default: http://[::1]:8090)
#   GSA_QUADLET_DIR       Quadlet install path   (default: ~/.config/containers/systemd)
#   PROVISION_DRY_RUN     Set to 1 to print commands without executing
#   PROVISION_SKIP_BUILD  Set to 1 to skip image build (use cached image)
#   PROVISION_SKIP_FW     Set to 1 to skip firewall configuration

set -euo pipefail

# ─── Colour output ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

log_step()  { echo -e "${BLUE}[provision]${RESET} ${BOLD}$*${RESET}"; }
log_ok()    { echo -e "${GREEN}  ✓${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}  ⚠${RESET} $*"; }
log_error() { echo -e "${RED}  ✗${RESET} $*" >&2; }
log_info()  { echo -e "    $*"; }

PROFILE_ID="${1:-}"
if [ -z "${PROFILE_ID}" ]; then
    log_error "Usage: $0 <game-profile-id>"
    log_error "Available profiles:"
    ls profiles/*.a2ml 2>/dev/null | sed 's|profiles/||; s|\.a2ml||; s|^|  |' || true
    exit 1
fi

if [ "${PROFILE_ID}" = "cryofall" ]; then
    log_error "CryoFall's profile-ID-based provisioner is retired. Use an explicit deployment instance after disposable qualification."
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN="${PROVISION_DRY_RUN:-0}"
SKIP_BUILD="${PROVISION_SKIP_BUILD:-0}"
SKIP_FW="${PROVISION_SKIP_FW:-0}"
VERISIMDB_URL="${GSA_VERISIMDB_URL:-http://[::1]:8090}"
QUADLET_DIR="${GSA_QUADLET_DIR:-${HOME}/.config/containers/systemd}"

# ─── Profile registry ─────────────────────────────────────────────────────────
#
# Maps profile IDs to the provisioning parameters extracted from the A2ML schema.
# Future: replace this with `gsa provision --schema <id>` once that CLI subcommand
# is implemented in cli.zig (the A2ML profile already contains all this data).
#
# Format:  PORTS_UDP   space-separated UDP ports from @port(protocol="UDP")
#          PORTS_TCP   space-separated TCP ports from @port(protocol="TCP")
#          CONTAINER   container name from @container(name=...)
#          QUADLET     filename of the .container Quadlet unit
#          VOLUMES     colon-separated "name:mountpoint" pairs
#          STEAMAPPID  SteamCMD AppID (empty if not a Steam game)

declare -A PROFILE_PORTS_UDP PROFILE_PORTS_TCP PROFILE_CONTAINER \
           PROFILE_QUADLET PROFILE_VOLUMES PROFILE_STEAMAPPID

# ── Valheim (Iron Gate / Unity) ───────────────────────────────────────────────
PROFILE_PORTS_UDP[valheim]="2456 2457 2458"
PROFILE_PORTS_TCP[valheim]=""
PROFILE_CONTAINER[valheim]="valheim"
PROFILE_QUADLET[valheim]="container/valheim/gsa-valheim.container"
PROFILE_VOLUMES[valheim]="valheim-game:/opt/valheim valheim-world:/data/valheim valheim-backups:/data/backups"
PROFILE_STEAMAPPID[valheim]="896660"

# ── Minecraft Java (Mojang) ───────────────────────────────────────────────────
PROFILE_PORTS_UDP[minecraft-java]=""
PROFILE_PORTS_TCP[minecraft-java]="25565"
PROFILE_CONTAINER[minecraft-java]="minecraft-java"
PROFILE_QUADLET[minecraft-java]="container/minecraft-java/gsa-minecraft-java.container"
PROFILE_VOLUMES[minecraft-java]="mc-java-world:/data/minecraft-java mc-java-backups:/data/backups"
PROFILE_STEAMAPPID[minecraft-java]=""

# Existing game profiles are a legacy A2ML dependency. Do not add new A2ML
# profiles; any future generic provision route requires an approved versioned
# contract and must preserve the game-owned server boundary.

# ─── Validate profile is known ────────────────────────────────────────────────
if [ -z "${PROFILE_CONTAINER[$PROFILE_ID]+x}" ]; then
    log_error "Unknown profile: '${PROFILE_ID}'"
    log_error "Known profiles: ${!PROFILE_CONTAINER[*]}"
    exit 1
fi

CONTAINER="${PROFILE_CONTAINER[$PROFILE_ID]}"
QUADLET="${PROFILE_QUADLET[$PROFILE_ID]}"
PORTS_UDP="${PROFILE_PORTS_UDP[$PROFILE_ID]}"
PORTS_TCP="${PROFILE_PORTS_TCP[$PROFILE_ID]}"
# shellcheck disable=SC2206
VOLUMES=(${PROFILE_VOLUMES[$PROFILE_ID]})
IMAGE_TAG="localhost/${CONTAINER}-server:latest"

# ─── Helper: run or echo (dry-run mode) ───────────────────────────────────────
run() {
    if [ "${DRY_RUN}" = "1" ]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  GSA Server Provisioner — ${PROFILE_ID}${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
log_info "Profile:   ${PROFILE_ID}"
log_info "Container: ${CONTAINER}"
log_info "Image:     ${IMAGE_TAG}"
log_info "UDP ports: ${PORTS_UDP:-none}"
log_info "TCP ports: ${PORTS_TCP:-none}"
log_info "Quadlet:   ${QUADLET}"
[ "${DRY_RUN}" = "1" ] && log_warn "DRY RUN — no changes will be made"
echo ""

# ─── Step 1: Pre-flight ───────────────────────────────────────────────────────
log_step "1/9  Pre-flight checks"

MISSING=0
for tool in podman systemctl; do
    if command -v "${tool}" >/dev/null 2>&1; then
        log_ok "${tool} found"
    else
        log_error "${tool} not found — required for provisioning"
        MISSING=$((MISSING + 1))
    fi
done

if [ "${SKIP_FW}" != "1" ]; then
    if command -v firewall-cmd >/dev/null 2>&1; then
        log_ok "firewall-cmd found (AlmaLinux/Fedora)"
    elif command -v ufw >/dev/null 2>&1; then
        log_ok "ufw found (Debian/Ubuntu)"
    else
        log_warn "No firewall manager found — firewall step will be skipped"
        SKIP_FW=1
    fi
fi

if [ "${MISSING}" -gt 0 ]; then
    log_error "Pre-flight failed — ${MISSING} required tool(s) missing"
    exit 1
fi

if [ ! -f "${REPO_ROOT}/profiles/${PROFILE_ID}.a2ml" ]; then
    log_error "Profile file not found: profiles/${PROFILE_ID}.a2ml"
    exit 1
fi
log_ok "Profile file: profiles/${PROFILE_ID}.a2ml"

if [ ! -f "${REPO_ROOT}/${QUADLET}" ]; then
    log_error "Quadlet file not found: ${QUADLET}"
    exit 1
fi
log_ok "Quadlet file: ${QUADLET}"

# ─── Step 2: Build container image ───────────────────────────────────────────
log_step "2/9  Build container image"

if [ "${SKIP_BUILD}" = "1" ]; then
    log_warn "SKIP_BUILD=1 — using cached image ${IMAGE_TAG}"
else
    CONTAINERFILE="${REPO_ROOT}/container/${CONTAINER}/Containerfile"
    if [ ! -f "${CONTAINERFILE}" ]; then
        log_error "Containerfile not found: container/${CONTAINER}/Containerfile"
        exit 1
    fi
    log_info "Building ${IMAGE_TAG} from ${CONTAINERFILE}..."
    run podman build \
        -t "${IMAGE_TAG}" \
        -f "${CONTAINERFILE}" \
        "${REPO_ROOT}"
    log_ok "Image built: ${IMAGE_TAG}"
fi

# ─── Step 3: Create named volumes ─────────────────────────────────────────────
log_step "3/9  Create Podman volumes"

for vol_spec in "${VOLUMES[@]}"; do
    VOL_NAME="${vol_spec%%:*}"
    if podman volume inspect "${VOL_NAME}" >/dev/null 2>&1; then
        log_ok "Volume exists: ${VOL_NAME} (preserved)"
    else
        run podman volume create "${VOL_NAME}"
        log_ok "Volume created: ${VOL_NAME}"
    fi
done

# ─── Step 4: Firewall ─────────────────────────────────────────────────────────
log_step "4/9  Firewall rules"

if [ "${SKIP_FW}" != "1" ]; then
    if command -v firewall-cmd >/dev/null 2>&1; then
        # AlmaLinux 9.7 (Verpex VPS)
        for port in ${PORTS_UDP}; do
            run firewall-cmd --permanent --add-port="${port}/udp" 2>/dev/null && \
                log_ok "Opened UDP ${port} (firewall-cmd)" || \
                log_warn "UDP ${port} may already be open"
        done
        for port in ${PORTS_TCP}; do
            run firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null && \
                log_ok "Opened TCP ${port} (firewall-cmd)" || \
                log_warn "TCP ${port} may already be open"
        done
        if [ -n "${PORTS_UDP}${PORTS_TCP}" ]; then
            run firewall-cmd --reload
            log_ok "Firewall reloaded"
        fi
    elif command -v ufw >/dev/null 2>&1; then
        for port in ${PORTS_UDP}; do
            run ufw allow "${port}/udp" && log_ok "Opened UDP ${port} (ufw)"
        done
        for port in ${PORTS_TCP}; do
            run ufw allow "${port}/tcp" && log_ok "Opened TCP ${port} (ufw)"
        done
    fi
else
    log_warn "Skipping firewall (SKIP_FW=1)"
    for port in ${PORTS_UDP}; do log_info "  → manually open UDP ${port}"; done
    for port in ${PORTS_TCP}; do log_info "  → manually open TCP ${port}"; done
fi

# ─── Step 5: Install Quadlet ──────────────────────────────────────────────────
log_step "5/9  Install Quadlet unit"

run mkdir -p "${QUADLET_DIR}"
run cp "${REPO_ROOT}/${QUADLET}" "${QUADLET_DIR}/"
log_ok "Installed: ${QUADLET_DIR}/$(basename "${QUADLET}")"

run systemctl --user daemon-reload
log_ok "systemd daemon reloaded"

# ─── Step 6: Enable + start service ──────────────────────────────────────────
log_step "6/9  Start service"

SERVICE="gsa-${CONTAINER}"
run systemctl --user enable --now "${SERVICE}" 2>/dev/null || \
    run systemctl --user start "${SERVICE}"
log_ok "Service started: ${SERVICE}"

# ─── Step 7: Health verification ─────────────────────────────────────────────
log_step "7/9  Verify server health"

HEALTH_ATTEMPTS=30      # 5 minutes (10s intervals)
HEALTH_INTERVAL=10

if [ "${DRY_RUN}" = "1" ]; then
    log_warn "Dry run — skipping health wait"
else
    echo -n "    Waiting for container to become healthy"
    for i in $(seq 1 "${HEALTH_ATTEMPTS}"); do
        STATUS=$(podman inspect --format "{{.State.Health.Status}}" "${CONTAINER}" 2>/dev/null || echo "not-found")
        if [ "${STATUS}" = "healthy" ]; then
            echo ""
            log_ok "Container healthy after $((i * HEALTH_INTERVAL))s"
            break
        elif [ "${STATUS}" = "not-found" ]; then
            # Container may not be started yet (first-run SteamCMD install)
            echo -n "."
        else
            echo -n "."
        fi
        if [ "${i}" -eq "${HEALTH_ATTEMPTS}" ]; then
            echo ""
            log_warn "Health check timed out after $((HEALTH_ATTEMPTS * HEALTH_INTERVAL))s"
            log_warn "The server may still be downloading game files (first run takes ~3 min)"
            log_info "Monitor: podman logs -f ${CONTAINER}"
        fi
        sleep "${HEALTH_INTERVAL}"
    done
fi

# ─── Step 8: Register in VeriSimDB ───────────────────────────────────────────
log_step "8/9  Register in VeriSimDB"

# Use the GSA CLI to probe the server and push config to VeriSimDB.
# Falls back to a direct HTTP POST if the CLI is unavailable.
GSA_CLI="${REPO_ROOT}/src/interface/ffi/zig-out/bin/gsa"

if [ "${DRY_RUN}" = "1" ]; then
    log_warn "Dry run — skipping VeriSimDB registration"
elif [ -x "${GSA_CLI}" ]; then
    # Probe the server (fingerprint + config extract) and store in VeriSimDB
    run "${GSA_CLI}" probe localhost || log_warn "Probe failed — server may still be starting"
    log_ok "Server probed and registered via gsa CLI"
else
    # Direct HTTP POST to VeriSimDB document modality
    PAYLOAD=$(cat <<JSONEOF
{
  "id": "${PROFILE_ID}-server",
  "type": "game-server",
  "profile": "${PROFILE_ID}",
  "container": "${CONTAINER}",
  "provisioned_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "managed_by": "gsa"
}
JSONEOF
)
    if curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "${PAYLOAD}" \
        "${VERISIMDB_URL}/v1/document/${PROFILE_ID}-server" >/dev/null 2>&1; then
        log_ok "Registered in VeriSimDB (${VERISIMDB_URL})"
    else
        log_warn "VeriSimDB registration failed — is gsa-verisimdb running?"
        log_info "Start it: systemctl --user start gsa-verisimdb"
    fi
fi

# ─── Step 9: Report ───────────────────────────────────────────────────────────
log_step "9/9  Provisioning complete"
echo ""
echo -e "${GREEN}${BOLD}  Server '${PROFILE_ID}' provisioned successfully!${RESET}"
echo ""
echo -e "  ${BOLD}Connection${RESET}"

for port in ${PORTS_UDP}; do
    echo "    UDP ${port}  (game traffic)"
done
for port in ${PORTS_TCP}; do
    echo "    TCP ${port}"
done

echo ""
echo -e "  ${BOLD}Manage via GSA${RESET}"
echo "    Select an explicit deployment instance for instance-aware operations."
echo "    gsa probe localhost ${PORTS_UDP%% *}   ← probe the configured endpoint"
echo ""
echo -e "  ${BOLD}Podman / systemd${RESET}"
echo "    podman ps                                ← check container status"
echo "    podman logs -f ${CONTAINER}              ← stream server output"
echo "    systemctl --user status gsa-${CONTAINER} ← service health"
echo ""
echo -e "  ${BOLD}Game administration${RESET}"
echo "    Use the game's supported admin interface; no generic admin path is assumed."
echo ""
echo -e "  ${BOLD}DNS reminder${RESET}"
echo "    UDP ports cannot be Cloudflare-proxied."
echo "    Cloudflare DNS record for this server must be grey-cloud (DNS-only)."
echo ""
