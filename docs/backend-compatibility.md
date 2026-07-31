# Backend Compatibility Matrix

Tested against the [permanent test PR](https://github.com/xpepper/gh-pr-summarise/pull/1)
using `bash scripts/backend-matrix.sh` with the default `--max-diff-chars 28000`.

Tested on: 2026-07-31

Timings come from a single run on one machine and vary a lot between runs — treat them as
orders of magnitude, not benchmarks. The same OpenRouter model was measured at 10s and 37s
on identical input.

## Results

| Backend | Result | Time | Notes |
|---------|--------|------|-------|
| `claude` | ✅ | 39s | Defaults to `haiku`. |
| `copilot` | ✅ | 9s | Fastest of the subscription backends, and the most accurate in spot checks. Bills ~8–9 AI credits per call. |
| `openrouter` | ✅ | 24s | Free tier. Defaults to `openai/gpt-oss-20b:free`. |
| `openai` | ✅ | — | Generic OpenAI-compatible backend. Verified separately by pointing `PR_SUMMARISE_ENDPOINT` at OpenRouter; unavailable in the matrix run because no endpoint was configured. |
| `pi` | ✅ | 7s | |
| `omp` | ✅ | 10s | Rejects `--no-context-files` despite being pi-family. |
| `agy` | ✅ | 10s | |
| `opencode` | ❌ no output | 4s | `Token refresh failed: 401` — the CLI's own auth had expired on the test machine. Re-authenticate opencode and retry; the adapter itself is untested. |
| `llm` | ✅ | 6s | Uses whatever default model `llm` is configured with. |
| `apfel` | ✅ | 4s | Free and offline. Diff clamped to 8 000 chars — see below. |

## Quality notes

Speed and success are not the same as usefulness. On the test PR — whose diff contains two
independent changes (README env-var docs **and** a `--draw-me-a-rocket` easter egg) — the
backends differ in how much they actually report:

- `copilot`, `claude`, `pi`, `agy`, `omp`, `llm` and `openrouter` all named both
  changes.
- `apfel` named only the README change and missed the easter egg entirely, and it tends to
  skip the requested summary paragraph. It is a reasonable fast local draft, not a
  replacement for the cloud backends.

## apfel's context limit

Apple's on-device model has a hard 4 096-token context, of which ~3 584 are usable for the
prompt. At roughly 2.5 characters per token on diffs that works out to about **8 000
characters**, versus 28 000 for every other backend. The tool clamps this automatically, so
`apfel` never errors on a large PR — it just silently sees less of it. Check the size first:

```bash
gh pr diff <PR> --patch | wc -c
apfel --count-tokens "$(gh pr diff <PR> --patch)"
```

## Reasoning models and truncation

Reasoning models spend part of the output budget on hidden tokens before emitting anything
visible. `openai/gpt-oss-20b:free` burned 289 of a 500-token budget on reasoning, returned
HTTP 200, and handed back a description that stopped mid-sentence.

The HTTP backends therefore request 1 200 output tokens and treat `finish_reason: length`
as a failure, so a truncated description falls through to the next backend instead of being
applied to the PR. If you point the `openai` backend at a reasoning model and see
`❌ truncated`, the model needs a larger output budget than the tool requests.

## Reproducing

```bash
bash scripts/backend-matrix.sh                            # every backend
bash scripts/backend-matrix.sh --backends claude,openrouter
bash scripts/backend-matrix.sh > docs/backend-compatibility.md
```

Nothing is applied to the PR: every run answers `n` at the confirmation prompt.
