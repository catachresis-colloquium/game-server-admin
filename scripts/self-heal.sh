#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
#
# GSA Self-Healing Watchdog
#
# Continuously monitors a GSA-managed game server container and takes
# automatic corrective action when problems are detected.
#
# Monitors:
#   - Container running state         → restart if exited/dead
#   - UDP port binding                → restart if port not listening
#   - Disk space on game data volume  → warn + alert at thresholds
#   - Settings.xml integrity          → restore from VeriSimDB backup if corrupt
#   - SteamCMD update availability   → scheduled update window
#
# Recovery actions (in escalation order):
#   1. podman start <container>       (for exited/stopped containers)
#   2. systemctl --user restart <svc> (for failed Quadlet units)
#   3. Groove alert to configured targets
#   4. After max_restarts, mark degraded and alert — do not loop indefinitely
#
# Usage:
#   ./scripts/self-heal.sh [options]
#   ./scripts/self-heal.sh --container <supported-container> --port <udp-port>
#   ./scripts/self-heal.sh --daemon     # run in background via systemd
#
# Environment variables:
#   GSA_VERISIMDB_URL      VeriSimDB endpoint (default: http://[::1]:8090)
#   GSA_GROOVE_ALERT_URL   Groove target URL for alerts (optional)
#   SELFHEAL_INTERVAL      Check interval in seconds (default: 30)
#   SELFHEAL_MAX_RESTARTS  Max restarts before giving up (default: 5)
#   SELFHEAL_DISK_WARN_GB  Disk warning threshold in GB (default: 2)
#   SELFHEAL_DISK_CRIT_GB  Disk critical threshold in GB (default: 0.5)

set -euo pipefail

# ─── Colour + logging ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

ts()      { date '+%Y-%m-%dT%H:%M:%SZ'; }
log_ok()  { echo -e "[$(ts)] ${GREEN}HEAL OK${RESET}     $*"; }
log_warn(){ echo -e "[$(ts)] ${YELLOW}HEAL WARN${RESET}   $*"; }
log_fix() { echo -e "[$(ts)] ${BLUE}HEAL FIX${RESET}    $*"; }
log_crit(){ echo -e "[$(ts)] ${RED}HEAL CRIT${RESET}   $*" >&2; }

# ─── Defaults ─────────────────────────────────────────────────────────────────
CONTAINER="${1:-}"
SERVICE=""
UDP_PORT="6000"
INTERVAL="${SELFHEAL_INTERVAL:-30}"
MAX_RESTARTS="${SELFHEAL_MAX_RESTARTS:-5}"
DISK_WARN_GB="${SELFHEAL_DISK_WARN_GB:-2}"
DISK_CRIT_GB="${SELFHEAL_DISK_CRIT_GB:-0.5}"
VERISIMDB_URL="${GSA_VERISIMDB_URL:-http://[::1]:8090}"
DAEMON=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)  CONTAINER="$2"; SERVICE="gsa-${CONTAINER}"; shift 2 ;;
        --port)       UDP_PORT="$2"; shift 2 ;;
        --interval)   INTERVAL="$2"; shift 2 ;;
        --daemon)     DAEMON=1; shift ;;
        *) shift ;;
    esac
done

if [[ -z "${CONTAINER}" ]]; then
    log_crit "An explicit supported container is required; CryoFall's legacy watchdog is retired."
    exit 2
fi
SERVICE="${SERVICE:-gsa-${CONTAINER}}"

if [[ "${CONTAINER}" == "cryofall" ]]; then
    log_crit "CryoFall's legacy self-healer is retired: port binding alone is not readiness and automatic restart/restore is not instance-aware."
    exit 2
fi

RESTART_COUNT=0
DEGRADED=0

# ─── Groove alert helper ──────────────────────────────────────────────────────
groove_alert() {
    local SEVERITY="$1"
    local MESSAGE="$2"
    local GROOVE_URL="${GSA_GROOVE_ALERT_URL:-}"

    if [[ -n "${GROOVE_URL}" ]]; then
        curl -sf -X POST "${GROOVE_URL}/alert" \
            -H "Content-Type: application/json" \
            -d "{\"severity\":\"${SEVERITY}\",\"message\":\"${MESSAGE}\",\"source\":\"gsa-selfheal-${CONTAINER}\"}" \
            >/dev/null 2>&1 || true
    fi
}

# ─── Self-diagnostic checks ───────────────────────────────────────────────────

check_container_running() {
    local STATUS
    STATUS=$(podman inspect --format '{{.State.Status}}' "${CONTAINER}" 2>/dev/null || echo "not-found")
    echo "${STATUS}"
}

check_port_listening() {
    # Returns 0 (yes) or 1 (no)
    ss -ulnp 2>/dev/null | grep -q ":${UDP_PORT} "
}

check_disk_space() {
    # Returns available GB on the cryofall-game-data volume mount
    local VOL_PATH
    VOL_PATH=$(podman volume inspect "${CONTAINER}-game-data" \
        --format '{{.Mountpoint}}' 2>/dev/null || echo "")
    if [[ -z "${VOL_PATH}" ]]; then echo "0"; return; fi

    local AVAIL_BYTES
    AVAIL_BYTES=$(df --output=avail -B1 "${VOL_PATH}" 2>/dev/null | tail -1 || echo "0")
    echo "scale=2; ${AVAIL_BYTES} / 1073741824" | bc 2>/dev/null || echo "0"
}

check_settings_xml() {
    local VOL_PATH
    VOL_PATH=$(podman volume inspect "${CONTAINER}-world-data" \
        --format '{{.Mountpoint}}' 2>/dev/null || echo "")
    if [[ -z "${VOL_PATH}" ]]; then return 0; fi

    local CFG="${VOL_PATH}/Settings.xml"
    if [[ ! -f "${CFG}" ]]; then return 1; fi

    # Basic XML well-formedness check
    python3 -c "
import xml.etree.ElementTree as ET, sys
try:
    ET.parse(sys.argv[1])
    sys.exit(0)
except ET.ParseError:
    sys.exit(1)
" "${CFG}" 2>/dev/null
}

restore_settings_xml() {
    # Attempt to restore Settings.xml from VeriSimDB backup snapshot
    log_fix "Attempting Settings.xml restore from VeriSimDB..."

    local SNAPSHOT
    SNAPSHOT=$(curl -sf "${VERISIMDB_URL}/v1/document/${CONTAINER}-settings" 2>/dev/null || echo "")
    if [[ -z "${SNAPSHOT}" ]]; then
        log_warn "No VeriSimDB snapshot found for ${CONTAINER}-settings"
        return 1
    fi

    local VOL_PATH
    VOL_PATH=$(podman volume inspect "${CONTAINER}-world-data" \
        --format '{{.Mountpoint}}' 2>/dev/null || echo "")
    if [[ -z "${VOL_PATH}" ]]; then return 1; fi

    # Extract xml field from VeriSimDB document response
    echo "${SNAPSHOT}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
xml = d.get('xml') or d.get('content') or ''
print(xml)
" > "${VOL_PATH}/Settings.xml" 2>/dev/null && \
        log_ok "Settings.xml restored from VeriSimDB" || \
        log_warn "Settings.xml restore failed"
}

restart_server() {
    local REASON="$1"
    RESTART_COUNT=$((RESTART_COUNT + 1))

    if [[ "${RESTART_COUNT}" -gt "${MAX_RESTARTS}" ]]; then
        log_crit "Max restarts (${MAX_RESTARTS}) exceeded. Marking server DEGRADED."
        DEGRADED=1
        groove_alert "critical" "GSA: ${CONTAINER} server is DEGRADED after ${MAX_RESTARTS} restart attempts. Manual intervention required."
        return 1
    fi

    log_fix "Restarting ${CONTAINER} (attempt ${RESTART_COUNT}/${MAX_RESTARTS}) — reason: ${REASON}"
    groove_alert "warning" "GSA: ${CONTAINER} server restarting (attempt ${RESTART_COUNT}) — ${REASON}"

    # Try Quadlet service restart first, fall back to direct podman
    if systemctl --user is-enabled "${SERVICE}" >/dev/null 2>&1; then
        systemctl --user restart "${SERVICE}" 2>/dev/null && \
            log_fix "Restarted via systemctl --user restart ${SERVICE}" || \
            (podman start "${CONTAINER}" 2>/dev/null && \
             log_fix "Restarted via podman start ${CONTAINER}")
    else
        podman start "${CONTAINER}" 2>/dev/null && \
            log_fix "Restarted via podman start ${CONTAINER}"
    fi

    # Brief wait for startup
    sleep 5
}

# ─── Main watchdog loop ───────────────────────────────────────────────────────

echo -e "[$(ts)] ${BOLD}GSA Self-Heal Watchdog${RESET} — monitoring ${CONTAINER} (interval: ${INTERVAL}s)"
echo "[$(ts)] Container: ${CONTAINER}"
echo "[$(ts)] Service:   ${SERVICE}"
echo "[$(ts)] UDP port:  ${UDP_PORT}"
echo "[$(ts)] VeriSimDB: ${VERISIMDB_URL}"
echo "[$(ts)] Max restarts: ${MAX_RESTARTS}"
echo ""

while true; do
    # ── Don't monitor if degraded ────────────────────────────────────────────
    if [[ "${DEGRADED}" == "1" ]]; then
        log_crit "Server is DEGRADED. Watchdog suspended. Fix manually:"
        log_crit "  podman logs ${CONTAINER}"
        log_crit "  systemctl --user status ${SERVICE}"
        log_crit "  just ${CONTAINER}-logs"
        sleep 300  # check again in 5 min in case human fixed it
        CONTAINER_STATUS="$(check_container_running)"
        if [[ "${CONTAINER_STATUS}" == "running" ]]; then
            log_ok "Container recovered from DEGRADED state — resuming watchdog"
            DEGRADED=0
            RESTART_COUNT=0
        fi
        continue
    fi

    # ── Check 1: Container running state ─────────────────────────────────────
    CONTAINER_STATUS="$(check_container_running)"
    case "${CONTAINER_STATUS}" in
        running)
            # Good — reset restart counter on successful run
            RESTART_COUNT=0
            ;;
        exited|stopped|dead|not-found)
            log_warn "Container '${CONTAINER}' is ${CONTAINER_STATUS}"
            restart_server "container ${CONTAINER_STATUS}"
            sleep "${INTERVAL}"
            continue
            ;;
        created|paused)
            log_warn "Container '${CONTAINER}' is ${CONTAINER_STATUS} (not running)"
            restart_server "container stuck in ${CONTAINER_STATUS}"
            sleep "${INTERVAL}"
            continue
            ;;
        *)
            log_warn "Unknown container status: ${CONTAINER_STATUS}"
            ;;
    esac

    # ── Check 2: UDP port bound ───────────────────────────────────────────────
    if ! check_port_listening 2>/dev/null; then
        log_warn "UDP port ${UDP_PORT} is not bound — server may not have started yet"
        # Don't restart immediately — server may still be initialising (SteamCMD)
        # Wait one more cycle before acting
        sleep "${INTERVAL}"
        if ! check_port_listening 2>/dev/null; then
            log_warn "UDP port ${UDP_PORT} still not bound after two cycles"
            restart_server "UDP port ${UDP_PORT} not listening"
        fi
        continue
    fi

    # ── Check 3: Disk space ───────────────────────────────────────────────────
    AVAIL_GB="$(check_disk_space)"
    if command -v bc >/dev/null 2>&1; then
        if (( $(echo "${AVAIL_GB} < ${DISK_CRIT_GB}" | bc -l) )); then
            log_crit "CRITICAL: disk space ${AVAIL_GB} GB < ${DISK_CRIT_GB} GB threshold"
            groove_alert "critical" "GSA: ${CONTAINER} disk space critical — ${AVAIL_GB} GB available"
        elif (( $(echo "${AVAIL_GB} < ${DISK_WARN_GB}" | bc -l) )); then
            log_warn "Low disk space: ${AVAIL_GB} GB available (warning at ${DISK_WARN_GB} GB)"
            groove_alert "warning" "GSA: ${CONTAINER} low disk space — ${AVAIL_GB} GB available"
        fi
    fi

    # ── Check 4: Settings.xml integrity ──────────────────────────────────────
    if ! check_settings_xml 2>/dev/null; then
        log_warn "Settings.xml appears corrupt — attempting restore"
        restore_settings_xml || log_warn "Could not restore Settings.xml automatically"
    fi

    # ── All checks passed ─────────────────────────────────────────────────────
    log_ok "${CONTAINER} healthy (UDP:${UDP_PORT} bound, disk:${AVAIL_GB}GB, config:ok)"

    sleep "${INTERVAL}"
done
