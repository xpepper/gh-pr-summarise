# gh pr-summarise

A `gh` extension that generates a pull request description from the diff using an LLM
backend of your choice — a local CLI you already have (`claude`, `copilot`, `pi`, …)
or any OpenAI-compatible endpoint.

> **Migrating from v0.1?** [GitHub Models was retired on 2026-07-30](https://github.blog/changelog/2026-07-30-github-models-is-now-retired/)
> and its inference API now returns HTTP 410, so v0.1 no longer works at all. v0.2 replaces
> it with pluggable backends. `PR_SUMMARISE_FALLBACK_MODELS` is gone — see
> [Backends](#backends).

> **Agent safety:** only agent CLIs with a supported no-tools mode are offered as backends.
> Codex, Agy and OpenCode are intentionally unsupported because their current CLIs cannot
> disable all model tools for an untrusted PR diff.

## Requirements

- [`gh`](https://cli.github.com) — GitHub CLI, authenticated via `gh auth login`
- `jq` — JSON processor ([jqlang.org](https://jqlang.org))
- `curl` — HTTP client (standard on macOS and Linux); only needed by the HTTP backends
- At least one [backend](#backends)

## Install

```bash
gh extension install xpepper/gh-pr-summarise
```

## Quick start

The tool needs one **backend** — the thing that actually writes the text. There is no
built-in provider, so this is the one setup step.

**If you already use `claude` or `copilot`,** you are done. They are auto-detected.
From a branch with an open PR:

```bash
gh pr-summarise
```

**Otherwise, the fastest zero-cost route is OpenRouter's free tier:**

```bash
# 1. Create a key at https://openrouter.ai/keys, then export it.
#    Add this to ~/.zshrc (or ~/.bashrc) to make it permanent.
export OPENROUTER_API_KEY="sk-or-v1-..."

# 2. Check the key works and see your remaining quota.
curl -sS https://openrouter.ai/api/v1/key \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" | jq '.data'

# 3. Try it against the permanent test PR. Answering "n" applies nothing,
#    so this is safe to run as many times as you like.
echo n | gh pr-summarise --backend openrouter \
  https://github.com/xpepper/gh-pr-summarise/pull/1

# 4. Happy with it? Make OpenRouter the default for every run.
export PR_SUMMARISE_BACKENDS="openrouter,claude,copilot"
```

Then, from any repo with an open PR:

```bash
gh pr-summarise
```

See [Using OpenRouter's free tier](#using-openrouters-free-tier) for the rate limits and
how to pick a different free model.

## Usage

```bash
# From inside a cloned repo — uses the current branch's open PR
gh pr-summarise

# Pass a PR number
gh pr-summarise 123

# Or paste a GitHub URL directly
gh pr-summarise https://github.com/owner/repo/pull/123

# Pick a backend explicitly (otherwise the first available one is auto-detected)
gh pr-summarise --backend openrouter

# Override the model the backend uses
gh pr-summarise --backend claude --model sonnet

# Limit the diff size sent to the model (useful for large PRs or models with small context)
gh pr-summarise --max-diff-chars 10000

# Skip the confirmation prompt (useful in scripts)
gh pr-summarise --yes

# Generate even if a human-written description already exists
gh pr-summarise --force

# Also generate a PR title (adds an [INTOP-123] prefix if the branch carries a card id)
gh pr-summarise --title

# Generate a Conventional Commit title, e.g. "[INTOP-123] feat: add export endpoint"
gh pr-summarise --conventional
```

### What a run looks like

```
$ gh pr-summarise --title 42
Fetching diff for PR #42...
Generating summary via openrouter: openai/gpt-oss-20b:free...
Generating title via openrouter: openai/gpt-oss-20b:free...

Suggested title: [INTOP-123] feat: add user export endpoint
──── Generated description (openrouter: openai/gpt-oss-20b:free) ────
Adds a CSV export endpoint for user records, behind the existing admin scope.

## Changes
- Add `GET /admin/users/export` returning a streamed CSV.
- ...

<!-- pr-summarise -->
───────────────────────────────────────────────────────────────────────────

Apply this description to PR #42? [y/N]
```

Nothing is written to the PR until you answer `y`. The banner names the backend that
actually produced the text, which matters when the first one failed and the tool fell
through to the next.

## Options

| Flag | Short | Default | Description |
|---|---|---|---|
| `--backend` | `-b` | auto-detected | Backend to use — see [Backends](#backends). |
| `--model` | `-m` | backend's own | Model to use. Meaning depends on the backend (`haiku` for `claude`, `openai/gpt-oss-20b:free` for `openrouter`). `apfel` has a single on-device model: pinning it with `--model` is an error, and reaching it through the fallback chain warns and uses its own model. |
| `--max-diff-chars` | `-n` | `28000` | Diff truncation limit. Clamped down further if the backend's own budget is smaller. |
| `--yes` | `-y` | — | Apply without asking for confirmation. |
| `--force` | `-f` | — | Generate even if a human-written description already exists. |
| `--title` | `-t` | — | Also generate a PR title from the diff (see [PR title](#pr-title)). |
| `--conventional` | `-c` | — | Format the generated title as a [Conventional Commit](https://www.conventionalcommits.org/). Implies `--title`. |
| `--prompt-file` | `-p` | — | Path to a file containing a custom system prompt. Overrides `PR_SUMMARISE_PROMPT_FILE`. |
| `--help` | `-h` | — | Show help. |
| `--version` | `-v` | — | Print version and exit. |

## Behaviour

| Existing PR description | What happens |
|---|---|
| Empty | Generate and prompt to apply |
| Just a tracker link (e.g. YouTrack, Jira) | Preserve the link, append generated description |
| Previously generated by this extension | Regenerate and replace |
| Human-written content | Skip — prints the existing description and exits |

Use `--force` to override the skip and generate anyway.

### PR title

By default the tool only touches the PR **description**. Pass `--title` (or `-t`) to
also generate a one-line PR title from the diff:

- If the head branch carries a card id (e.g. `intop-123-add-export-endpoint`), the
  title is prefixed with the uppercased id in brackets — `[INTOP-123] …`. The id is
  matched as the first `key-number` token in the branch name (so `feature/intop-123-…`
  works too). Branches without such a token get no prefix.
- Add `--conventional` (or `-c`) to format the title as a
  [Conventional Commit](https://www.conventionalcommits.org/), e.g.
  `[INTOP-123] feat: add export endpoint`. `--conventional` implies `--title`.

The generated title is shown alongside the description for review and, on confirmation,
applied with `gh pr edit --title`. Title generation makes one extra model request; if it
fails (e.g. rate-limited), the tool warns and still applies the description.

The tool detects its own output via an HTML comment marker (`<!-- pr-summarise -->`) embedded at the end of every generated description. If you edit a generated description and want to protect your changes from being overwritten on the next run, remove that marker.

## Backends

A backend is either a **local CLI** you already have installed or an
**OpenAI-compatible HTTP endpoint**. With no `--backend`, the first available of
`claude,copilot,openrouter` is used; the rest act as a fallback chain if it fails.
Override the order with `PR_SUMMARISE_BACKENDS`, or pin one with `--backend`.

A pinned backend is never silently swapped for another — if you name it, you get it or an
error.

| Backend | Needs | Cost | Notes |
|---|---|---|---|
| `claude` | `claude` CLI | Claude subscription | Defaults to the `haiku` model. |
| `copilot` | `copilot` CLI | Copilot AI credits | Roughly 8–9 credits per call: its own system prompt dominates the request. |
| `openrouter` | `OPENROUTER_API_KEY` | free tier available | 50 requests/day (1 000/day after $10 in credits), 20 req/min. Defaults to `openai/gpt-oss-20b:free`. |
| `openai` | `PR_SUMMARISE_ENDPOINT` | depends | Any OpenAI-compatible endpoint: Microsoft Foundry, OpenRouter, Ollama, llama.cpp, `apfel --serve`. |
| `pi` / `omp` | that CLI | provider API key | |
| `llm` | [`llm`](https://llm.datasette.io) | provider API key | The broadest escape hatch: hundreds of models via plugins, including local ones via `llm-ollama`. |
| `apfel` | [`apfel`](https://apfel.franzai.com/) | **free, offline** | Apple's on-device model. macOS 26+ on Apple Silicon. See the caveat below. |

### Setting up each backend

| Backend | Setup |
|---|---|
| `claude` | `brew install --cask claude-code`, then `claude` once to sign in. |
| `copilot` | Install the [Copilot CLI](https://github.com/github/copilot-cli) and sign in. Needs a Copilot subscription. |
| `openrouter` | Create a key at [openrouter.ai/keys](https://openrouter.ai/keys) and `export OPENROUTER_API_KEY=...`. |
| `openai` | `export PR_SUMMARISE_ENDPOINT=...` and, if the endpoint needs one, `PR_SUMMARISE_API_KEY`. |
| `llm` | `uv tool install llm` (or `pipx install llm`), then `llm keys set openai` — or `llm install llm-ollama` for local models. |
| `apfel` | `brew install apfel`. macOS 26+ on Apple Silicon, with Apple Intelligence enabled. |
| `pi` / `omp` | Install the CLI and authenticate it however that tool expects. |

To see which are actually working on your machine:

```bash
bash scripts/backend-matrix.sh
```

### Using OpenRouter's free tier

Models whose id ends in `:free` cost nothing. The limits are **50 requests/day** without
any purchase, **1 000/day** once you have bought at least $10 in credits, and **20
requests/minute** either way.

Note that `--title` makes a *second* request per run, so with titles enabled a 50/day
allowance is about 25 runs.

List the free models currently on offer, largest context first:

```bash
curl -sS https://openrouter.ai/api/v1/models \
  | jq -r '.data[] | select(.id|endswith(":free")) | "\(.context_length)\t\(.id)"' \
  | sort -rn
```

Pick one with `--model`:

```bash
gh pr-summarise --backend openrouter --model "nvidia/nemotron-3-nano-30b-a3b:free"
```

Two things worth knowing before you go hunting for a "better" free model:

- **Not every `:free` model actually serves requests.** `google/gemma-4-31b-it:free`
  returns `"Provider returned error"`. The default, `openai/gpt-oss-20b:free`, is the one
  this project tests against.
- **Latency swings widely** — the same model on identical input has been measured at 10s
  and 37s. A slow run is not a hang.

### Choosing a backend

`claude`, `copilot` and `openrouter` all produce good descriptions. Pick on cost: `openrouter`
is free but slower (10–35s) and rate-limited; `copilot` is the most accurate but bills
credits per call; `claude` is fast and covered by a subscription you may already pay for.

`apfel` is the only free *offline* option, but its context window is a hard 4 096 tokens
(~3 584 usable), which caps the diff at **8 000 characters** rather than 28 000 — the tool
clamps this automatically. On anything but a small PR it will summarise only the first
fragment of the diff, so treat it as a fast local draft rather than a replacement for the
cloud backends.

### Fallback

If a backend fails — CLI error, empty output, rate limit, or a **truncated** response — the
tool moves to the next one in the chain and prints a notice to stderr. The banner names the
backend that actually produced the text.

A truncated answer is treated as a failure rather than applied to the PR. This matters for
reasoning models: they can spend the entire output budget on hidden reasoning tokens, return
HTTP 200, and hand back a description that stops mid-sentence.

### Caveats when using agent CLIs

`claude`, `copilot`, `pi` and `omp` are coding agents rather than plain completion APIs.
Their adapters explicitly disable tools, close stdin, and run from an empty scratch directory,
so an untrusted diff cannot ask them to inspect the local machine, pick up the current repo's
`AGENTS.md`/`CLAUDE.md`, or swallow the confirmation prompt. Agent CLIs without a supported
no-tools mode are not offered as backends.

### Newer OpenAI model compatibility

Newer OpenAI models (`gpt-5`, `o1`, `o3`, `o4-mini`, and variants) require
`max_completion_tokens` instead of `max_tokens` and reject an explicit `temperature` value.
The HTTP backends detect these errors and retry transparently — no extra flags needed.

## Configuration

Environment variables for advanced use:

```bash
# Pin a backend (equivalent to always passing --backend)
export PR_SUMMARISE_BACKEND="openrouter"

# Change the auto-detection and fallback order
export PR_SUMMARISE_BACKENDS="openrouter,claude,copilot"

# Required by the openrouter backend
export OPENROUTER_API_KEY="sk-or-v1-..."

# Any OpenAI-compatible endpoint, used by the `openai` backend.
# Ollama, llama.cpp and `apfel --serve` all speak this protocol.
export PR_SUMMARISE_ENDPOINT="http://localhost:11434/v1/chat/completions"
export PR_SUMMARISE_API_KEY="..."

# Model to use (equivalent to --model). Meaning depends on the active backend.
export PR_SUMMARISE_MODEL="openai/gpt-oss-20b:free"

# Diff truncation limit (equivalent to --max-diff-chars)
export PR_SUMMARISE_MAX_DIFF_CHARS=28000

# Seconds a single backend attempt may take before the next backend is tried.
# Set to 0 to wait indefinitely.
export PR_SUMMARISE_TIMEOUT=300

# Custom system prompt loaded from a file (overridden by --prompt-file)
export PR_SUMMARISE_PROMPT_FILE="/path/to/my-prompt.txt"

# Generate a title by default (equivalent to always passing --title)
export PR_SUMMARISE_TITLE=1

# Make generated titles Conventional Commits by default (implies --title)
export PR_SUMMARISE_CONVENTIONAL=1
```

## Troubleshooting

| Message | Cause and fix |
|---|---|
| `no usable backend found` | Nothing in the chain is installed or configured. Run `gh pr-summarise --help` for the backend list, then see [Setting up each backend](#setting-up-each-backend). |
| `Backend 'x' is not available` | You pinned a backend with `--backend` that is not installed or whose API key is unset. A pinned backend is never silently swapped for another. |
| `no backend could generate a summary` | Every backend ran but returned nothing — usually expired CLI auth. Re-authenticate the CLI, or drop `2>/dev/null` from the relevant `backend_*_generate` function to see its real error. |
| `Response was truncated (finish_reason=length)` | A reasoning model spent its whole output budget on hidden tokens. Pick a non-reasoning model with `--model`. |
| `rate limit` / HTTP 429 on `openrouter` | You hit 50 requests/day or 20/minute. Check the remaining quota with the `curl .../api/v1/key` command above, or add backends to `PR_SUMMARISE_BACKENDS` so it falls through. |
| `Backend x timed out after 300s` | The CLI blocked — usually an interactive auth prompt it cannot show, or a stalled request. The chain moves on to the next backend; run the CLI by hand to re-authenticate, or raise `PR_SUMMARISE_TIMEOUT`. |
| `already has a human-written description` | Working as intended — the tool will not overwrite prose it did not write. Use `--force`. |
| Summary only covers part of a large PR | The diff was truncated to the backend's budget. Raise `--max-diff-chars`, or switch off `apfel`, which caps at 8 000 characters. |

## Update

```bash
gh extension upgrade pr-summarise
```

## Development

Install locally from a clone of this repo:

```bash
gh extension remove pr-summarise 2>/dev/null; gh extension install .
```

A permanent test PR lives at **https://github.com/xpepper/gh-pr-summarise/pull/1** — it has a small, safe diff and is specifically meant for end-to-end testing.

```bash
# Manual smoke test (prints the generated description, does not apply it)
echo "n" | gh pr-summarise https://github.com/xpepper/gh-pr-summarise/pull/1

# Automated integration test (calls a real backend and edits the test PR)
make integration-test
```

> `make integration-test` is intentionally excluded from `make test` to avoid unintended API calls and PR edits in CI.

To check which backends actually work on this machine, run the matrix script:

```bash
# Try every known backend against the test PR
bash scripts/backend-matrix.sh

# Test a subset, a different PR, or a smaller diff limit
bash scripts/backend-matrix.sh --backends claude,openrouter --test-pr https://github.com/owner/repo/pull/123
```

Measured results are documented in [`docs/backend-compatibility.md`](docs/backend-compatibility.md).
