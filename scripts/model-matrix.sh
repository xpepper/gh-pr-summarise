#!/usr/bin/env bash
# scripts/model-matrix.sh
#
# Run gh-pr-summarise against every model returned by `gh models list` and
# print a Markdown compatibility table to stdout.
#
# Usage:
#   bash scripts/model-matrix.sh
#   bash scripts/model-matrix.sh --test-pr https://github.com/owner/repo/pull/N
#   bash scripts/model-matrix.sh --max-diff-chars 500
#
# Requires: gh (authenticated), curl, jq — same as the main script.
# Results are printed to stdout so you can redirect to a file:
#   bash scripts/model-matrix.sh > /tmp/matrix.md

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/gh-pr-summarise"
TEST_PR="https://github.com/xpepper/gh-pr-summarise/pull/1"
MAX_DIFF_CHARS="28000"

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-pr)      TEST_PR="$2";        shift 2 ;;
    --max-diff-chars) MAX_DIFF_CHARS="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ────────────────────────────────────────────────────────────────────

# Internal helper to analyze gh-pr-summarise output and set global variables.
_analyze_output() {
  local output="$1"
  RESULT_STATUS="❌ error"
  RESULT_NOTE=""

  # Priority 1: Success markers
  if [[ "$output" =~ (description\ updated|Generated\ description|Aborted) ]]; then
    RESULT_STATUS="✅"
  # Priority 2: Failures with specific notes (highest priority for errors)
  elif [[ "$output" =~ Max\ size:\ ([0-9]+)\ tokens ]]; then
    RESULT_STATUS="❌ token/param error"
    RESULT_NOTE="Max size: ${BASH_REMATCH[1]} tokens"
  elif [[ "$output" =~ (tokens_limit_reached|too\ large) ]]; then
    RESULT_STATUS="❌ token/param error"
  elif [[ "$output" =~ (max_tokens|max_completion_tokens) ]]; then
    RESULT_STATUS="❌ token/param error"
    RESULT_NOTE="use max_completion_tokens instead"
  elif [[ "$output" =~ (api\ versions?\ [^\"]+) ]]; then
    RESULT_STATUS="❌ API version"
    RESULT_NOTE="${BASH_REMATCH[1]:0:60}"
  elif [[ "$output" =~ (unknown_model|Unknown\ model) ]]; then
    RESULT_STATUS="❌ unknown model"
    RESULT_NOTE="not available via inference endpoint"
  elif [[ "$output" =~ (context\ deadline|timed\ out) ]]; then
    RESULT_STATUS="❌ timeout"
    RESULT_NOTE="model too slow on free tier"
  # Priority 3: Retry hints (considered success-ish)
  elif [[ "$output" =~ Retrying\ with\ ([^.]+) ]]; then
    RESULT_STATUS="✅ (via fallback: ${BASH_REMATCH[1]})"
  # Priority 4: Generic errors
  elif [[ "$output" =~ (rate\ limit\ reached\ for\ all|Too\ many\ requests|rate_limit_exceeded) ]]; then
    RESULT_STATUS="ℹ️ rate limited"
  elif [[ "$output" =~ (context\ deadline|timed\ out|timeout) ]]; then
    RESULT_STATUS="❌ timeout"
  elif [[ "$output" =~ (api\ version|api\ versions) ]]; then
    RESULT_STATUS="❌ API version"
  elif [[ "$output" =~ BadRequest ]]; then
    RESULT_STATUS="❌ bad request"
  elif [[ "$output" =~ no\ summary\ returned ]]; then
    RESULT_STATUS="❌ no summary"
    if [[ "$output" =~ \"code\":\"([^\"]+)\" ]]; then
      RESULT_NOTE="${BASH_REMATCH[1]:0:60}"
    fi
  fi
}

classify() {
  _analyze_output "$1"
  echo "$RESULT_STATUS"
}

notes() {
  _analyze_output "$1"
  echo "$RESULT_NOTE"
}

# ── Main ───────────────────────────────────────────────────────────────────────

echo "Testing against: $TEST_PR (--max-diff-chars $MAX_DIFF_CHARS)"
echo "Date: $(date +%Y-%m-%d)"
echo ""
echo "| Model | Result | Notes |"
echo "|-------|--------|-------|"

mapfile -t MODELS < <(gh models list | awk '{print $1}')

for model in "${MODELS[@]}"; do
  output=$(echo "n" | bash "$SCRIPT" \
    --model "$model" \
    --max-diff-chars "$MAX_DIFF_CHARS" \
    "$TEST_PR" 2>&1) || true

  status=$(classify "$output")
  note=$(notes "$output")

  echo "| \`$model\` | $status | $note |"
  sleep 1  # be polite to the API
done
