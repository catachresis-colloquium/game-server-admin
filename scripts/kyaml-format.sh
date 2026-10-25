#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# kyaml-format.sh — format arbitrary YAML as KYAML, or check that it already is
# (YAML-POLICY Y-3; KYAML adoption step 3, standards#1022).
#
# The rewriter is `yq -p yaml -o kyaml '.'`, verbatim — the one rewriter the
# step-2 comment-preservation proof (tools/yaml-comment-proof, standards#1021)
# covers. That proof does not generalise to any other rewriter, so this script
# deliberately adds none: no post-processing, no re-indenting, no sed.
#
# Usage:
#   kyaml-format.sh [--check] FILE...
#
#   (default)  rewrite each FILE in place as KYAML when it is not already.
#   --check    rewrite nothing; exit 1 if any FILE is not already KYAML.
#
# Exit contract:
#   0 = every FILE is KYAML (after the rewrite, in format mode)
#   1 = --check: at least one FILE is not KYAML (each one is named)
#   2 = refused: no FILE given, a FILE is missing or unparseable, a FILE has no
#       final newline, or the rewrite would change the parsed data. A refusal
#       never rewrites that FILE and never counts as clean.
#
# Why the final-newline refusal: a `|` block scalar that ends at EOF with no
# line break is read differently by go-yaml (yq) and eemeli/yaml — measured on
# k9-contractile.yml, the trailing "\n" of its last run: body exists for one
# parser and not the other. Formatting such a file would silently pick one
# reading, so the script refuses it and names the fix instead.
set -uo pipefail

MODE=format
if [ "${1:-}" = "--check" ]; then
  MODE=check
  shift
fi

if [ "$#" -eq 0 ]; then
  echo "kyaml-format: no files given (usage: kyaml-format.sh [--check] FILE...)" >&2
  exit 2
fi

command -v yq >/dev/null 2>&1 || { echo "kyaml-format: yq is not on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# canonical_data <file> — prints the file's parsed value as key-sorted JSON;
# fails when the file does not parse.
canonical_data() {
  yq -p yaml -o json -I 0 'sort_keys(..)' "$1"
}

# kyaml_of <file> <out> — writes the KYAML rendering of <file> to <out>;
# fails when <file> does not parse.
kyaml_of() {
  yq -p yaml -o kyaml '.' "$1" > "$2"
}

# refuse <file> <reason> — reports a file this script will not judge.
refuse() {
  echo "::error file=$1::kyaml-format: REFUSED $1 — $2" >&2
  refused=$((refused + 1))
}

refused=0 drift=0 clean=0 rewritten=0
i=0
for f in "$@"; do
  i=$((i + 1))
  out="$TMP/$i.kyaml"
  if [ ! -f "$f" ]; then
    refuse "$f" "no such file"; continue
  fi
  if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then
    refuse "$f" "no final newline; add one first (a trailing block scalar is ambiguous without it)"; continue
  fi
  if ! kyaml_of "$f" "$out" 2>"$TMP/err"; then
    refuse "$f" "does not parse: $(head -1 "$TMP/err")"; continue
  fi
  if cmp -s "$f" "$out"; then
    clean=$((clean + 1)); continue
  fi
  # The rewrite is only acceptable when it preserves the data exactly.
  if ! before=$(canonical_data "$f") || ! after=$(canonical_data "$out") || [ "$before" != "$after" ]; then
    refuse "$f" "the KYAML rendering does not parse to the same data"; continue
  fi
  if [ "$MODE" = check ]; then
    echo "::error file=$f::kyaml-format: $f is not KYAML — run scripts/kyaml-format.sh $f" >&2
    drift=$((drift + 1))
  else
    cat "$out" > "$f"
    echo "kyaml-format: rewrote $f"
    rewritten=$((rewritten + 1))
  fi
done

total=$#
if [ "$refused" -gt 0 ]; then
  echo "kyaml-format: $refused of $total file(s) REFUSED — not judged, not clean" >&2
  exit 2
fi
if [ "$drift" -gt 0 ]; then
  echo "kyaml-format: $drift of $total file(s) are not KYAML" >&2
  exit 1
fi
if [ "$MODE" = check ]; then
  echo "kyaml-format: all $total file(s) are KYAML"
else
  echo "kyaml-format: $total file(s) KYAML ($rewritten rewritten, $clean already clean)"
fi
exit 0
