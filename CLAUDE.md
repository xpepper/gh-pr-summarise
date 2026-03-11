# gh-pr-summarise Development Guidelines

## Project Overview

`gh-pr-summarise` is a GitHub CLI extension that generates a pull request description
from the diff using GitHub Models (GPT-4.1 by default) and optionally applies it to
the PR.

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
shellcheck gh-pr-summarise

# Run bats unit tests only
bats tests/gh-pr-summarise.bats

# Run integration test (calls GitHub Models API and edits the live test PR)
make integration-test
```

## Definition of Done

A feature or fix is done when:
1. `make test` passes (shellcheck + bats)
2. `make integration-test` passes against the live API (test PR: https://github.com/xpepper/gh-pr-summarise/pull/1)

## Key Design Decisions

- **Single Bash script** — no build step, no compiled binary, no extra runtime deps
  beyond `gh`, `curl`, and `jq`.
- **GitHub Models API** — called directly via `curl` using the token from `gh auth token`.
  The service hard-caps requests at 8 000 tokens; `--max-diff-chars 28000` (~7k tokens)
  leaves headroom for the system prompt.
- **Marker-based idempotency** — generated descriptions embed `<!-- pr-summarise -->`
  so the script can detect and replace its own output on subsequent runs without
  overwriting human-written descriptions.
- **Link-only detection** — if the existing PR body is just a URL (e.g. a YouTrack or
  Jira link), the generated description is appended rather than skipped.
- **Custom prompt** — `--prompt-file PATH` (short: `-p`) or the `PR_SUMMARISE_PROMPT_FILE`
  env var lets callers supply their own system prompt. The flag takes precedence over the
  env var. The file must exist and be readable; missing files are rejected with an error
  before any API call is made.
- **Automatic rate-limit fallback** — on `rate_limit_exceeded`, retries automatically with
  the next model in a comma-separated chain (`openai/gpt-4o,openai/gpt-4o-mini` by default).
  Controlled via `PR_SUMMARISE_FALLBACK_MODELS`; set to `""` to disable. If all models in
  the chain are exhausted, exits with a clear error referencing the env var.
- **Auto-tuning diff size** — on `tokens_limit_reached`, the script halves `MAX_DIFF_CHARS`
  and rebuilds `DIFF` from the already-fetched `FULL_DIFF`, retrying up to 3 times
  (28k → 14k → 7k → 3.5k). If all retries fail, exits with an actionable error hinting at
  `--max-diff-chars` and `gh models list`.
- **Transparent model-compat retries** — `invoke_model` wraps `call_model` and retries when
  a model rejects `max_tokens` (retries with `max_completion_tokens`) or rejects an explicit
  `temperature` (retries without it). Covers `gpt-5`, `o1`, `o3`, `o4-mini` and variants.

## Behaviour Matrix

| Existing PR description      | Behaviour                                  |
|------------------------------|--------------------------------------------|
| Empty                        | Generate and prompt to apply               |
| Just a tracker URL           | Preserve the URL, append generated content |
| Contains `<!-- pr-summarise -->` | Regenerate and replace                 |
| Human-written content        | Skip — print existing body and exit 0      |

Use `--force` to bypass the human-written check.

