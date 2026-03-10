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

classify() {
  local output="$1"

  if echo "$output" | grep -qE "description updated|Generated description|Aborted"; then
    echo "✅"
    return
  fi

  if echo "$output" | grep -qE "Retrying with"; then
    local fallback
    fallback=$(echo "$output" | grep -oE "Retrying with [^..]+" | head -1 | sed 's/Retrying with //')
    echo "✅ (via fallback: $fallback)"
    return
  fi

  if echo "$output" | grep -qE "tokens_limit_reached|too large|Max size|max_tokens|max_completion_tokens"; then
    echo "❌ token/param error"
    return
  fi

  if echo "$output" | grep -qE "rate limit reached for all|Too many requests|rate_limit_exceeded"; then
    echo "ℹ️ rate limited"
    return
  fi

  if echo "$output" | grep -qE "context deadline|timed out|timeout"; then
    echo "❌ timeout"
    return
  fi

  if echo "$output" | grep -qE "unknown_model|Unknown model"; then
    echo "❌ unknown model"
    return
  fi

  if echo "$output" | grep -qE "api version|api versions"; then
    echo "❌ API version"
    return
  fi

  if echo "$output" | grep -qE "BadRequest"; then
    echo "❌ bad request"
    return
  fi

  if echo "$output" | grep -qE "no summary returned"; then
    echo "❌ no summary"
    return
  fi

  echo "❌ error"
}

notes() {
  local output="$1"

  # Surface the most useful single line from the output
  if echo "$output" | grep -qE "tokens_limit_reached|too large|Max size"; then
    echo "$output" | grep -oE "Max size: [0-9]+ tokens" | head -1
    return
  fi

  if echo "$output" | grep -qE "max_tokens|max_completion_tokens"; then
    echo "use max_completion_tokens instead"
    return
  fi

  if echo "$output" | grep -qE "api version|api versions"; then
    echo "$output" | grep -oE "api versions? [^\"]+" | head -1 | cut -c1-60
    return
  fi

  if echo "$output" | grep -qE "unknown_model|Unknown model"; then
    echo "not available via inference endpoint"
    return
  fi

  if echo "$output" | grep -qE "context deadline|timed out"; then
    echo "model too slow on free tier"
    return
  fi

  if echo "$output" | grep -qE "no summary returned"; then
    # Try to extract the error code from the raw JSON
    echo "$output" | grep -oE '"code":"[^"]+"' | head -1 | tr -d '"code:' | head -c 60
    return
  fi
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
