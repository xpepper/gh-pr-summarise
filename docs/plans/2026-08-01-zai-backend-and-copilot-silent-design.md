# Design: `zai` backend and clean copilot output

**Date:** 2026-08-01
**Status:** Approved, ready for an implementation plan

**Goal:** Let a z.ai GLM Coding Plan subscription drive `gh-pr-summarise` through a
first-class `zai` backend, and stop the copilot backend from leaking its agent trace into
generated PR descriptions.

---

## Background & research notes

Both items below were verified empirically on 2026-08-01 against a live z.ai coding-plan key
and a local `copilot` install. Nothing here is inferred from documentation alone.

### z.ai coding plan

- The coding plan's OpenAI-compatible base URL is `https://api.z.ai/api/coding/paas/v4`.
  The general Open Platform URL `https://api.z.ai/api/paas/v4` is **not** interchangeable —
  a coding-plan key is rejected there.
- `glm-5.2` (flagship) and `glm-5-turbo` both answer correctly through the standard
  `/chat/completions` shape the existing `http_call` already speaks.
- **Both are thinking models by default.** Measured on a one-sentence prompt:

  | Model | `reasoning_tokens` | visible content tokens |
  |-------|-------------------|------------------------|
  | `glm-5.2` | ~600 | ~140 |
  | `glm-5-turbo` | ~460 | ~140 |

  At `max_tokens: 20` the response came back `finish_reason: length` with an **empty**
  content string — the exact failure mode already documented in
  "Truncation is a failure". The HTTP backends send `max_tokens: 1200`, so a real PR diff
  producing a longer description is not far from tripping it.
- `{"thinking": {"type": "disabled"}}` is accepted and drops `reasoning_tokens` to exactly
  `0` while producing equivalent output. It removes the truncation risk and is faster.

The existing generic `openai` backend can already reach z.ai today by setting
`PR_SUMMARISE_ENDPOINT`, `PR_SUMMARISE_API_KEY` and `PR_SUMMARISE_MODEL`. It cannot disable
thinking, because there is no way to add fields to the request body.

### Copilot output contamination

Observed on a real run (`hutch#4745`), the generated body began with a stray line:

```
● skill(using-superpowers)

Updates the Biome configuration to always use the latest schema.
```

Reproduced from an empty scratch dir with the exact flags the backend uses. The leading
character is U+25CF followed by a space — copilot's skill-invocation trace, written to
**stdout**, which violates the backend contract's "content on stdout, everything else on
stderr" rule.

`copilot -s/--silent` ("output only the agent response") suppresses it; verified, the line
is gone and the summary is unchanged. There is no `--no-skills` flag: skills load from
`~/.copilot/skills/`, `~/.agents/skills/` and installed plugins, so the existing
`$AGENT_CWD` isolation only defeats *project-level* skills. That is acceptable — with
`--available-tools=` already set the skill cannot act, so the visible trace was the entire
problem.

**Rejected alternative:** a second LLM pass (e.g. `apfel`) to clean up the output. The
contamination is one deterministic marker line, not prose contamination. Asking a small
on-device model to *edit* a finished description invites it to rewrite the whole thing, and
costs an extra backend call per run. A downstream sanitiser was also considered and rejected
as speculative: no backend other than copilot has ever leaked, and `--silent` is copilot's
own supported answer. If another backend regresses later, a sanitiser can be added then,
against a real sample.

---

## Design

### 1. `HTTP_EXTRA_BODY` — extra request-body fields

`http_call` builds its body with `jq` and already merges an optional `temperature` object.
Generalise that with a global mirroring the existing `HTTP_EXTRA_HEADERS`:

```bash
HTTP_EXTRA_BODY='{}'

# inside http_call's jq invocation:
--argjson extra "$HTTP_EXTRA_BODY"
'{ model: $model, ($tparam): $maxtok, messages: [...] }
   + (if $include_temp then {temperature: 0.2} else {} end)
   + $extra'
```

Every HTTP backend resets `HTTP_EXTRA_BODY` to `'{}'` at the top of its `_generate`, exactly
as they already reset `HTTP_EXTRA_HEADERS`. **This reset is load-bearing, not tidiness:**
these are globals and the fallback chain runs several backends inside one process, so an
unreset `thinking` field would follow `zai` onto the next provider and break a request that
would otherwise have succeeded.

### 2. The `zai` backend

Four functions by convention, plus one entry in `KNOWN_BACKENDS`:

```bash
backend_zai_available() { [[ -n "${ZAI_API_KEY:-}" ]]; }
backend_zai_model()     { echo "glm-5.2"; }
backend_zai_budget()    { echo 28000; }
backend_zai_generate() {
  HTTP_EXTRA_HEADERS=()
  HTTP_EXTRA_BODY='{"thinking":{"type":"disabled"}}'
  http_generate "https://api.z.ai/api/coding/paas/v4/chat/completions" \
    "${ZAI_API_KEY:-}" "$(resolve_model zai)" "$1" "$2" 1200
}
```

The thinking-disabled setting carries a comment explaining *why* (the measurement above), in
the style of the other load-bearing comments in the script.

Decisions:

- **Default model `glm-5.2`.** `--model glm-5-turbo` works and inherits thinking-disabled.
- **Budget 28000**, matching every other non-`apfel` backend.
- **`max_tokens` stays 1200**, consistent with the other HTTP backends. With thinking
  disabled the measured visible output is ~140 tokens, so the margin is ample.
- **The default chain stays `claude,copilot,openrouter`.** `backend_zai_available` would
  gate it safely, but silently changing which provider answers for existing users is the
  same class of surprise the pinned-backend rule exists to prevent. Using zai means
  `--backend zai` or setting `PR_SUMMARISE_BACKENDS`.

**Known risk:** if a future GLM model rejects the `thinking` field, `http_generate` has no
retry for it — its two portability retries cover `max_tokens` and `temperature` only. The
failure is visible (the raw response is printed) and the chain moves on, so this is
acceptable; a third retry would be speculative.

### 3. Copilot `--silent`

Add `--silent` to the arg list in `backend_copilot_generate`, with a comment naming what it
prevents — copilot's `● skill(...)` trace landing in a PR body.

### 4. Documentation

- `usage()`: add `zai` to the backend list (it renders `$KNOWN_BACKENDS`, so that part is
  automatic) and document `ZAI_API_KEY` under environment variables.
- `README.md`: same, plus a worked z.ai example.
- Both places note that the coding-plan endpoint is `/api/coding/paas/v4` and that the
  general `/api/paas/v4` is not interchangeable — this is the single most likely setup
  mistake.
- `docs/backend-compatibility.md`: add a `zai` row.
- `scripts/backend-matrix.sh`: its `BACKENDS` list duplicates `KNOWN_BACKENDS`; add `zai`
  there too or the matrix silently skips it.

---

## Testing

`zai` speaks HTTP, so it drives the existing `curl` mock in `tests/gh-pr-summarise.bats` and
needs no new harness. Coverage mirrors the openrouter tests:

1. `--backend zai` posts to `https://api.z.ai/api/coding/paas/v4/chat/completions`.
2. The request body carries `thinking.type == "disabled"`.
3. `--model glm-5-turbo` reaches the request body.
4. `--backend zai` without `ZAI_API_KEY` fails with the "not available" message rather than
   falling through to another provider.

Per the project's own note in `CLAUDE.md`, assertions 1–3 must inspect the **actual request
body**, not just the output banner — a test that only checks for a fixed header passes even
when the call is broken. Following the recorded gotcha about cross-process file writes in
CI, the mock echoes the received body back inside its JSON response rather than writing it
to a temp file.

Two hygiene items:

- `teardown()` must `unset ZAI_API_KEY`, alongside the vars it already clears.
- The developer running this has `ZAI_API_KEY` exported in their shell, so any test that
  does **not** pin a backend would start auto-detecting `zai` on their machine while
  behaving differently in CI. The existing chain tests all name their backends explicitly
  (`PR_SUMMARISE_BACKENDS=claude,openrouter` and similar), so no breakage is expected — but
  this is to be confirmed by running the suite, not assumed.

There is no automated coverage for the copilot `--silent` change: the copilot backend is a
live-CLI adapter with no seam, and asserting on a real `copilot` run would make the unit
suite depend on an installed, authenticated CLI. It is verified by the manual reproduction
recorded above and by `make integration-test`.

## Definition of done

1. `make test` passes (shellcheck + bats).
2. `make integration-test` passes.
3. One manual `--backend zai` run against the test PR succeeds, and one `--backend copilot`
   run produces a description with no leading `●` line.
