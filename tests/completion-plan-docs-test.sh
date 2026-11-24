#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# From the repository root: bash tests/completion-plan-docs-test.sh
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
plan='docs/ULTRAPLAN-GSA-COMPLETION-2026-11-23.adoc'

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# Keep the link navigable without requiring the current label or line wrapping.
roadmap=$(<"$repo_root/ROADMAP.adoc")
link_label='\[[[:blank:]]*[^][:space:]][^]]*\]'
if [[ ! $roadmap =~ (^|[[:space:]])link:"$plan"$link_label ]]; then
    fail "ROADMAP.adoc needs a labeled link to $plan"
fi

# A matching link alone would still pass if the plan were removed or replaced
# by an empty placeholder.
[[ -f "$repo_root/$plan" && -s "$repo_root/$plan" ]] || fail "Missing or empty plan: $plan"
grep -Eq '^=[[:blank:]]+[^[:space:]]' "$repo_root/$plan" || fail "Missing AsciiDoc document title: $plan"

printf 'PASS: ROADMAP.adoc links to the titled completion plan\n'
