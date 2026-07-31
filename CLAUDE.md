# gh-pr-summarise Development Guidelines

## Project Overview

`gh-pr-summarise` is a GitHub CLI extension that generates a pull request description
from the diff using a pluggable LLM backend and optionally applies it to the PR.

This is a **single Bash script** (`gh-pr-summarise`) that implements the extension.

Run `./gh-pr-summarise --help` for usage.

**Context Marker**: When working with this file, add `📝` to your start-of-message markers.

**Example**:
"🍀 📝 Let's implement the requested feature..."

## Quick Reference

```bash
# Run the extension locally
./gh-pr-summarise [PR]

# Run all checks (shellcheck + bats unit tests)
make test

# Run shellcheck only
shellcheck gh-pr-summarise scripts/backend-matrix.sh

# Run bats unit tests only
bats tests/gh-pr-summarise.bats tests/backend-matrix.bats

# Check which backends work on this machine
bash scripts/backend-matrix.sh

# Run integration test (calls a live backend and edits the live test PR)
make integration-test
```

## Definition of Done

A feature or fix is done when:
1. `make test` passes (shellcheck + bats)
2. `make integration-test` passes against a live backend (test PR: https://github.com/xpepper/gh-pr-summarise/pull/1)

Unit tests must pin `PR_SUMMARISE_BACKEND` (the `pin_http_backend` helper). Without it,
auto-detection picks up whatever real CLI happens to be installed on the developer's
machine, so the suite would make live API calls and behave differently in CI.

## Key Design Decisions

- **Single Bash script** — no build step, no compiled binary, no extra runtime deps
  beyond `gh`, `curl`, and `jq`.
- **Marker-based idempotency** — generated descriptions embed `<!-- pr-summarise -->`
  so the script can detect and replace its own output on subsequent runs without
  overwriting human-written descriptions.
- **Link-only detection** — if the existing PR body is just a URL (e.g. a YouTrack or
  Jira link), the generated description is appended rather than skipped.
- **Custom prompt** — `--prompt-file PATH` (short: `-p`) or the `PR_SUMMARISE_PROMPT_FILE`
  env var lets callers supply their own system prompt. The flag takes precedence over the
  env var. The file must exist and be readable; missing files are rejected with an error
  before any backend call is made.
- **Backend contract** — each backend implements four functions:
  `backend_<n>_available` / `_model` / `_budget` / `_generate`. `_generate` takes
  `$1`=prompt `$2`=diff and puts **content on stdout, everything else on stderr**.
  That discipline is what lets each CLI adapter be a one-liner wrapping `2>/dev/null`.
  Dispatch is by convention (`"backend_${name}_generate"`), so adding a backend means
  adding four functions and one entry in `KNOWN_BACKENDS`.
- **CLI backends are isolated** — every CLI backend runs with `</dev/null` and from an
  empty scratch dir (`$AGENT_CWD`). Both are load-bearing: `codex exec` reads stdin and
  would swallow the y/N confirmation answer, and agent CLIs auto-load `AGENTS.md` from the
  cwd and would follow *this repo's* instructions instead of the summarisation prompt.
  User-global agent instructions are deliberately left alone.
- **Backend chain, not model chain** — on failure the tool tries the next backend in
  `PR_SUMMARISE_BACKENDS` (default `claude,copilot,openrouter`). A backend pinned with
  `--backend` is never silently swapped.
- **Per-backend diff budget** — `min(MAX_DIFF_CHARS, backend_budget)` applied up front,
  rather than retrying on overflow. `apfel` is 8000, everything else 28000.
- **Truncation is a failure** — `finish_reason: length` makes the HTTP backend fail so the
  chain moves on. Reasoning models can spend the whole output budget on hidden tokens and
  still return HTTP 200 with a half-finished description.
- **`generate_content` sets globals** — it assigns `GENERATED_CONTENT` and `ACTIVE_BACKEND`
  instead of echoing its result. Capturing it via `$(...)` ran it in a subshell that lost
  track of which backend actually answered, so the banner could name the wrong one.
- **Transparent model-compat retries** — the HTTP backends retry when a model rejects
  `max_tokens` (retrying with `max_completion_tokens`) or an explicit `temperature`.
- **Optional PR title** — `--title` (`-t`, env `PR_SUMMARISE_TITLE`) makes a second model
  call to generate a one-line title from the diff. A `[CARD-ID]` prefix is derived
  deterministically from the head branch (first `key-number` token, uppercased; e.g.
  `intop-123-foo` → `[INTOP-123] `). `--conventional` (`-c`, env `PR_SUMMARISE_CONVENTIONAL`)
  formats it as a Conventional Commit and implies `--title`. The description and title share
  the `generate_content` helper. Title generation is best-effort: on failure the tool warns
  and still applies the description. Note it costs a second backend call per run.

## Behaviour Matrix

| Existing PR description      | Behaviour                                  |
|------------------------------|--------------------------------------------|
| Empty                        | Generate and prompt to apply               |
| Just a tracker URL           | Preserve the URL, append generated content |
| Contains `<!-- pr-summarise -->` | Regenerate and replace                 |
| Human-written content        | Skip — print existing body and exit 0      |

Use `--force` to bypass the human-written check.

