#!/usr/bin/env bash
# scripts/backend-matrix.sh
#
# Run gh-pr-summarise once per backend against a test PR and print a Markdown
# compatibility table to stdout. Backends that are not installed or not
# configured on this machine are reported as skipped rather than failed.
#
# Usage:
#   bash scripts/backend-matrix.sh
#   bash scripts/backend-matrix.sh --backends claude,openrouter
#   bash scripts/backend-matrix.sh --test-pr https://github.com/owner/repo/pull/N
#   bash scripts/backend-matrix.sh --max-diff-chars 500
#
# Requires: gh (authenticated) plus whichever backends you want to exercise.
# Results are printed to stdout so you can redirect to a file:
#   bash scripts/backend-matrix.sh > docs/backend-compatibility.md
#
# Nothing is applied to the PR: each run answers "n" at the confirmation prompt.

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/gh-pr-summarise"
TEST_PR="https://github.com/xpepper/gh-pr-summarise/pull/1"
MAX_DIFF_CHARS="28000"
BACKENDS="claude copilot openrouter openai pi omp agy opencode llm apfel"

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backends)       BACKENDS="${2//,/ }";  shift 2 ;;
    --test-pr)        TEST_PR="$2";          shift 2 ;;
    --max-diff-chars) MAX_DIFF_CHARS="$2";   shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ────────────────────────────────────────────────────────────────────

# Classifies one gh-pr-summarise run into a status and a note.
# Sets RESULT_STATUS and RESULT_NOTE.
_analyze_output() {
  local output="$1"
  RESULT_STATUS="❌ error"
  RESULT_NOTE=""

  # A backend that was never usable is skipped, not broken: saying "failed"
  # for a CLI that simply is not installed would be misleading.
  if [[ "$output" == *"no usable backend"* ]]; then
    RESULT_STATUS="⏭️ unavailable"
    RESULT_NOTE="not installed, or its API key is unset"
  elif [[ "$output" == *"Generated description"* || "$output" == *"description updated"* ]]; then
    RESULT_STATUS="✅"
  elif [[ "$output" == *"was truncated"* ]]; then
    RESULT_STATUS="❌ truncated"
    RESULT_NOTE="output budget too small for this model"
  elif [[ "$output" == *"no backend could generate"* ]]; then
    RESULT_STATUS="❌ no output"
    RESULT_NOTE="backend ran but returned nothing — check its auth"
  fi
}

classify() { _analyze_output "$1"; echo "$RESULT_STATUS"; }
notes()    { _analyze_output "$1"; echo "$RESULT_NOTE"; }

# ── Main ───────────────────────────────────────────────────────────────────────

echo "Testing against: $TEST_PR (--max-diff-chars $MAX_DIFF_CHARS)"
echo "Date: $(date +%Y-%m-%d)"
echo ""
echo "| Backend | Result | Time | Notes |"
echo "|---------|--------|------|-------|"

for backend in $BACKENDS; do
  started=$SECONDS
  output=$(echo "n" | bash "$SCRIPT" \
    --backend "$backend" \
    --force \
    --max-diff-chars "$MAX_DIFF_CHARS" \
    "$TEST_PR" 2>&1) || true
  elapsed=$(( SECONDS - started ))

  status=$(classify "$output")
  note=$(notes "$output")

  # Elapsed time is noise for a backend that never ran.
  [[ "$status" == "⏭️ unavailable" ]] && elapsed="—" || elapsed="${elapsed}s"

  echo "| \`$backend\` | $status | $elapsed | $note |"
done
