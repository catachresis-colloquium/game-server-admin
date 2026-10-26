#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# SPDX-FileCopyrightText: 2026 Joshua Benjamin Jewell <developer@joshuajewell.dev>
#
# GSA Server Setup Wizard — fire-and-forget provisioning
#
# Walks through the complete setup of a game server from scratch:
#   1. Preflight — check tools and connectivity
#   2. Identity  — resolve Steam operator IDs via Steam Web API
#   3. Config    — customise Settings.xml via guided prompts
#   4. Stage     — download game files via SteamCMD (authenticated)
#   5. Provision — build image, open firewall, install Quadlet, start
#   6. Verify    — confirm server is healthy and reachable
#   7. Report    — print connection details and admin instructions
#
# Usage:
#   ./scripts/wizard.sh [--game <profile-id>] [--unattended] [--dry-run]
#   ./scripts/wizard.sh                     # interactive (default)
#   ./scripts/wizard.sh --game <profile-id> # skip game selection
#   ./scripts/wizard.sh --unattended        # no prompts, use env vars
#
# Environment variables for --unattended mode:
#   WIZARD_GAME              Game profile ID
#   WIZARD_SERVER_NAME       Display name for the server
#   WIZARD_MAX_PLAYERS       Max concurrent players
#   WIZARD_IS_PVE            true/false
#   WIZARD_WIPE_DAYS         World wipe interval in days (0=never)
#   WIZARD_GATHERING_RATE    Gathering speed multiplier
#   WIZARD_LEARNING_RATE     Learning speed multiplier
#   WIZARD_CRAFTING_RATE     Crafting speed multiplier
#   WIZARD_OPERATOR_1        First operator's Steam vanity URL or Steam64 ID
#   WIZARD_OPERATOR_2        Second operator's Steam vanity URL or Steam64 ID
#   GSA_STEAM_API_KEY        Steam Web API key (for vanity URL resolution)
#   STEAM_USER               Steam account username (for download)
#   STEAM_PASS               Steam account password
#   WIZARD_TARGET_HOST       Remote deployment host (e.g. root@209.42.26.106)
#   WIZARD_SKIP_STAGE        1 = skip game file download (already staged)

set -euo pipefail

echo "Legacy profile-based wizard is retired; it cannot provision the deployment-instance model." >&2
echo "Use an explicitly qualified deployment flow for the selected game." >&2
exit 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─── Colour + UI helpers ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_step()  { echo ""; echo -e "${BLUE}━━━ $* ━━━${RESET}"; echo ""; }
log_ok()    { echo -e "  ${GREEN}✓${RESET}  $*"; }
log_warn()  { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
log_error() { echo -e "  ${RED}✗${RESET}  $*" >&2; }
log_info()  { echo -e "     $*"; }
log_box()   { echo -e "${CYAN}$*${RESET}"; }

prompt() {
    # prompt "Question text" "default_value"
    local QUESTION="$1"
    local DEFAULT="${2:-}"
    local ANSWER
    if [[ -n "${DEFAULT}" ]]; then
        echo -ne "  ${BOLD}${QUESTION}${RESET} [${DEFAULT}]: "
    else
        echo -ne "  ${BOLD}${QUESTION}${RESET}: "
    fi
    read -r ANSWER
    echo "${ANSWER:-${DEFAULT}}"
}

prompt_secret() {
    local QUESTION="$1"
    local ANSWER
    echo -ne "  ${BOLD}${QUESTION}${RESET}: "
    read -rs ANSWER
    echo ""
    echo "${ANSWER}"
}

confirm() {
    # confirm "Question?" → returns 0 (yes) or 1 (no)
    local QUESTION="$1"
    local DEFAULT="${2:-y}"
    echo -ne "  ${BOLD}${QUESTION}${RESET} [${DEFAULT}/$([ "${DEFAULT}" = "y" ] && echo "n" || echo "y")]: "
    read -r REPLY
    REPLY="${REPLY:-${DEFAULT}}"
    [[ "${REPLY}" =~ ^[Yy]$ ]]
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
GAME="${WIZARD_GAME:-}"
UNATTENDED=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --game)        GAME="$2";    shift 2 ;;
        --unattended)  UNATTENDED=1; shift ;;
        --dry-run)     DRY_RUN=1;    shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

export PROVISION_DRY_RUN="${DRY_RUN}"

# ─── Banner ───────────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║         Game Server Admin — Setup Wizard                 ║${RESET}"
echo -e "${BOLD}║         Powered by GSA + VeriSimDB + Groove               ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  This wizard provisions a complete game server end-to-end:"
echo -e "  resolve operators → configure → download → deploy → verify"
echo ""
[[ "${UNATTENDED}" == "1" ]] && log_warn "Running in unattended mode — using environment variables"
[[ "${DRY_RUN}"    == "1" ]] && log_warn "Dry-run mode — no changes will be made"
echo ""

# ─── Step 1: Game selection ───────────────────────────────────────────────────
log_step "Step 1 / 7 — Game selection"

if [[ -z "${GAME}" ]] && [[ "${UNATTENDED}" == "0" ]]; then
    echo -e "  Available game profiles:"
    for f in "${REPO_ROOT}/profiles/"*.a2ml; do
        NAME="$(basename "${f}" .a2ml)"
        DISPLAY="$(grep -m1 'name=' "${f}" 2>/dev/null | grep -oP 'name="\K[^"]+' | head -1 || echo "${NAME}")"
        echo -e "    ${BOLD}${NAME}${RESET}  (${DISPLAY})"
    done
    echo ""
    GAME="$(prompt "Game profile" "minecraft-java")"
fi

if [[ -z "${GAME}" ]]; then
    log_error "No game selected. Set WIZARD_GAME or pass --game."
    exit 1
fi

if [[ ! -f "${REPO_ROOT}/profiles/${GAME}.a2ml" ]]; then
    log_error "Profile not found: profiles/${GAME}.a2ml"
    exit 1
fi

if [[ "${GAME}" == "cryofall" ]]; then
    log_error "CryoFall's legacy wizard path is retired: it assumes authenticated Steam login, obsolete paths and profile-based provisioning."
    log_info "The qualified CryoFall path is read-only and requires an explicitly declared deployment instance."
    exit 2
fi

log_ok "Game: ${GAME}"

# ─── Step 2: Steam API — resolve operator IDs ─────────────────────────────────
log_step "Step 2 / 7 — Steam operator IDs"

STEAM_API_KEY="${GSA_STEAM_API_KEY:-}"
if [[ -z "${STEAM_API_KEY}" ]] && [[ "${UNATTENDED}" == "0" ]]; then
    echo -e "  A Steam Web API key lets GSA look up Steam IDs from usernames."
    echo -e "  Get a free key at: ${CYAN}https://steamcommunity.com/dev/apikey${RESET}"
    echo -e "  (Press Enter to skip — you can fill in Steam IDs manually later)"
    echo ""
    STEAM_API_KEY="$(prompt "Steam Web API key" "")"
fi

GSA_CLI="${REPO_ROOT}/src/interface/ffi/zig-out/bin/gsa"

resolve_steam_id() {
    local VANITY="$1"
    local RESULT=""

    # If it looks like a Steam64 ID already (17 digits), use directly
    if [[ "${VANITY}" =~ ^[0-9]{17}$ ]]; then
        echo "${VANITY}"
        return
    fi

    # Try GSA CLI steam resolve if API key available
    if [[ -n "${STEAM_API_KEY}" ]] && [[ -x "${GSA_CLI}" ]]; then
        RESULT=$(GSA_STEAM_API_KEY="${STEAM_API_KEY}" \
            "${GSA_CLI}" steam resolve "${VANITY}" 2>/dev/null || true)
        if [[ "${RESULT}" =~ ^[0-9]{17}$ ]]; then
            echo "${RESULT}"
            return
        fi
    fi

    # Fall back: curl the Steam community XML directly
    if command -v curl >/dev/null 2>&1; then
        RESULT=$(curl -sf "https://steamcommunity.com/id/${VANITY}?xml=1" 2>/dev/null | \
            grep -oP '(?<=<steamID64>)\d+(?=</steamID64>)' || true)
        if [[ "${RESULT}" =~ ^[0-9]{17}$ ]]; then
            echo "${RESULT}"
            return
        fi
    fi

    # Could not resolve — return empty
    echo ""
}

# Resolve operator 1
OP1_INPUT="${WIZARD_OPERATOR_1:-}"
if [[ -z "${OP1_INPUT}" ]] && [[ "${UNATTENDED}" == "0" ]]; then
    echo -e "  Operator 1 (primary admin — you):"
    OP1_INPUT="$(prompt "Steam username or Steam64 ID" "hyperpolymath")"
fi
OP1_ID=""
if [[ -n "${OP1_INPUT}" ]]; then
    echo -n "    Resolving '${OP1_INPUT}'... "
    OP1_ID="$(resolve_steam_id "${OP1_INPUT}")"
    if [[ -n "${OP1_ID}" ]]; then
        echo -e "${GREEN}${OP1_ID}${RESET}"
        log_ok "Operator 1: ${OP1_INPUT} → ${OP1_ID}"
    else
        echo -e "${YELLOW}not found${RESET}"
        log_warn "Could not resolve '${OP1_INPUT}' — will use username as placeholder"
        OP1_ID="NEEDS_STEAM64_ID_FOR_${OP1_INPUT}"
    fi
fi

# Resolve operator 2
OP2_INPUT="${WIZARD_OPERATOR_2:-}"
if [[ -z "${OP2_INPUT}" ]] && [[ "${UNATTENDED}" == "0" ]]; then
    echo -e "  Operator 2 (co-admin — e.g. Joshua):"
    OP2_INPUT="$(prompt "Steam username or Steam64 ID (Enter to skip)" "")"
fi
OP2_ID=""
if [[ -n "${OP2_INPUT}" ]]; then
    echo -n "    Resolving '${OP2_INPUT}'... "
    OP2_ID="$(resolve_steam_id "${OP2_INPUT}")"
    if [[ -n "${OP2_ID}" ]]; then
        echo -e "${GREEN}${OP2_ID}${RESET}"
        log_ok "Operator 2: ${OP2_INPUT} → ${OP2_ID}"
    else
        echo -e "${YELLOW}not found${RESET}"
        log_warn "Could not resolve '${OP2_INPUT}' — will use username as placeholder"
        OP2_ID="NEEDS_STEAM64_ID_FOR_${OP2_INPUT}"
    fi
fi

# ─── Step 3: Server configuration ─────────────────────────────────────────────
log_step "Step 3 / 7 — Server configuration"

SETTINGS_FILE="${REPO_ROOT}/container/${GAME}/Settings.xml"
if [[ ! -f "${SETTINGS_FILE}" ]]; then
    log_error "Settings file not found: ${SETTINGS_FILE}"
    exit 1
fi

SERVER_NAME="${WIZARD_SERVER_NAME:-}"
MAX_PLAYERS="${WIZARD_MAX_PLAYERS:-}"
IS_PVE="${WIZARD_IS_PVE:-}"
WIPE_DAYS="${WIZARD_WIPE_DAYS:-}"
GATHERING="${WIZARD_GATHERING_RATE:-}"
LEARNING="${WIZARD_LEARNING_RATE:-}"
CRAFTING="${WIZARD_CRAFTING_RATE:-}"

if [[ "${UNATTENDED}" == "0" ]]; then
    echo -e "  Customise your server (press Enter to keep current values):"
    echo ""
    CURRENT_NAME=$(grep -oP '(?<=<ServerName>)[^<]+' "${SETTINGS_FILE}" || echo "Jewell Family Server")
    SERVER_NAME="$(prompt "Server name" "${CURRENT_NAME}")"

    CURRENT_MAX=$(grep -oP '(?<=<MaxPlayers>)[^<]+' "${SETTINGS_FILE}" || echo "10")
    MAX_PLAYERS="$(prompt "Max players" "${CURRENT_MAX}")"

    CURRENT_PVE=$(grep -oP '(?<=<IsPvE>)[^<]+' "${SETTINGS_FILE}" || echo "true")
    IS_PVE="$(prompt "PvE mode (true/false)" "${CURRENT_PVE}")"

    CURRENT_WIPE=$(grep -oP '(?<=<WipePeriodDays>)[^<]+' "${SETTINGS_FILE}" || echo "0")
    WIPE_DAYS="$(prompt "World wipe period in days (0=never)" "${CURRENT_WIPE}")"

    echo ""
    echo -e "  Rate multipliers (1.0 = default, 2.0 = twice as fast):"
    CURRENT_G=$(grep -oP '(?<=<GatheringSpeedMultiplier>)[^<]+' "${SETTINGS_FILE}" || echo "2.0")
    GATHERING="$(prompt "Gathering rate" "${CURRENT_G}")"

    CURRENT_L=$(grep -oP '(?<=<LearningSpeedMultiplier>)[^<]+' "${SETTINGS_FILE}" || echo "2.0")
    LEARNING="$(prompt "Learning rate" "${CURRENT_L}")"

    CURRENT_C=$(grep -oP '(?<=<CraftingSpeedMultiplier>)[^<]+' "${SETTINGS_FILE}" || echo "2.0")
    CRAFTING="$(prompt "Crafting rate" "${CURRENT_C}")"
fi

# Apply configuration to Settings.xml
SERVER_NAME="${SERVER_NAME:-Jewell Family Server}"
MAX_PLAYERS="${MAX_PLAYERS:-10}"
IS_PVE="${IS_PVE:-true}"
WIPE_DAYS="${WIPE_DAYS:-0}"
GATHERING="${GATHERING:-2.0}"
LEARNING="${LEARNING:-2.0}"
CRAFTING="${CRAFTING:-2.0}"

if [[ "${DRY_RUN}" == "0" ]]; then
    # Update Settings.xml with wizard values
    python3 - "${SETTINGS_FILE}" <<PYEOF
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

def replace_tag(xml, tag, value):
    return re.sub(f'(<{tag}>)[^<]*(</\\s*{tag}>)', f'\\g<1>{value}\\g<2>', xml)

content = replace_tag(content, 'ServerName',               '${SERVER_NAME}')
content = replace_tag(content, 'MaxPlayers',               '${MAX_PLAYERS}')
content = replace_tag(content, 'IsPvE',                    '${IS_PVE}')
content = replace_tag(content, 'WipePeriodDays',           '${WIPE_DAYS}')
content = replace_tag(content, 'GatheringSpeedMultiplier', '${GATHERING}')
content = replace_tag(content, 'LearningSpeedMultiplier',  '${LEARNING}')
content = replace_tag(content, 'CraftingSpeedMultiplier',  '${CRAFTING}')

# Update operators
if '${OP1_ID}' or '${OP2_ID}':
    ops = ''
    if '${OP1_ID}':
        ops += f'    <Operator steamId="${OP1_ID}" name="${OP1_INPUT:-operator1}" />\n'
    if '${OP2_ID}':
        ops += f'    <Operator steamId="${OP2_ID}" name="${OP2_INPUT:-operator2}" />\n'
    if ops:
        ops_block = f'  <Operators>\n{ops}  </Operators>'
        # Replace existing Operators block (including commented version)
        content = re.sub(
            r'(\s*<!--.*?<Operators>.*?</Operators>.*?-->)',
            '\n  ' + ops_block,
            content, flags=re.DOTALL
        )
        if '<Operators>' not in content:
            content = content.replace('</server-settings>', f'\n  {ops_block}\n\n</server-settings>')

with open(path, 'w') as f:
    f.write(content)
print('Settings.xml updated')
PYEOF
    log_ok "Settings.xml configured"
else
    log_warn "Dry run — Settings.xml not modified"
fi

# ─── Step 4: Stage game files ─────────────────────────────────────────────────
log_step "Step 4 / 7 — Game file staging"

SKIP_STAGE="${WIZARD_SKIP_STAGE:-0}"
TARGET_HOST="${WIZARD_TARGET_HOST:-}"

if [[ "${SKIP_STAGE}" == "1" ]]; then
    log_warn "WIZARD_SKIP_STAGE=1 — assuming game files are already staged"
elif [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "Dry run — skipping game file staging"
else
    # Check if files are already staged in the volume
    STAGED=0
    if [[ -n "${TARGET_HOST}" ]]; then
        VOL_PATH=$(ssh "${TARGET_HOST}" \
            "podman volume inspect cryofall-game-data --format '{{.Mountpoint}}'" 2>/dev/null || true)
        if [[ -n "${VOL_PATH}" ]] && ssh "${TARGET_HOST}" "test -f '${VOL_PATH}/CryoFall_Server.dll'" 2>/dev/null; then
            STAGED=1
        fi
    else
        VOL_PATH=$(podman volume inspect cryofall-game-data --format '{{.Mountpoint}}' 2>/dev/null || true)
        if [[ -n "${VOL_PATH}" ]] && [[ -f "${VOL_PATH}/CryoFall_Server.dll" ]]; then
            STAGED=1
        fi
    fi

    if [[ "${STAGED}" == "1" ]]; then
        log_ok "Game files already staged — skipping download"
    else
        log_info "Game files not found — starting SteamCMD download..."

        STEAM_ARGS=(
            "--app-id" "1061710"
        )
        [[ -n "${TARGET_HOST}" ]] && STEAM_ARGS+=("--target-host" "${TARGET_HOST}")

        STEAM_USER="${STEAM_USER:-}" \
        STEAM_PASS="${STEAM_PASS:-}" \
        bash "${SCRIPT_DIR}/steam-stage.sh" "${STEAM_ARGS[@]}"
    fi
fi

# ─── Step 5: Provision server ─────────────────────────────────────────────────
log_step "Step 5 / 7 — Server provisioning"

PROVISION_ARGS=("${GAME}")
PROVISION_EXTRA=()
[[ "${DRY_RUN}" == "1" ]] && export PROVISION_DRY_RUN=1
[[ "${SKIP_STAGE}" == "1" ]] && export PROVISION_SKIP_BUILD=0

bash "${SCRIPT_DIR}/provision-server.sh" "${GAME}"

# ─── Step 6: Health verification ─────────────────────────────────────────────
log_step "Step 6 / 7 — Health verification"

CHECK_HOST="${TARGET_HOST:-localhost}"
PROBE_HOST="${CHECK_HOST/root@/}"
PROBE_HOST="${PROBE_HOST%%:*}"

if [[ "${DRY_RUN}" == "0" ]]; then
    GSA_CLI="${REPO_ROOT}/src/interface/ffi/zig-out/bin/gsa"
    if [[ -x "${GSA_CLI}" ]]; then
        log_info "Probing ${PROBE_HOST}:6000..."
        sleep 10  # let the server start
        "${GSA_CLI}" probe "${PROBE_HOST}" 6000 2>/dev/null && \
            log_ok "Server probe successful — CryoFall fingerprinted" || \
            log_warn "Probe not yet responding — server may still be starting"
    else
        log_warn "GSA CLI not built — skipping probe (run: just build)"
    fi
else
    log_warn "Dry run — skipping probe"
fi

# ─── Step 7: Report ───────────────────────────────────────────────────────────
log_step "Step 7 / 7 — Complete!"

echo -e "${GREEN}${BOLD}"
echo "  ╔═══════════════════════════════════════════════════════╗"
echo "  ║   Your ${GAME} server is provisioned!                  "
echo "  ╚═══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "  ${BOLD}Connection${RESET}"
echo -e "    Server:   ${PROBE_HOST}:${PORTS_UDP%% *} (UDP)"
echo ""
echo -e "  ${BOLD}Admin operators${RESET}"
[[ -n "${OP1_ID}" ]] && echo -e "    ${OP1_INPUT:-op1}  →  ${OP1_ID}"
[[ -n "${OP2_ID}" ]] && echo -e "    ${OP2_INPUT:-op2}  →  ${OP2_ID}"
if [[ "${OP2_ID}" =~ ^NEEDS_STEAM64 ]]; then
    echo ""
    log_warn "${OP2_INPUT}'s Steam64 ID couldn't be resolved automatically."
    log_info "Use the game's documented operator mechanism to add this ID."
fi
echo ""
echo -e "  ${BOLD}Manage via GSA${RESET}"
echo -e "    gsa instance status --file <instance.json> --id <instance-id> --host-id <host-key>"
echo -e "    gsa instance logs --file <instance.json> --id <instance-id> --host-id <host-key>"
echo ""
echo -e "  ${BOLD}Self-heal watchdog${RESET}"
echo -e "    Legacy profile-based watchdogs are not instance-aware."
echo ""
echo -e "  ${BOLD}DNS${RESET}"
echo -e "    Use a DNS-only record for game UDP endpoints; HTTP proxies do not carry game traffic."
echo ""
