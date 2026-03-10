# Model Error Handling & Fallbacks Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Improve UX when GitHub Models returns token-limit or rate-limit errors, by showing
actionable messages and transparently retrying with fallback models.

**Architecture:** Three independent improvements to `gh-pr-summarise` (single bash script):
(1) parse and surface `tokens_limit_reached` errors with actionable hints;
(2) auto-retry on `rate_limit_exceeded` through a configurable fallback model chain;
(3) minor ergonomic polish (JSON output flag, progress hint on fallback).

**Tech Stack:** Bash, bats (tests), jq (JSON parsing), shellcheck (lint)

---

## Background & Research Notes

### Token limit errors
When a model's input limit is exceeded the API returns a JSON body like:
```json
{"error":{"code":"tokens_limit_reached","message":"Request body too large for gpt-5 model. Max size: 4000 tokens."}}
```
The current script dumps the raw JSON and exits. Users have no hint on what to do.

### Rate limit errors
Free-tier GitHub Models caps: ~150 req/day for gpt-4o-mini, ~50/day for gpt-4o,
~10/day for gpt-4.1. Exceeding returns HTTP 429 or error code `rate_limit_exceeded`.

### Good fallback chain (free tier, code quality)
1. `openai/gpt-4.1` — default, best quality
2. `openai/gpt-4o` — strong, 50/day free
3. `openai/gpt-4o-mini` — fast, 150/day free, sufficient for most PRs

### Key script section (lines 181–187 of `gh-pr-summarise`)
```bash
SUMMARY=$(echo "$RESPONSE" | jq -r '.choices[0].message.content' 2>/dev/null) || SUMMARY=""

if [[ -z "$SUMMARY" || "$SUMMARY" == "null" ]]; then
  echo "Error: no summary returned by GitHub Models. Raw response:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi
```
All three tasks modify this section (and the curl call above it).

---

## Task 1: Actionable error message for `tokens_limit_reached`

**Files:**
- Modify: `gh-pr-summarise` (around line 181)
- Test: `tests/gh-pr-summarise.bats`

**Context:** Currently both `tokens_limit_reached` and any other API error fall through to the
same generic "no summary returned" message. We want to detect this specific error code and
show a helpful hint.

### Step 1: Write the failing test

Add to `tests/gh-pr-summarise.bats` — place it near other API-error tests:

```bash
@test "shows actionable hint when model returns tokens_limit_reached" {
  # Arrange: mock curl to return a tokens_limit_reached error
  mock_curl() {
    echo '{"error":{"code":"tokens_limit_reached","message":"Request body too large for deepseek-v3-0324 model. Max size: 4000 tokens."}}'
  }
  export -f mock_curl
  # Bats PATH trick: write a curl stub to a temp bin dir
  local bin_dir
  bin_dir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nmock_curl "$@"\n' > "$bin_dir/curl"
  chmod +x "$bin_dir/curl"

  run env PATH="$bin_dir:$PATH" bash gh-pr-summarise 123
  [ "$status" -ne 0 ]
  [[ "$output" == *"tokens_limit_reached"* ]] || [[ "$output" == *"too large"* ]]
  [[ "$output" == *"--max-diff-chars"* ]]
}
```

> **Note on bats mocking:** The existing tests use a shared `setup()` that stubs `gh` and
> `curl`. Read the top of `tests/gh-pr-summarise.bats` to understand the existing stub pattern
> before adding this test — adapt the new test to use the same approach.

### Step 2: Run the test to verify it fails

```bash
bats tests/gh-pr-summarise.bats --filter "tokens_limit_reached"
```
Expected: FAILED — the current code prints the raw JSON, not the hint.

### Step 3: Implement the fix in `gh-pr-summarise`

Replace the error block (around lines 181–187):

```bash
SUMMARY=$(echo "$RESPONSE" | jq -r '.choices[0].message.content' 2>/dev/null) || SUMMARY=""

if [[ -z "$SUMMARY" || "$SUMMARY" == "null" ]]; then
  ERROR_CODE=$(echo "$RESPONSE" | jq -r '.error.code // ""' 2>/dev/null)
  if [[ "$ERROR_CODE" == "tokens_limit_reached" ]]; then
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // ""' 2>/dev/null)
    echo "Error: $ERROR_MSG" >&2
    echo "Hint: reduce the diff size with --max-diff-chars (current: $MAX_DIFF_CHARS)" >&2
    echo "      or switch to a model with a larger context window (e.g. --model openai/gpt-4.1)" >&2
  else
    echo "Error: no summary returned by GitHub Models. Raw response:" >&2
    echo "$RESPONSE" >&2
  fi
  exit 1
fi
```

### Step 4: Run the test to verify it passes

```bash
bats tests/gh-pr-summarise.bats --filter "tokens_limit_reached"
```
Expected: PASS

### Step 5: Run the full test suite

```bash
make test
```
Expected: all previously passing tests still pass.

### Step 6: Commit

```bash
git add gh-pr-summarise tests/gh-pr-summarise.bats
git commit -m "feat(errors): show actionable hint for tokens_limit_reached errors"
```

---

## Task 2: Automatic fallback on `rate_limit_exceeded`

**Files:**
- Modify: `gh-pr-summarise` (defaults section + API call section)
- Test: `tests/gh-pr-summarise.bats`

**Context:** When the chosen model hits its daily free-tier request cap, the API returns
an error with code `rate_limit_exceeded`. Instead of failing, the script should silently
retry with the next model in a fallback chain, notifying the user.

### Step 1: Write the failing test

```bash
@test "automatically falls back to next model on rate_limit_exceeded" {
  # First curl call returns rate_limit_exceeded; second succeeds
  local call_count=0
  mock_curl() {
    call_count=$((call_count + 1))
    if [[ $call_count -eq 1 ]]; then
      echo '{"error":{"code":"rate_limit_exceeded","message":"Rate limit reached for openai/gpt-4.1"}}'
    else
      echo '{"choices":[{"message":{"content":"summary from fallback model"}}]}'
    fi
  }
  export -f mock_curl
  # ... (same bin_dir stub pattern as Task 1)

  run env PATH="$bin_dir:$PATH" bash gh-pr-summarise 123
  [ "$status" -eq 0 ]
  [[ "$output" == *"rate limit"* ]] || [[ "$output" == *"fallback"* ]] || [[ "$output" == *"retrying"* ]]
  [[ "$output" == *"summary from fallback model"* ]]
}
```

> Again, read the existing stub pattern in `tests/gh-pr-summarise.bats` and adapt accordingly.

### Step 2: Run the test to verify it fails

```bash
bats tests/gh-pr-summarise.bats --filter "fallback"
```
Expected: FAILED.

### Step 3: Implement the fallback chain

**3a. Add fallback defaults near the top of the script** (after the existing `MODEL=` line):

```bash
# Comma-separated fallback chain used when the primary model hits rate limits.
# Override with PR_SUMMARISE_FALLBACK_MODELS env var; set to "" to disable.
FALLBACK_MODELS="${PR_SUMMARISE_FALLBACK_MODELS:-openai/gpt-4o,openai/gpt-4o-mini}"
```

**3b. Extract the API call into a helper function** (replace the existing curl block):

```bash
# ── Call GitHub Models (with fallback on rate limit) ─────────────────────────
call_model() {
  local model="$1"
  curl -sS -L "$ENDPOINT" \
    -H "Authorization: Bearer $(gh auth token)" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg model  "$model" \
      --arg prompt "$PROMPT_TEXT" \
      --arg diff   "$DIFF" \
      '{
        model: $model,
        temperature: 0.2,
        max_tokens: 500,
        messages: [{
          role: "user",
          content: "\($prompt)\n\n\($diff)"
        }]
      }')"
}

echo "Generating summary via GitHub Models ($MODEL)..."
RESPONSE=$(call_model "$MODEL")
ERROR_CODE=$(echo "$RESPONSE" | jq -r '.error.code // ""' 2>/dev/null)

if [[ "$ERROR_CODE" == "rate_limit_exceeded" && -n "$FALLBACK_MODELS" ]]; then
  IFS=',' read -ra FALLBACKS <<< "$FALLBACK_MODELS"
  for fallback in "${FALLBACKS[@]}"; do
    echo "Rate limit reached for $MODEL. Retrying with $fallback..." >&2
    MODEL="$fallback"
    RESPONSE=$(call_model "$MODEL")
    ERROR_CODE=$(echo "$RESPONSE" | jq -r '.error.code // ""' 2>/dev/null)
    [[ "$ERROR_CODE" != "rate_limit_exceeded" ]] && break
  done
fi
```

**3c. Remove the old `echo "Generating summary..."` + curl block** — it is replaced above.

### Step 4: Run the test to verify it passes

```bash
bats tests/gh-pr-summarise.bats --filter "fallback"
```
Expected: PASS

### Step 5: Run the full test suite

```bash
make test
```
Expected: all tests pass.

### Step 6: Document the new env var in usage()

Add to the `usage()` function's "Environment variables" section:

```
  PR_SUMMARISE_FALLBACK_MODELS  Comma-separated fallback model chain used when the
                                primary model hits rate limits.
                                Default: openai/gpt-4o,openai/gpt-4o-mini
                                Set to "" to disable automatic fallback.
```

Also add it to the README under the Configuration / Environment variables section.

### Step 7: Commit

```bash
git add gh-pr-summarise README.md tests/gh-pr-summarise.bats
git commit -m "feat(fallback): auto-retry with fallback models on rate_limit_exceeded"
```

---

## Task 3: Ergonomic polish

**Files:**
- Modify: `gh-pr-summarise`
- Modify: `README.md`

**Context:** Small UX improvements inspired by research into CLI ergonomics: (a) expose
fallback model chain in help output; (b) surface the active model name in the final
confirmation banner so users know which model was actually used when a fallback kicked in.

### Step 1: Show the active model in the output banner

In the "Review and confirm" section (around line 198), change:

```bash
echo "──── Generated description ────────────────────────────────────────────────"
```

to include the model that actually produced the output:

```bash
echo "──── Generated description ($MODEL) ──────────────────────────────────────"
```

This is especially useful when a fallback model was used.

### Step 2: Run the test suite to confirm no regressions

```bash
make test
```

### Step 3: Update README Options table

Add a row for the new env var:

| `PR_SUMMARISE_FALLBACK_MODELS` | — | `openai/gpt-4o,openai/gpt-4o-mini` | Comma-separated fallback chain when rate limit is hit. Set to `""` to disable. |

(Add this to the existing Configuration / Environment variables section.)

### Step 4: Commit

```bash
git add gh-pr-summarise README.md
git commit -m "feat(ux): show active model in output banner"
```

---

## Task 4: Manual model compatibility matrix (exploratory)

**Not a code task** — exploratory manual testing against the live API using the permanent test PR.

**Goal:** Understand which models from `gh models list` work well with the default settings,
which ones hit token limits, and whether the `--max-diff-chars` option behaves as expected
across models.

**Test PR:** https://github.com/xpepper/gh-pr-summarise/pull/1 (small safe diff, purpose-built for testing)

### Step 1: Get the full model list

```bash
gh models list
```

### Step 2: Run the tool against each model

For every model ID returned above, run:

```bash
# Default --max-diff-chars (28000 chars)
echo "n" | gh pr-summarise https://github.com/xpepper/gh-pr-summarise/pull/1 --model <MODEL_ID>

# Explicit small limit — verify the model respects it
echo "n" | gh pr-summarise https://github.com/xpepper/gh-pr-summarise/pull/1 --model <MODEL_ID> --max-diff-chars 500
```

Record for each model:
- ✅ Success with default `--max-diff-chars`
- ⚠️ Hits token limit with default (how many chars does it accept?)
- ❌ Fails even with small diff
- ℹ️ Rate limited (free tier exhausted)

### Step 3: Document findings

Create `docs/model-compatibility.md` with a table:

| Model | Default (28k chars) | Small (500 chars) | Notes |
|-------|--------------------|--------------------|-------|
| openai/gpt-4.1 | ✅ | ✅ | |
| ... | | | |

### What to look for

1. **Token limit compatibility**: does the default `--max-diff-chars 28000` work, or does the model
   reject it with `tokens_limit_reached`? If so, what's the practical safe limit for that model?
2. **Option mapping**: does `--max-diff-chars` correctly truncate the diff sent to the API
   (the model should never see more chars than specified)?
3. **Response quality**: does the model produce a meaningful PR description, or gibberish?

This informs future work: updating the default `--max-diff-chars`, adding per-model presets,
and choosing the best fallback chain order (Task 2).

---

## Testing Checklist

After all three code tasks are done, do a manual smoke-test:

```bash
# Verify token-limit error message is helpful
# (mock or use a model known to reject large diffs)

# Verify fallback kicks in by temporarily setting an exhausted/invalid primary:
PR_SUMMARISE_MODEL=openai/gpt-4.1 \
PR_SUMMARISE_FALLBACK_MODELS=openai/gpt-4o-mini \
  gh pr-summarise <PR_NUMBER>

# Verify fallback can be disabled:
PR_SUMMARISE_FALLBACK_MODELS="" gh pr-summarise <PR_NUMBER>
```

---

## Out of Scope (deferred)

- `--json` output flag (low priority, no user request yet)
- Progress spinner/dots during API call (nice to have, adds complexity)
- Per-model `--max-diff-chars` auto-tuning based on known token limits
