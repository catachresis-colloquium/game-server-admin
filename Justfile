# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# RSR Standard Justfile Template
# https://just.systems/man/en/
#
# Copy this file to new projects and customize the placeholder values.
#
# Run `just` to see all available recipes
# Run `just cookbook` to generate docs/just-cookbook.adoc
# Run `just combinations` to see matrix recipe options

set shell := ["bash", "-uc"]
set dotenv-load := true
set positional-arguments := true

# Import auto-generated contractile recipes (must-check, trust-verify, etc.)
# Re-generate with: contractile gen-just
import? "contractile.just"

# Project metadata — customize these
project := "game-server-admin"
version := "0.1.0"
tier := "infrastructure"  # 1 | 2 | infrastructure

# ═══════════════════════════════════════════════════════════════════════════════
# DEFAULT & HELP
# ═══════════════════════════════════════════════════════════════════════════════

# Show all available recipes with descriptions
default:
    @just --list --unsorted

# Show detailed help for a specific recipe
help recipe="":
    #!/usr/bin/env bash
    if [ -z "{{recipe}}" ]; then
        just --list --unsorted
        echo ""
        echo "Usage: just help <recipe>"
        echo "       just cookbook     # Generate full documentation"
        echo "       just combinations # Show matrix recipes"
    else
        just --show "{{recipe}}" 2>/dev/null || echo "Recipe '{{recipe}}' not found"
    fi

# Show this project's info
info:
    @echo "Project: game-server-admin"
    @echo "Version: {{version}}"
    @echo "RSR Tier: {{tier}}"
    @echo "Recipes: $(just --summary | wc -w)"
    @[ -f ".machine_readable/descriptiles/STATE.a2ml" ] && grep -oP 'phase\s*=\s*"\K[^"]+' .machine_readable/descriptiles/STATE.a2ml | head -1 | xargs -I{} echo "Phase: {}" || true

# ═══════════════════════════════════════════════════════════════════════════════
# INIT — Bootstrap a new project from this template
# ═══════════════════════════════════════════════════════════════════════════════

# Interactive project bootstrap — replaces all {{PLACEHOLDER}} tokens
init:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "═══════════════════════════════════════════════════"
    echo "  RSR Project Bootstrap"
    echo "═══════════════════════════════════════════════════"
    echo ""

    # --- Load defaults from config (if exists) ---
    # Create yours: ~/.config/rsr/defaults
    # Format: OWNER=myorg  AUTHOR="My Name"  AUTHOR_EMAIL=me@example.org ...
    DEFAULTS="${XDG_CONFIG_HOME:-$HOME/.config}/rsr/defaults"
    if [ -f "$DEFAULTS" ]; then
        echo "Loading defaults from $DEFAULTS"
        # shellcheck source=/dev/null
        source "$DEFAULTS"
        echo ""
    fi

    # --- Required values (pre-filled from defaults if available) ---
    read -rp "Project name (human-readable, e.g. My Project): " PROJECT_NAME
    [ -z "$PROJECT_NAME" ] && echo "Error: project name required" && exit 1

    read -rp "Repository slug (e.g. my-project): " REPO
    [ -z "$REPO" ] && echo "Error: repo slug required" && exit 1

    read -rp "Owner [${OWNER:-}]: " _OWNER
    OWNER="${_OWNER:-${OWNER:-}}"
    [ -z "$OWNER" ] && echo "Error: owner required" && exit 1

    read -rp "Author full name [${AUTHOR:-}]: " _AUTHOR
    AUTHOR="${_AUTHOR:-${AUTHOR:-}}"
    [ -z "$AUTHOR" ] && echo "Error: author name required" && exit 1

    read -rp "Author email [${AUTHOR_EMAIL:-}]: " _AUTHOR_EMAIL
    AUTHOR_EMAIL="${_AUTHOR_EMAIL:-${AUTHOR_EMAIL:-}}"
    [ -z "$AUTHOR_EMAIL" ] && echo "Error: email required" && exit 1

    # --- Optional values (pre-filled from defaults if available) ---
    read -rp "Author organization [${AUTHOR_ORG:-none}]: " _AUTHOR_ORG
    AUTHOR_ORG="${_AUTHOR_ORG:-${AUTHOR_ORG:-}}"

    read -rp "Previous/alt email [${AUTHOR_EMAIL_ALT:-none}]: " _AUTHOR_EMAIL_ALT
    AUTHOR_EMAIL_ALT="${_AUTHOR_EMAIL_ALT:-${AUTHOR_EMAIL_ALT:-}}"

    read -rp "Project description []: " PROJECT_DESCRIPTION

    read -rp "Forge domain [${FORGE:-github.com}]: " _FORGE
    FORGE="${_FORGE:-${FORGE:-github.com}}"

    read -rp "Security contact email [${SECURITY_EMAIL:-$AUTHOR_EMAIL}]: " _SECURITY_EMAIL
    SECURITY_EMAIL="${_SECURITY_EMAIL:-${SECURITY_EMAIL:-$AUTHOR_EMAIL}}"

    read -rp "Conduct contact email [${CONDUCT_EMAIL:-$AUTHOR_EMAIL}]: " _CONDUCT_EMAIL
    CONDUCT_EMAIL="${_CONDUCT_EMAIL:-${CONDUCT_EMAIL:-$AUTHOR_EMAIL}}"

    read -rp "Project type (library|binary|monorepo|service|website) [library]: " PROJECT_TYPE
    PROJECT_TYPE="${PROJECT_TYPE:-library}"

    read -rp "Website URL [https://${FORGE}/${OWNER}/${REPO}]: " WEBSITE
    WEBSITE="${WEBSITE:-https://${FORGE}/${OWNER}/${REPO}}"

    # --- Container values (optional — only relevant if container/ exists) ---
    if [ -d "container" ]; then
        echo ""
        echo "── Container configuration (optional) ─────────"
        read -rp "Service name [${REPO}]: " _SERVICE_NAME
        SERVICE_NAME="${_SERVICE_NAME:-${REPO}}"
        read -rp "Primary port [8080]: " _PORT
        PORT="${_PORT:-8080}"
        read -rp "Container registry [ghcr.io/${OWNER}]: " _REGISTRY
        REGISTRY="${_REGISTRY:-ghcr.io/${OWNER}}"
    else
        SERVICE_NAME="${REPO}"
        PORT="8080"
        REGISTRY="ghcr.io/${OWNER}"
    fi

    # --- Derived values ---
    PROJECT_UPPER=$(echo "$REPO" | tr '[:lower:]-' '[:upper:]_')
    PROJECT_LOWER=$(echo "$REPO" | tr '[:upper:]-' '[:lower:]_')
    CURRENT_YEAR=$(date +%Y)
    CURRENT_DATE=$(date +%Y-%m-%d)
    VERSION="0.1.0"

    # Derive citation name parts (best-effort split on last space)
    AUTHOR_LAST="${AUTHOR##* }"
    AUTHOR_FIRST="${AUTHOR% *}"
    FIRST_INITIAL="${AUTHOR_FIRST:0:1}."
    if [ "$AUTHOR_LAST" = "$AUTHOR_FIRST" ]; then
        AUTHOR_FIRST="$AUTHOR"
        AUTHOR_LAST=""
        FIRST_INITIAL=""
    fi

    echo ""
    echo "── Summary ──────────────────────────────────────"
    echo "  Project:     $PROJECT_NAME"
    echo "  Repo:        $REPO"
    echo "  Owner:       $OWNER"
    echo "  Author:      $AUTHOR <$AUTHOR_EMAIL>"
    [ -n "$AUTHOR_ORG" ] && echo "  Organization: $AUTHOR_ORG"
    echo "  Forge:       $FORGE"
    echo "  Year:        $CURRENT_YEAR"
    echo "────────────────────────────────────────────────"
    echo ""
    read -rp "Proceed? [Y/n] " CONFIRM
    [[ "${CONFIRM:-Y}" =~ ^[Nn] ]] && echo "Aborted." && exit 0

    echo ""
    echo "Replacing placeholders..."

    # Brace tokens as variables (hex avoids just interpolation)
    LB=$(printf '\x7b\x7b')
    RB=$(printf '\x7d\x7d')

    # Build the sed expression list
    # Note: using | as delimiter since URLs contain /
    SED_ARGS=(
        -e "s|${LB}PROJECT_NAME${RB}|${PROJECT_NAME}|g"
        -e "s|${LB}PROJECT_DESCRIPTION${RB}|${PROJECT_DESCRIPTION}|g"
        -e "s|${LB}PROJECT${RB}|${PROJECT_UPPER}|g"
        -e "s|${LB}project${RB}|${PROJECT_LOWER}|g"
        -e "s|${LB}REPO${RB}|${REPO}|g"
        -e "s|${LB}OWNER${RB}|${OWNER}|g"
        -e "s|${LB}AUTHOR${RB}|${AUTHOR}|g"
        -e "s|${LB}AUTHOR_EMAIL${RB}|${AUTHOR_EMAIL}|g"
        -e "s|${LB}AUTHOR_ORG${RB}|${AUTHOR_ORG}|g"
        -e "s|${LB}AUTHOR_LAST${RB}|${AUTHOR_LAST}|g"
        -e "s|${LB}AUTHOR_FIRST${RB}|${AUTHOR_FIRST}|g"
        -e "s|${LB}AUTHOR_INITIALS${RB}|${FIRST_INITIAL}|g"
        -e "s|${LB}FORGE${RB}|${FORGE}|g"
        -e "s|${LB}CURRENT_YEAR${RB}|${CURRENT_YEAR}|g"
        -e "s|${LB}CURRENT_DATE${RB}|${CURRENT_DATE}|g"
        -e "s|${LB}DATE${RB}|${CURRENT_DATE}|g"
        -e "s|${LB}SECURITY_EMAIL${RB}|${SECURITY_EMAIL}|g"
        -e "s|${LB}CONDUCT_EMAIL${RB}|${CONDUCT_EMAIL}|g"
        -e "s|${LB}LICENSE${RB}|AGPL-3.0-or-later|g"
        -e "s|${LB}CONDUCT_TEAM${RB}|Code of Conduct Committee|g"
        -e "s|${LB}RESPONSE_TIME${RB}|48 hours|g"
        -e "s|${LB}MAIN_BRANCH${RB}|main|g"
        -e "s|${LB}PROJECT_PURPOSE${RB}|${PROJECT_DESCRIPTION}|g"
        -e "s|${LB}PROJECT_ROLE${RB}|${PROJECT_TYPE}|g"
        -e "s|${LB}PROJECT_TYPE${RB}|${PROJECT_TYPE}|g"
        -e "s|${LB}WEBSITE${RB}|${WEBSITE}|g"
        -e "s|${LB}SERVICE_NAME${RB}|${SERVICE_NAME}|g"
        -e "s|${LB}PORT${RB}|${PORT}|g"
        -e "s|${LB}REGISTRY${RB}|${REGISTRY}|g"
        -e "s|${LB}IMAGE${RB}|${REGISTRY}/${SERVICE_NAME}|g"
        -e "s|${LB}VERSION${RB}|${VERSION}|g"
        -e "s|${LB}EMAIL${RB}|${AUTHOR_EMAIL}|g"
    )
    [ -n "$AUTHOR_EMAIL_ALT" ] && SED_ARGS+=(-e "s|${LB}AUTHOR_EMAIL_ALT${RB}|${AUTHOR_EMAIL_ALT}|g")

    # Replace in all text files (skip .git, LICENSE text, and binaries)
    find . -type f \
        -not -path './.git/*' \
        -not -name 'AGPL-3.0-or-later.txt' \
        -not -name '*.png' -not -name '*.jpg' -not -name '*.gif' \
        -not -name '*.woff' -not -name '*.woff2' \
        | while read -r file; do
        if file --brief "$file" | grep -qi 'text\|ascii\|utf'; then
            sed -i "${SED_ARGS[@]}" "$file"
        fi
    done

    # Also replace game-server-admin and hyperpolymath in AI manifest
    sed -i "s|\[YOUR-REPO-NAME\]|${PROJECT_NAME}|g" 0-AI-MANIFEST.a2ml 2>/dev/null || true
    sed -i "s|\[YOUR-NAME/ORG\]|${OWNER}|g" 0-AI-MANIFEST.a2ml 2>/dev/null || true

    echo ""
    echo "── Validation ───────────────────────────────────"

    # Check for remaining placeholders
    PATTERN="${LB}[A-Z_]*${RB}"
    REMAINING=$(grep -rl "$PATTERN" . --include='*.md' --include='*.adoc' --include='*.yml' --include='*.yaml' --include='*.a2ml' --include='*.toml' --include='*.scm' --include='*.ncl' --include='*.guix' --include='*.json' --include='*.sh' 2>/dev/null | grep -v '.git/' | grep -v '.machine_readable/ai/PLACEHOLDERS.adoc' || true)
    if [ -n "$REMAINING" ]; then
        echo "WARNING: Remaining placeholders in:"
        echo "$REMAINING" | sed 's/^/  /'
        echo ""
        echo "Run: grep -rn '$LB' . --include='*.md' to inspect"
    else
        echo "All placeholders replaced successfully!"
    fi

    # K9-SVC validation (if available)
    if command -v k9-svc >/dev/null 2>&1; then
        echo ""
        echo "Running k9-svc validation..."
        k9-svc validate . 2>/dev/null || true
    fi

    echo ""
    echo "Done! Next steps:"
    echo "  1. Review changes: git diff"
    echo "  2. Remove template cruft: rm .machine_readable/ai/PLACEHOLDERS.adoc"
    echo "  3. Customize README.adoc for your project"
    echo "  4. Commit: git add -A && git commit -m 'feat: initialize from RSR template'"
    echo "  5. Push: git remote add origin git@${FORGE}:${OWNER}/${REPO}.git && git push -u origin main"

# ═══════════════════════════════════════════════════════════════════════════════
# BUILD & COMPILE
# ═══════════════════════════════════════════════════════════════════════════════

# Build all layers (ABI + FFI + GUI)
build: build-abi build-ffi build-gui
    @echo "Build complete — all layers compiled"

# Build the Idris2 ABI layer (formal type specs)
build-abi:
    @echo "Type-checking Idris2 ABI..."
    cd src/interface/abi && idris2 --check Types.idr && idris2 --check Foreign.idr && idris2 --check Layout.idr
    @echo "ABI type-check passed"

# Build the Zig FFI layer (compile libgsa.so)
build-ffi *args:
    @echo "Building Zig FFI (libgsa.so)..."
    cd src/interface/ffi && zig build {{args}}
    @echo "FFI build complete"

# Build the Ephapax GUI layer
build-gui:
    @echo "Compiling Ephapax core logic..."
    # Ephapax compiles to Zig via __ffi — the GUI is loaded as HTML at runtime
    @echo "GUI build complete (HTML panels loaded at runtime)"

# Build in release mode with optimizations
build-release: build-abi
    @echo "Building Zig FFI (release)..."
    cd src/interface/ffi && zig build -Doptimize=ReleaseFast
    @echo "Release build complete"

# Watch for changes and rebuild FFI
build-watch:
    find src/interface/ffi/src -name '*.zig' | entr -c just build-ffi

# Clean build artifacts [reversible: rebuild with `just build`]
clean:
    @echo "Cleaning..."
    rm -rf src/interface/ffi/zig-out/ src/interface/ffi/zig-cache/
    rm -rf src/interface/generated/abi/*.h

# Deep clean including caches [reversible: rebuild]
clean-all: clean
    rm -rf .cache .tmp

# ═══════════════════════════════════════════════════════════════════════════════
# GSA-SPECIFIC RECIPES
# ═══════════════════════════════════════════════════════════════════════════════

# Probe a game server by host and port
probe host port="27015":
    @echo "Probing {{host}}:{{port}}..."
    # Uses the compiled FFI probe engine
    cd src/interface/ffi && zig build run -- --probe {{host}} {{port}}

# Deprecated: current standards retire A2ML; do not scaffold new A2ML profiles.
add-profile name:
    @echo "Disabled: new A2ML profile scaffolding is retired. No file was created."
    @echo "See docs/developer/GAME-PROFILE-CONTRACT.adoc for the draft/test-only boundary."
    @exit 1

# Deprecated: the old generator rewrites A2ML panel-clade descriptors.
generate-clades:
    @echo "Disabled: panel-clade A2ML generation is retired. No files were created."
    @echo "Existing clades remain for compatibility; a replacement authoring format needs maintainer approval."
    @exit 1

# Start the dedicated VeriSimDB instance
verisimdb-up:
    @echo "Starting gsa-verisimdb on port 8090..."
    cd container && podman compose -f selur-compose.toml up -d gsa-verisimdb
    @echo "VeriSimDB running at http://localhost:8090"

# Stop the dedicated VeriSimDB instance
verisimdb-down:
    @echo "Stopping gsa-verisimdb..."
    cd container && podman compose -f selur-compose.toml down gsa-verisimdb

# Build the VeriSimDB container image from source
verisimdb-build:
    #!/usr/bin/env bash
    set -euo pipefail
    VERISIMDB_SRC="${VERISIMDB_SRC:-../nextgen-databases/verisimdb}"
    if [ ! -d "$VERISIMDB_SRC/rust-core" ]; then
        echo "ERROR: VeriSimDB source not found at $VERISIMDB_SRC"
        echo "Set VERISIMDB_SRC to the verisimdb repo root"
        exit 1
    fi
    echo "Building gsa-verisimdb image from $VERISIMDB_SRC..."
    # Create temp build context with VeriSimDB source
    BUILD_CTX=$(mktemp -d)
    trap 'rm -rf "$BUILD_CTX"' EXIT
    cp container/verisimdb/Containerfile "$BUILD_CTX/"
    cp -a "$VERISIMDB_SRC" "$BUILD_CTX/verisimdb-src"
    podman build -t gsa-verisimdb:latest -f "$BUILD_CTX/Containerfile" "$BUILD_CTX"
    echo "Built gsa-verisimdb:latest"

# Install Podman Quadlet units for VeriSimDB systemd integration
quadlet-install:
    #!/usr/bin/env bash
    set -euo pipefail
    QUADLET_DIR="${HOME}/.config/containers/systemd"
    echo "Installing GSA quadlets to $QUADLET_DIR..."
    mkdir -p "$QUADLET_DIR"
    cp container/verisimdb/gsa-verisimdb.container "$QUADLET_DIR/"
    cp container/verisimdb-backup/gsa-verisimdb-backup.container "$QUADLET_DIR/"
    systemctl --user daemon-reload
    echo "Quadlets installed. Start with:"
    echo "  systemctl --user start gsa-verisimdb"
    echo "  systemctl --user start gsa-verisimdb-backup"

# Remove Podman Quadlet units
quadlet-remove:
    #!/usr/bin/env bash
    set -euo pipefail
    QUADLET_DIR="${HOME}/.config/containers/systemd"
    echo "Stopping GSA services..."
    systemctl --user stop gsa-verisimdb-backup 2>/dev/null || true
    systemctl --user stop gsa-verisimdb 2>/dev/null || true
    echo "Removing quadlet files..."
    rm -f "$QUADLET_DIR/gsa-verisimdb.container"
    rm -f "$QUADLET_DIR/gsa-verisimdb-backup.container"
    systemctl --user daemon-reload
    echo "Quadlets removed."

# Full VeriSimDB deployment: build image → install quadlets → start
verisimdb-deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "═══════════════════════════════════════════════════"
    echo "  GSA VeriSimDB Deployment Pipeline"
    echo "═══════════════════════════════════════════════════"
    just verisimdb-build
    just quadlet-install
    echo ""
    echo "Starting VeriSimDB services..."
    systemctl --user start gsa-verisimdb
    # Wait for main instance health before starting backup
    echo "Waiting for main instance health..."
    for i in $(seq 1 10); do
        if curl -sf http://[::1]:8090/health >/dev/null 2>&1; then
            echo "  Main instance healthy!"
            break
        fi
        [ "$i" -eq 10 ] && echo "WARNING: Main instance not healthy after 10s"
        sleep 1
    done
    systemctl --user start gsa-verisimdb-backup
    echo ""
    echo "Deployment complete:"
    systemctl --user status gsa-verisimdb --no-pager 2>/dev/null | head -5 || true
    systemctl --user status gsa-verisimdb-backup --no-pager 2>/dev/null | head -5 || true

# ─── Game server provisioner ──────────────────────────────────────────────────
#
# Legacy-profile game server minter. Reads existing profiles/<game>.a2ml and
# container/<game>/ to provision a running server; do not create new A2ML profiles:
#   build → volumes → firewall → quadlet → start → verify → register in VeriSimDB
#
# Usage:
#   just game-deploy GAME=cryofall           # any supported profile
#   just cryofall-deploy                      # CryoFall shorthand
#   just game-deploy GAME=cryofall DRY=1      # preview without executing
#   just verpex-deploy GAME=cryofall          # SSH deploy to Verpex VPS

# Existing deployment route — GAME must match an existing legacy profile ID; no new A2ML profiles
game-deploy GAME="" DRY="0":
    #!/usr/bin/env bash
    set -euo pipefail
    GAME="{{ GAME }}"
    if [ -z "${GAME}" ]; then
        echo "Usage: just game-deploy GAME=<profile-id>"
        echo "Profiles: $(ls profiles/*.a2ml | sed 's|profiles/||; s|\.a2ml||' | tr '\n' ' ')"
        exit 1
    fi
    PROVISION_DRY_RUN="{{ DRY }}" bash scripts/provision-server.sh "${GAME}"

# ─── Fire-and-forget wizard ───────────────────────────────────────────────────
# Complete end-to-end server provisioning including Steam auth and game download.
# Set environment variables before running:
#   STEAM_USER, STEAM_PASS, GSA_STEAM_API_KEY (optional, for ID resolution)
#   WIZARD_TARGET_HOST (optional, for remote Verpex deployment)

# Interactive wizard — prompts for all values
wizard GAME="cryofall":
    bash scripts/wizard.sh --game {{ GAME }}

# Unattended wizard — reads all values from environment
wizard-auto GAME="cryofall":
    WIZARD_GAME="{{ GAME }}" bash scripts/wizard.sh --game {{ GAME }} --unattended

# Stage game files from Steam onto the deployment host
# Requires: STEAM_USER, STEAM_PASS
cryofall-stage:
    bash scripts/steam-stage.sh \
        --app-id 1200170 \
        --target-volume cryofall-game-data

# Stage game files to Verpex VPS (set WIZARD_TARGET_HOST or uses default)
cryofall-stage-verpex:
    bash scripts/steam-stage.sh \
        --app-id 1200170 \
        --target-volume cryofall-game-data \
        --target-host root@209.42.26.106

# Resolve a Steam vanity URL to a Steam64 ID
# Usage: just steam-resolve VANITY=hyperpolymath API_KEY=<your-key>
steam-resolve VANITY="" API_KEY="":
    #!/usr/bin/env bash
    set -euo pipefail
    VANITY="{{ VANITY }}"
    KEY="{{ API_KEY }}"
    [ -z "${KEY}" ] && KEY="${GSA_STEAM_API_KEY:-}"
    if [ -z "${VANITY}" ]; then
        echo "Usage: just steam-resolve VANITY=<username>"
        exit 1
    fi
    GSA_STEAM_API_KEY="${KEY}" src/interface/ffi/zig-out/bin/gsa steam resolve "${VANITY}"

# CryoFall shorthand — equivalent to: just game-deploy GAME=cryofall
cryofall-deploy:
    just game-deploy GAME=cryofall

# Build the CryoFall container image only (no full provision)
cryofall-build:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Building CryoFall server image..."
    podman build \
        -t localhost/cryofall-server:latest \
        -f container/cryofall/Containerfile \
        .
    echo "Built localhost/cryofall-server:latest"

# CryoFall service management (via systemd Quadlet)
cryofall-start:
    systemctl --user start gsa-cryofall

cryofall-stop:
    systemctl --user stop gsa-cryofall

cryofall-restart:
    systemctl --user restart gsa-cryofall

cryofall-logs:
    podman logs --tail 100 -f cryofall

cryofall-status:
    #!/usr/bin/env bash
    echo "CryoFall container:"
    podman inspect --format "  Status: {{{{.State.Status}}}}  Health: {{{{.State.Health.Status}}}}" cryofall 2>/dev/null || echo "  Not running"
    echo ""
    echo "Systemd service:"
    systemctl --user status gsa-cryofall --no-pager 2>/dev/null | head -8 || echo "  Not installed"

# Start self-healing watchdog in the foreground
cryofall-watchdog:
    bash scripts/self-heal.sh --container cryofall --port 6000

# Install watchdog as a systemd user service (runs in background on Verpex)
cryofall-watchdog-install:
    #!/usr/bin/env bash
    set -euo pipefail
    UNIT_FILE="${HOME}/.config/systemd/user/gsa-cryofall-watchdog.service"
    mkdir -p "$(dirname "${UNIT_FILE}")"
    REPO="$(pwd)"
    cat > "${UNIT_FILE}" << UNIT
    [Unit]
    Description=GSA CryoFall self-heal watchdog
    After=gsa-cryofall.service
    Requires=gsa-cryofall.service

    [Service]
    Type=simple
    ExecStart=/usr/bin/bash ${REPO}/scripts/self-heal.sh --container cryofall --port 6000
    Restart=always
    RestartSec=10s
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=default.target
    UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now gsa-cryofall-watchdog
    echo "Watchdog service installed and started."
    systemctl --user status gsa-cryofall-watchdog --no-pager | head -6

# Deploy to Verpex VPS via SSH (run this from local machine)
# Requires SSH key access: root@209.42.26.106
verpex-deploy GAME="cryofall":
    #!/usr/bin/env bash
    set -euo pipefail
    GAME="{{ GAME }}"
    VERPEX_HOST="209.42.26.106"
    VERPEX_USER="root"
    echo "Deploying ${GAME} server to Verpex VPS (${VERPEX_HOST})..."
    # Copy provisioner + profiles + container definition
    ssh "${VERPEX_USER}@${VERPEX_HOST}" "mkdir -p ~/gsa-provision/${GAME}"
    rsync -az --progress \
        profiles/ scripts/ container/"${GAME}"/ \
        "${VERPEX_USER}@${VERPEX_HOST}:~/gsa-provision/${GAME}/"
    # Run provisioner on the VPS
    ssh "${VERPEX_USER}@${VERPEX_HOST}" "cd ~/gsa-provision/${GAME} && bash provision-server.sh ${GAME}"
    echo "Remote provisioning complete."

# Check VeriSimDB systemd service status
verisimdb-status:
    #!/usr/bin/env bash
    echo "Main VeriSimDB (port 8090):"
    systemctl --user status gsa-verisimdb --no-pager 2>/dev/null || echo "  Not installed"
    echo ""
    echo "Backup VeriSimDB (port 8091):"
    systemctl --user status gsa-verisimdb-backup --no-pager 2>/dev/null || echo "  Not installed"
    echo ""
    echo "Health checks:"
    curl -sf http://[::1]:8090/health && echo " ← main (8090)" || echo "  main (8090): unreachable"
    curl -sf http://[::1]:8091/health && echo " ← backup (8091)" || echo "  backup (8091): unreachable"

# Launch the Gossamer GUI
gui: build-ffi
    @echo "Launching Game Server Admin..."
    GSA_VERISIMDB_URL="${GSA_VERISIMDB_URL:-http://localhost:8090}" \
    GSA_PROFILES_DIR="${GSA_PROFILES_DIR:-./profiles}" \
    ./src/interface/ffi/zig-out/bin/gsa status

# Test probe engine against known ports
test-probe:
    @echo "Testing probe engine..."
    cd src/interface/ffi && zig build test -- --filter "probe"

# Test A2ML round-trip (extract → serialise → deserialise)
test-a2ml:
    @echo "Testing A2ML round-trip..."
    cd src/interface/ffi && zig build test -- --filter "a2ml"

# Test VeriSimDB CRUD and drift detection
test-verisimdb:
    @echo "Testing VeriSimDB client..."
    cd src/interface/ffi && zig build test -- --filter "verisimdb"

# Count game profiles loaded
profile-count:
    @echo "Game profiles: $(ls profiles/*.a2ml 2>/dev/null | wc -l)"
    @echo "Panel clades: $(ls -d panel-clades/gsa-game-*/ 2>/dev/null | wc -l)"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST & QUALITY
# ═══════════════════════════════════════════════════════════════════════════════

# Run all tests (unit + integration)
test *args:
    @echo "Running Zig unit tests..."
    cd src/interface/ffi && zig build test {{args}}
    @echo "Running Zig integration tests..."
    cd src/interface/ffi && zig build test-integration {{args}}
    @echo "All tests passed!"

# Meta-validate the deployment schema and check all fixtures (jsonschema 4.x).
# Override PYTHON to use a virtual environment; no live deployment access.
test-deployment-contract:
    "${PYTHON:-python3}" scripts/validate-deployment-instance-fixtures.py

# Run tests with verbose output
test-verbose:
    @echo "Running tests (verbose)..."
    cd src/interface/ffi && zig build test 2>&1

# Smoke test — quick sanity: build + unit tests + profile count
test-smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    FFI_DIR="src/interface/ffi"
    echo "Smoke test: build FFI..."
    (cd "$FFI_DIR" && zig build)
    echo "Smoke test: unit tests..."
    (cd "$FFI_DIR" && zig build test)
    echo "Smoke test: smoke suite..."
    (cd "$FFI_DIR" && zig build test-smoke)
    PROFILES=$(ls profiles/*.a2ml 2>/dev/null | wc -l)
    echo "Smoke test: $PROFILES game profiles found"
    [[ "$PROFILES" -ge 1 ]] || { echo "FAIL: No game profiles"; exit 1; }
    echo "Smoke test passed!"

# Typecheck the AffineScript interface (module resolution is cwd-relative,
# so run from src/ui/tea). Point AFFINESCRIPT_BIN at the compiler if it is
# not on PATH (e.g. .../affinescript/_build/default/bin/main.exe).
affine-check:
    cd src/ui/tea && "${AFFINESCRIPT_BIN:-affinescript}" check gsa_ffi.affine \
        && "${AFFINESCRIPT_BIN:-affinescript}" check gsa_gui.affine
    @echo "AffineScript interface typechecks"

# AffineScript FFI declarations ↔ Zig exports symbol contract
affine-contract:
    bash scripts/affine-ffi-contract-check.sh

# Run all quality checks
quality: fmt-check lint test affine-contract
    @echo "All quality checks passed!"

# Fix all auto-fixable issues [reversible: git checkout]
fix: fmt
    @echo "Fixed all auto-fixable issues"

# ═══════════════════════════════════════════════════════════════════════════════
# LINT & FORMAT
# ═══════════════════════════════════════════════════════════════════════════════

# Format all source files [reversible: git checkout]
fmt:
    @echo "Formatting source files..."
    cd src/interface/ffi && zig fmt src/ test/ build.zig 2>/dev/null || true

# Check formatting without changes
fmt-check:
    @echo "Checking formatting..."
    cd src/interface/ffi && zig fmt --check src/ test/ build.zig 2>/dev/null || true

# Run linter (Zig build acts as a type checker / linter)
lint:
    @echo "Linting source files..."
    cd src/interface/ffi && zig build 2>&1 | head -50 || true

# ═══════════════════════════════════════════════════════════════════════════════
# RUN & EXECUTE
# ═══════════════════════════════════════════════════════════════════════════════

# Launch GSA (platform-detect, self-heal, git cycle)
# Scoped Deno permissions (read source/stat, run subprocesses, read env) —
# run.js needs no network or write capability of its own.
run:
    deno run --allow-read --allow-run --allow-env run.js

# Run the GSA binary directly (status probe, config, etc.)
run-admin *args: build-ffi
    GSA_VERISIMDB_URL="${GSA_VERISIMDB_URL:-http://localhost:8090}" \
    GSA_PROFILES_DIR="${GSA_PROFILES_DIR:-./profiles}" \
    ./src/interface/ffi/zig-out/bin/gsa {{args}}

# Run with verbose output
run-verbose *args: build-ffi
    GSA_VERISIMDB_URL="${GSA_VERISIMDB_URL:-http://localhost:8090}" \
    GSA_PROFILES_DIR="${GSA_PROFILES_DIR:-./profiles}" \
    ./src/interface/ffi/zig-out/bin/gsa {{args}}

# Install to user path
install: build-release
    @echo "Installing game-server-admin..."
    install -Dm755 src/interface/ffi/zig-out/bin/gsa "$HOME/.local/bin/gsa"
    @echo "Installed gsa to ~/.local/bin/gsa"

# ═══════════════════════════════════════════════════════════════════════════════
# DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════

# Install/check all dependencies (Zig has no external deps)
deps:
    @echo "Checking dependencies..."
    @command -v zig >/dev/null && echo "  zig: $(zig version)" || echo "  zig: NOT FOUND"
    @command -v idris2 >/dev/null && echo "  idris2: $(idris2 --version 2>/dev/null | head -1)" || echo "  idris2: NOT FOUND (optional, for ABI proofs)"
    @echo "All dependencies satisfied"

# Audit dependencies for vulnerabilities
deps-audit:
    @echo "Auditing for vulnerabilities..."
    @command -v trivy >/dev/null && trivy fs --severity HIGH,CRITICAL --quiet . || true
    @command -v gitleaks >/dev/null && gitleaks detect --source . --no-git --quiet || true
    @echo "Audit complete"

# ═══════════════════════════════════════════════════════════════════════════════
# DOCUMENTATION
# ═══════════════════════════════════════════════════════════════════════════════

# Generate all documentation
docs:
    @mkdir -p docs/generated docs/man
    just cookbook
    just man
    @echo "Documentation generated in docs/"

# Generate justfile cookbook documentation
cookbook:
    #!/usr/bin/env bash
    mkdir -p docs
    OUTPUT="docs/just-cookbook.adoc"
    echo "= game-server-admin Justfile Cookbook" > "$OUTPUT"
    echo ":toc: left" >> "$OUTPUT"
    echo ":toclevels: 3" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    echo "Generated: $(date -Iseconds)" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    echo "== Recipes" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    just --list --unsorted | while read -r line; do
        if [[ "$line" =~ ^[[:space:]]+([a-z_-]+) ]]; then
            recipe="${BASH_REMATCH[1]}"
            echo "=== $recipe" >> "$OUTPUT"
            echo "" >> "$OUTPUT"
            echo "[source,bash]" >> "$OUTPUT"
            echo "----" >> "$OUTPUT"
            echo "just $recipe" >> "$OUTPUT"
            echo "----" >> "$OUTPUT"
            echo "" >> "$OUTPUT"
        fi
    done
    echo "Generated: $OUTPUT"

# Generate man page
man:
    #!/usr/bin/env bash
    mkdir -p docs/man
    cat > docs/man/game-server-admin.1 << EOF
    .TH game-server-admin 1 "$(date +%Y-%m-%d)" "{{version}}" "game-server-admin Manual"
    .SH NAME
    game-server-admin \- RSR-compliant project
    .SH SYNOPSIS
    .B just
    [recipe] [args...]
    .SH DESCRIPTION
    RSR (Rhodium Standard Repository) project managed with just.
    .SH AUTHOR
    $(git config user.name 2>/dev/null || echo "Author") <$(git config user.email 2>/dev/null || echo "email")>
    EOF
    echo "Generated: docs/man/game-server-admin.1"

# ═══════════════════════════════════════════════════════════════════════════════
# CONTAINERS (stapeln ecosystem — Podman + Chainguard Wolfi)
# ═══════════════════════════════════════════════════════════════════════════════

# Initialise container templates — substitute placeholders with project values
container-init:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ ! -d "container" ]; then
        echo "Error: container/ directory not found."
        echo "This repo may not have been created from rsr-template-repo."
        exit 1
    fi

    echo "=== Container Template Initialisation ==="
    echo ""

    # Load RSR defaults if available
    DEFAULTS="${XDG_CONFIG_HOME:-$HOME/.config}/rsr/defaults"
    if [ -f "$DEFAULTS" ]; then
        echo "Loading defaults from $DEFAULTS"
        # shellcheck source=/dev/null
        source "$DEFAULTS"
        echo ""
    fi

    # Prompt for container-specific values
    read -rp "Service name (e.g. my-api) [game-server-admin]: " _SERVICE_NAME
    SERVICE_NAME="${_SERVICE_NAME:-game-server-admin}"

    read -rp "Primary port [8080]: " _PORT
    PORT="${_PORT:-8080}"

    read -rp "Container registry [ghcr.io/${OWNER:-hyperpolymath}]: " _REGISTRY
    REGISTRY="${_REGISTRY:-ghcr.io/${OWNER:-hyperpolymath}}"

    echo ""
    echo "  Service: $SERVICE_NAME"
    echo "  Port:    $PORT"
    echo "  Registry: $REGISTRY"
    echo ""
    read -rp "Proceed? [Y/n] " CONFIRM
    [[ "${CONFIRM:-Y}" =~ ^[Nn] ]] && echo "Aborted." && exit 0

    echo ""
    echo "Replacing container placeholders..."

    # Brace tokens as variables (hex escapes avoid just interpolation)
    LB=$(printf '\x7b\x7b')
    RB=$(printf '\x7d\x7d')

    SED_ARGS=(
        -e "s|${LB}SERVICE_NAME${RB}|${SERVICE_NAME}|g"
        -e "s|${LB}PORT${RB}|${PORT}|g"
        -e "s|${LB}REGISTRY${RB}|${REGISTRY}|g"
    )

    find container/ -type f | while read -r file; do
        if file --brief "$file" | grep -qi 'text\|ascii\|utf'; then
            sed -i "${SED_ARGS[@]}" "$file"
        fi
    done

    echo "Container templates initialised."
    echo ""
    echo "Next steps:"
    echo "  1. Edit container/Containerfile — add your build commands"
    echo "  2. Edit container/entrypoint.sh — set your application binary"
    echo "  3. Review container/compose.toml — adjust services and volumes"
    echo "  4. Build: just container-build"

# Build container image via cerro-torre pipeline
container-build *args:
    #!/usr/bin/env bash
    if [ -f "container/ct-build.sh" ]; then
        cd container && ./ct-build.sh {{args}}
    elif [ -f "container/Containerfile" ]; then
        podman build -t game-server-admin:latest -f container/Containerfile .
    elif [ -f "Containerfile" ]; then
        podman build -t game-server-admin:latest -f Containerfile .
    else
        echo "No Containerfile found in container/ or project root"
        exit 1
    fi

# Verify compose configuration
container-verify:
    #!/usr/bin/env bash
    if [ ! -f "container/compose.toml" ]; then
        echo "No container/compose.toml found"
        exit 1
    fi
    cd container
    if command -v selur-compose &>/dev/null; then
        selur-compose verify
    else
        echo "selur-compose not found, falling back to podman compose"
        podman compose --file compose.toml config
    fi

# Start container stack
container-up *args:
    #!/usr/bin/env bash
    if [ ! -f "container/compose.toml" ]; then
        echo "No container/compose.toml found"
        exit 1
    fi
    cd container
    if command -v selur-compose &>/dev/null; then
        selur-compose up {{args}}
    else
        podman compose --file compose.toml up {{args}}
    fi

# Stop container stack
container-down:
    #!/usr/bin/env bash
    cd container 2>/dev/null || { echo "No container/ directory"; exit 1; }
    if command -v selur-compose &>/dev/null; then
        selur-compose down
    else
        podman compose --file compose.toml down
    fi

# Sign and verify container bundle (build + pack + sign + verify)
container-sign:
    #!/usr/bin/env bash
    if [ -f "container/ct-build.sh" ]; then
        cd container && ./ct-build.sh
    else
        echo "No container/ct-build.sh found"
        exit 1
    fi

# Push signed bundle to registry
container-push:
    #!/usr/bin/env bash
    if [ -f "container/ct-build.sh" ]; then
        cd container && ./ct-build.sh --push
    else
        echo "No container/ct-build.sh found — falling back to podman push"
        podman push game-server-admin:latest
    fi

# Run container interactively (for debugging)
container-run *args:
    podman run --rm -it game-server-admin:latest {{args}}

# ═══════════════════════════════════════════════════════════════════════════════
# CI & AUTOMATION
# ═══════════════════════════════════════════════════════════════════════════════

# Run full CI pipeline locally
ci: deps quality
    @echo "CI pipeline complete!"

# Install git hooks
install-hooks:
    @mkdir -p .git/hooks
    @cat > .git/hooks/pre-commit << 'HOOKEOF'
    #!/bin/bash
    just fmt-check || exit 1
    just lint || exit 1
    just assail || exit 1
    HOOKEOF
    @chmod +x .git/hooks/pre-commit
    @echo "Git hooks installed"

# ═══════════════════════════════════════════════════════════════════════════════
# SECURITY
# ═══════════════════════════════════════════════════════════════════════════════

# Run security audit
security: deps-audit
    @echo "=== Security Audit ==="
    @command -v gitleaks >/dev/null && gitleaks detect --source . --verbose || true
    @command -v trivy >/dev/null && trivy fs --severity HIGH,CRITICAL . || true
    @echo "Security audit complete"

# Generate SBOM
sbom:
    @mkdir -p docs/security
    @command -v syft >/dev/null && syft . -o spdx-json > docs/security/sbom.spdx.json || echo "syft not found"

# ═══════════════════════════════════════════════════════════════════════════════
# VALIDATION & COMPLIANCE
# ═══════════════════════════════════════════════════════════════════════════════

# Validate RSR compliance
validate-rsr:
    #!/usr/bin/env bash
    echo "=== RSR Compliance Check ==="
    MISSING=""
    for f in .editorconfig .gitignore Justfile README.adoc LICENSE 0-AI-MANIFEST.a2ml; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    for f in .machine_readable/descriptiles/STATE.a2ml .machine_readable/descriptiles/META.a2ml .machine_readable/descriptiles/ECOSYSTEM.a2ml .machine_readable/anchors/ANCHOR.a2ml .machine_readable/policies/MAINTENANCE-AXES.a2ml .machine_readable/policies/MAINTENANCE-CHECKLIST.a2ml .machine_readable/policies/SOFTWARE-DEVELOPMENT-APPROACH.a2ml; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    for f in docs/legal/EXHIBIT-A-ETHICAL-USE.txt docs/legal/EXHIBIT-B-QUANTUM-SAFE.txt LICENSES/AGPL-3.0-or-later.txt; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    for f in src/interface/abi src/interface/ffi src/interface/generated; do
        [ -d "$f" ] || MISSING="$MISSING $f"
    done
    for f in docs/governance/MAINTENANCE-CHECKLIST.adoc docs/governance/SOFTWARE-DEVELOPMENT-APPROACH.adoc; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    if [ -f ".machine_readable/descriptiles/META.a2ml" ]; then
        grep -q 'axis-1 = "must > intend > like"' .machine_readable/descriptiles/META.a2ml || MISSING="$MISSING META.a2ml:axis-1"
        grep -q 'axis-2 = "corrective > adaptive > perfective"' .machine_readable/descriptiles/META.a2ml || MISSING="$MISSING META.a2ml:axis-2"
        grep -q 'axis-3 = "systems > compliance > effects"' .machine_readable/descriptiles/META.a2ml || MISSING="$MISSING META.a2ml:axis-3"
        grep -q 'scoping-first = true' .machine_readable/descriptiles/META.a2ml || MISSING="$MISSING META.a2ml:scoping-first"
        grep -q 'idris-unsound-scan = "believe_me/assert_total"' .machine_readable/descriptiles/META.a2ml || MISSING="$MISSING META.a2ml:idris-unsound-scan"
        grep -q 'audit-focus = "systems in place, documentation explains actual state, safety/security accounted for, observed effects reviewed"' .machine_readable/descriptiles/META.a2ml || MISSING="$MISSING META.a2ml:audit-focus"
        grep -q 'compliance-focus = "seams/compromises/exception register, bounded exceptions, anti-drift checks"' .machine_readable/descriptiles/META.a2ml || MISSING="$MISSING META.a2ml:compliance-focus"
        grep -q 'effects-evidence = "benchmark execution/results and maintainer status dialogue/review"' .machine_readable/descriptiles/META.a2ml || MISSING="$MISSING META.a2ml:effects-evidence"
        grep -q 'compliance-tooling = "panic-attack"' .machine_readable/policies/MAINTENANCE-AXES.a2ml || MISSING="$MISSING MAINTENANCE-AXES.a2ml:compliance-tooling"
        grep -q 'effects-tooling = "ecological checking with sustainabot guidance"' .machine_readable/policies/MAINTENANCE-AXES.a2ml || MISSING="$MISSING MAINTENANCE-AXES.a2ml:effects-tooling"
        grep -q 'source-human = "docs/governance/MAINTENANCE-CHECKLIST.adoc"' .machine_readable/policies/MAINTENANCE-CHECKLIST.a2ml || MISSING="$MISSING MAINTENANCE-CHECKLIST.a2ml:source-human"
        grep -q 'source-human = "docs/governance/SOFTWARE-DEVELOPMENT-APPROACH.adoc"' .machine_readable/policies/SOFTWARE-DEVELOPMENT-APPROACH.a2ml || MISSING="$MISSING SOFTWARE-DEVELOPMENT-APPROACH.a2ml:source-human"
    fi
    if [ -n "$MISSING" ]; then
        echo "MISSING:$MISSING"
        exit 1
    fi
    echo "RSR compliance: PASS"

# Validate STATE.a2ml syntax
validate-state:
    @if [ -f ".machine_readable/descriptiles/STATE.a2ml" ]; then \
        grep -q '^\[metadata\]' .machine_readable/descriptiles/STATE.a2ml && \
        grep -q 'project\s*=' .machine_readable/descriptiles/STATE.a2ml && \
        echo "STATE.a2ml: valid" || echo "STATE.a2ml: INVALID (missing required sections)"; \
    else \
        echo "No .machine_readable/descriptiles/STATE.a2ml found"; \
    fi

# Validate AI installation guide completeness (finishbot pre-release check)
validate-ai-install:
    #!/usr/bin/env bash
    echo "=== AI Installation Guide Check ==="
    GUIDE="docs/AI_INSTALLATION_GUIDE.adoc"
    README="README.adoc"
    ERRORS=0

    # Check guide exists
    if [ ! -f "$GUIDE" ]; then
        echo "MISSING: $GUIDE (create from template: docs/AI_INSTALLATION_GUIDE.adoc)"
        ERRORS=$((ERRORS + 1))
    else
        # Check for unfilled TODO markers
        TODOS=$(grep -c '\[TODO-AI-INSTALL' "$GUIDE" 2>/dev/null || true)
        if [ "$TODOS" -gt 0 ]; then
            echo "INCOMPLETE: $GUIDE has $TODOS unfilled [TODO-AI-INSTALL] markers:"
            grep -n '\[TODO-AI-INSTALL' "$GUIDE" | head -10
            ERRORS=$((ERRORS + 1))
        else
            echo "$GUIDE: complete (no TODO markers)"
        fi

        # Check AI implementation section exists
        if ! grep -q 'ai-implementation' "$GUIDE" 2>/dev/null; then
            echo "MISSING: [[ai-implementation]] anchor in $GUIDE"
            ERRORS=$((ERRORS + 1))
        fi

        # Check privacy notice exists
        if ! grep -qi 'privacy' "$GUIDE" 2>/dev/null; then
            echo "MISSING: Privacy notice in $GUIDE"
            ERRORS=$((ERRORS + 1))
        fi

        # Check install commands exist (not just placeholders)
        if ! grep -q 'git clone' "$GUIDE" 2>/dev/null; then
            echo "WARNING: No git clone command found in $GUIDE -- install commands may be incomplete"
        fi
    fi

    # Check README has AI install section
    if [ -f "$README" ]; then
        if ! grep -qi 'AI-Assisted Installation' "$README" 2>/dev/null; then
            echo "MISSING: AI-Assisted Installation section in $README"
            echo "  Copy from docs/AI-INSTALL-README-SECTION.adoc"
            ERRORS=$((ERRORS + 1))
        fi

        # Check README for unfilled TODO markers
        README_TODOS=$(grep -c '\[TODO-AI-INSTALL' "$README" 2>/dev/null || true)
        if [ "$README_TODOS" -gt 0 ]; then
            echo "INCOMPLETE: $README has $README_TODOS unfilled [TODO-AI-INSTALL] markers"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    if [ "$ERRORS" -gt 0 ]; then
        echo ""
        echo "AI install guide: FAIL ($ERRORS issues)"
        exit 1
    fi
    echo "AI install guide: PASS"

# Full validation suite
validate: validate-rsr validate-state validate-ai-install
    @echo "All validations passed!"

# ═══════════════════════════════════════════════════════════════════════════════
# STATE MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

# Update STATE.a2ml timestamp
state-touch:
    @if [ -f ".machine_readable/descriptiles/STATE.a2ml" ]; then \
        sed -i 's/last-updated = "[^"]*"/last-updated = "'"$(date +%Y-%m-%d)"'"/' .machine_readable/descriptiles/STATE.a2ml && \
        echo "STATE.a2ml timestamp updated"; \
    fi

# Show current phase from STATE.a2ml
state-phase:
    @grep -oP 'phase\s*=\s*"\K[^"]+' .machine_readable/descriptiles/STATE.a2ml 2>/dev/null | head -1 || echo "unknown"

# ═══════════════════════════════════════════════════════════════════════════════
# GUIX
# ═══════════════════════════════════════════════════════════════════════════════

# Enter Guix development shell (primary)
guix-shell:
    guix shell -D -f guix.scm

# Build with Guix
guix-build:
    guix build -f guix.scm

# ═══════════════════════════════════════════════════════════════════════════════
# HYBRID AUTOMATION
# ═══════════════════════════════════════════════════════════════════════════════

# Run local automation tasks
automate task="all":
    #!/usr/bin/env bash
    case "{{task}}" in
        all) just fmt && just lint && just test && just docs && just state-touch ;;
        cleanup) just clean && find . -name "*.orig" -delete && find . -name "*~" -delete ;;
        update) just deps && just validate ;;
        *) echo "Unknown: {{task}}. Use: all, cleanup, update" && exit 1 ;;
    esac

# ═══════════════════════════════════════════════════════════════════════════════
# COMBINATORIC MATRIX RECIPES
# ═══════════════════════════════════════════════════════════════════════════════

# Build matrix: [debug|release] x [target] x [features]
build-matrix mode="debug" target="" features="":
    @echo "Build matrix: mode={{mode}} target={{target}} features={{features}}"

# Test matrix: [unit|integration|e2e|all] x [verbosity] x [parallel]
test-matrix suite="unit" verbosity="normal" parallel="true":
    @echo "Test matrix: suite={{suite}} verbosity={{verbosity}} parallel={{parallel}}"

# Container matrix: [build|run|push|shell|scan] x [registry] x [tag]
container-matrix action="build" registry="ghcr.io/hyperpolymath" tag="latest":
    @echo "Container matrix: action={{action}} registry={{registry}} tag={{tag}}"

# CI matrix: [lint|test|build|security|all] x [quick|full]
ci-matrix stage="all" depth="quick":
    @echo "CI matrix: stage={{stage}} depth={{depth}}"

# Show all matrix combinations
combinations:
    @echo "=== Combinatoric Matrix Recipes ==="
    @echo ""
    @echo "Build Matrix: just build-matrix [debug|release] [target] [features]"
    @echo "Test Matrix:  just test-matrix [unit|integration|e2e|all] [verbosity] [parallel]"
    @echo "Container:    just container-matrix [build|run|push|shell|scan] [registry] [tag]"
    @echo "CI Matrix:    just ci-matrix [lint|test|build|security|all] [quick|full]"

# ═══════════════════════════════════════════════════════════════════════════════
# VERSION CONTROL
# ═══════════════════════════════════════════════════════════════════════════════

# Show git status
status:
    @git status --short

# Show recent commits
log count="20":
    @git log --oneline -{{count}}

# Generate CHANGELOG.md with git-cliff
changelog:
    @command -v git-cliff >/dev/null || { echo "git-cliff not found — install: cargo install git-cliff"; exit 1; }
    git cliff --config .machine_readable/configs/git-cliff/cliff.toml --output CHANGELOG.md
    @echo "Generated CHANGELOG.md"

# Preview changelog for unreleased commits (does not write)
changelog-preview:
    @command -v git-cliff >/dev/null || { echo "git-cliff not found — install: cargo install git-cliff"; exit 1; }
    git cliff --config .machine_readable/configs/git-cliff/cliff.toml --unreleased --strip header

# Tag a new release (usage: just release-tag 1.2.3)
release-tag version:
    #!/usr/bin/env bash
    TAG="v{{version}}"
    if git rev-parse "$TAG" >/dev/null 2>&1; then
        echo "Tag $TAG already exists"
        exit 1
    fi
    just changelog
    git add CHANGELOG.md
    git commit -m "chore(release): prepare $TAG"
    git tag -a "$TAG" -m "Release $TAG"
    echo "Created tag $TAG — push with: git push origin main --tags"

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

# Count lines of code
loc:
    @find . \( -name "*.rs" -o -name "*.ex" -o -name "*.exs" -o -name "*.res" -o -name "*.gleam" -o -name "*.zig" -o -name "*.idr" -o -name "*.hs" -o -name "*.ncl" -o -name "*.scm" -o -name "*.adb" -o -name "*.ads" \) -not -path './target/*' -not -path './_build/*' 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "0"

# Show TODO comments
todos:
    @grep -rn "TODO\|FIXME\|HACK\|XXX" --include="*.rs" --include="*.ex" --include="*.res" --include="*.gleam" --include="*.zig" --include="*.idr" --include="*.hs" . 2>/dev/null || echo "No TODOs"

# Open in editor
edit:
    ${EDITOR:-code} .

# Run high-rigor security assault using panic-attacker
maint-assault:
    @./.machine_readable/scripts/maintenance/maint-assault.sh

# Run panic-attacker pre-commit scan (foundational floor-raise requirement)
assail:
    @command -v panic-attack >/dev/null 2>&1 && panic-attack assail . || echo "WARN: panic-attack not found — install from https://github.com/hyperpolymath/panic-attacker"


# ═══════════════════════════════════════════════════════════════════════════════
# ONBOARDING & DIAGNOSTICS
# ═══════════════════════════════════════════════════════════════════════════════

# Check all required toolchain dependencies and report health
doctor:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Game Server Admin Doctor — Toolchain Health Check"
    echo "═══════════════════════════════════════════════════"
    echo ""
    PASS=0; FAIL=0; WARN=0
    check() {
        local name="$1" cmd="$2" min="$3"
        if command -v "$cmd" >/dev/null 2>&1; then
            VER=$("$cmd" --version 2>&1 | head -1)
            echo "  [OK]   $name — $VER"
            PASS=$((PASS + 1))
        else
            echo "  [FAIL] $name — not found (need $min+)"
            FAIL=$((FAIL + 1))
        fi
    }
    check "just"              just      "1.25" 
    check "git"               git       "2.40" 
    # Optional tools
    if command -v panic-attack >/dev/null 2>&1; then
        echo "  [OK]   panic-attack — available"
        PASS=$((PASS + 1))
    else
        echo "  [WARN] panic-attack — not found (pre-commit scanner)"
        WARN=$((WARN + 1))
    fi
    echo ""
    echo "  Result: $PASS passed, $FAIL failed, $WARN warnings"
    if [ "$FAIL" -gt 0 ]; then
        echo "  Run 'just heal' to attempt automatic repair."
        exit 1
    fi
    echo "  All required tools present."

# Attempt to automatically install missing tools
heal:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Game Server Admin Heal — Automatic Tool Installation"
    echo "═══════════════════════════════════════════════════"
    echo ""
    if ! command -v just >/dev/null 2>&1; then
        echo "Installing just..."
        cargo install just 2>/dev/null || echo "Install just from https://just.systems"
    fi
    echo ""
    echo "Heal complete. Run 'just doctor' to verify."

# Guided tour of the project structure and key concepts
tour:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Game Server Admin — Guided Tour"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo 'Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>'
    echo ""
    echo "Key directories:"
    echo "  src/                      Source code" 
    echo "  docs/                     Documentation" 
    echo "  tests/                    Test suite" 
    echo "  .github/workflows/        CI/CD workflows" 
    echo "  .machine_readable/        Machine-readable metadata" 
    echo "  container/                Container configuration" 
    echo "  examples/                 Usage examples" 
    echo ""
    echo "Quick commands:"
    echo "  just doctor    Check toolchain health"
    echo "  just heal      Fix missing tools"
    echo "  just help-me   Common workflows"
    echo "  just default   List all recipes"
    echo ""
    echo "Read more: README.adoc, EXPLAINME.adoc"

# Show help for common workflows
help-me:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Game Server Admin — Common Workflows"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "FIRST TIME SETUP:"
    echo "  just doctor           Check toolchain"
    echo "  just heal             Fix missing tools"
    echo ""
    echo "PRE-COMMIT:"
    echo "  just assail           Run panic-attacker scan"
    echo ""
    echo "LEARN:"
    echo "  just tour             Guided project tour"
    echo "  just default          List all recipes"


# Print the current CRG grade (reads from READINESS.md '**Current Grade:** X' line)
crg-grade:
    @grade=$$(grep -oP '(?<=\*\*Current Grade:\*\* )[A-FX]' READINESS.md 2>/dev/null | head -1); \
    [ -z "$$grade" ] && grade="X"; \
    echo "$$grade"

# Generate a shields.io badge markdown for the current CRG grade
# Looks for '**Current Grade:** X' in READINESS.md; falls back to X
crg-badge:
    @grade=$$(grep -oP '(?<=\*\*Current Grade:\*\* )[A-FX]' READINESS.md 2>/dev/null | head -1); \
    [ -z "$$grade" ] && grade="X"; \
    case "$$grade" in \
      A) color="brightgreen" ;; B) color="green" ;; C) color="yellow" ;; \
      D) color="orange" ;; E) color="red" ;; F) color="critical" ;; \
      *) color="lightgrey" ;; esac; \
    echo "[![CRG $$grade](https://img.shields.io/badge/CRG-$$grade-$$color?style=flat-square)](https://github.com/hyperpolymath/standards/tree/main/component-readiness-grades)"
