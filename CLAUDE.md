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

# Run all checks (shellcheck + bats) — once Makefile exists
make test

# Run shellcheck only
shellcheck gh-pr-summarise

# Run bats tests only — once tests/ exists
bats tests/
```

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

## Behaviour Matrix

| Existing PR description      | Behaviour                                  |
|------------------------------|--------------------------------------------|
| Empty                        | Generate and prompt to apply               |
| Just a tracker URL           | Preserve the URL, append generated content |
| Contains `<!-- pr-summarise -->` | Regenerate and replace                 |
| Human-written content        | Skip — print existing body and exit 0      |

Use `--force` to bypass the human-written check.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for planned improvements.
