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

---

## ✅ Task 1: Actionable error message for `tokens_limit_reached` — DONE

**Commits:** `515d832`

**What was implemented:**
- Detect `tokens_limit_reached` in the API response and show the model's actual error message
- Hint: reduce diff with `--max-diff-chars` (showing current value)
- Hint: run `gh models list` to find a larger-context model
- Generic "raw response" fallback preserved for all other error types

**Deviations from plan:**
- Plan's hint suggested `--model openai/gpt-4.1` (the default model — misleading). Changed to
  `run 'gh models list'` instead.
- Test assertion tightened: removed `||` fallback, added assertion on `gh models list` hint line.

---

## ✅ Task 2: Automatic fallback on `rate_limit_exceeded` — DONE

**Commits:** `4e97f6d`, `7475098`, `9a8a1dd`, `2f635d4`

**What was implemented:**
- `FALLBACK_MODELS` variable (default: `openai/gpt-4o,openai/gpt-4o-mini`), overridable via
  `PR_SUMMARISE_FALLBACK_MODELS` env var
- `call_model()` helper function extracted from the inline curl call
- Fallback loop: on `rate_limit_exceeded`, iterates the chain with a stderr notice per attempt,
  stops at first success
- Exhausted chain: if all models are rate-limited, exits with a helpful message referencing
  `PR_SUMMARISE_FALLBACK_MODELS`
- `usage()` and `README.md` updated

**Extra work beyond the plan (found via integration test):**
- GitHub's infrastructure sometimes returns HTML `"Too many requests"` instead of a JSON error.
  This crashed the script (`jq` exiting 5 via `set -euo pipefail`) and bypassed the fallback.
  Fixed by:
  - Adding `|| ERROR_CODE=""` / `|| ERROR_MSG=""` guards on all jq extractions
  - Also triggering the fallback chain on `"Too many requests"` response body
  - New test: `"falls back when API returns HTML Too many requests instead of JSON"`

**Deviations from plan:**
- Plan's test used a counter file (cross-process, unreliable in CI). Changed to sentinel-file
  pattern (`touch` + `-e`), which is CI-safe (documented gotcha in MEMORY.md).
- README env var documented in Configuration section code block, not as an Options table row
  (table is for CLI flags only — adding an env var there would be inconsistent).

---

## ✅ Task 3: Ergonomic polish — DONE

**Commits:** `f12d719`, `57055e8`

**What was implemented:**
- Active model name shown in the output banner:
  `──── Generated description (openai/gpt-4o-mini) ────...`
- Test added asserting the model name appears with a non-default model

**Deviations from plan:**
- Plan listed `PR_SUMMARISE_FALLBACK_MODELS` options table row as part of Task 3 — this was
  already handled in Task 2 (Configuration section, not the flags table).
- Plan mentioned a `--json` output flag; this was out of scope and not implemented.

---

## ✅ Docs & integration test improvements — DONE (beyond original plan)

**Commits:** `33c1ca6`, `56b8393`

- `CLAUDE.md`: new Key Design Decisions for fallback chain and token-limit errors; Definition
  of Done section added (`make test` + `make integration-test`)
- `README.md`: `-n / --max-diff-chars` usage example added; `gpt-4.1-mini` example corrected
  to `gpt-4o-mini`; new Behaviour subsections for rate-limit fallback and token-limit errors
- Integration tests: added idempotency test (marker detected and replaced, not appended twice)
  and tracker URL preservation test

---

## ✅ Task 4: Manual model compatibility matrix (exploratory) — DONE

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
and refining the fallback chain order.

---

---

## ✅ Task 5: Auto-retry for newer OpenAI model API incompatibilities — DONE

**Commits:** `d5ca376`, plus temperature fix

**What was implemented:**

- `call_model` extended with optional `tokens_param` (default `max_tokens`) and
  `include_temperature` (default `true`) arguments, using jq dynamic key syntax.
- `invoke_model` wrapper added that calls `call_model` and retries transparently:
  1. On `unsupported_parameter` / `param: max_tokens` → retries with `max_completion_tokens`
  2. On `unsupported_value` / `param: temperature` → retries without the `temperature` field
- All `call_model` call sites replaced with `invoke_model`.
- 3 new unit tests (retry on `max_tokens` rejection, retry on `temperature` rejection,
  request body contains `max_completion_tokens` on retry).
- Integration test added for `openai/gpt-5` (both fixes verified against live API).

**Discovered during work:**

- `openai/gpt-5-nano` hits both the `max_tokens` and `temperature` issues (both handled),
  but is also a reasoning model that consumes all 500 tokens internally — unreliable in
  integration tests. Integration test for `gpt-5-nano` removed; issue tracked in
  `docs/model-compatibility.md` Future Work.

---

---

## ✅ Task 6: Auto-tune diff size on `tokens_limit_reached` (Option B) — DONE

**What was implemented:**

- After the rate-limit fallback block, a `while` loop retries up to 3 times when
  `ERROR_CODE == tokens_limit_reached`.
- Each retry halves `MAX_DIFF_CHARS` and rebuilds `DIFF` from the already-fetched
  `FULL_DIFF` (no extra `gh pr diff` call needed).
- Progression: 28k → 14k → 7k → 3.5k — covers all realistic model context limits.
- After 3 failed retries, falls through to the existing actionable error message
  (hints for `--max-diff-chars` and `gh models list`).
- 2 new unit tests: success-after-one-retry, and exhausted-retries error path.

---

## Testing Checklist

- [x] `make test` passes (31 unit tests, shellcheck clean)
- [x] `make integration-test` passes (5 tests)
- [x] Task 4 manual matrix completed — results in `docs/model-compatibility.md`
- [x] Task 5 model compat fixes verified against live API (`openai/gpt-5`)
- [x] Task 6 diff auto-tune verified via unit tests

---

## Out of Scope (deferred)

- `--json` output flag (low priority, no user request yet)
- Progress spinner/dots during API call (nice to have, adds complexity)
- Empty content / reasoning token budget for `gpt-5-nano`, `grok-3-mini` and similar
