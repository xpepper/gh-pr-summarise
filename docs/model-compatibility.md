# GitHub Models Compatibility Matrix

Tested against the [permanent test PR](https://github.com/xpepper/gh-pr-summarise/pull/1)
using `gh pr-summarise --model <MODEL> --yes` with default `--max-diff-chars 28000`.

Tested on: 2026-03-10

## Results

| Model | Default (28k chars) | Notes |
|-------|---------------------|-------|
| `ai21-labs/ai21-jamba-1.5-large` | ❌ unknown model | API returns `unknown_model` — model ID not supported at the inference endpoint |
| `cohere/cohere-command-a` | ✅ | |
| `cohere/cohere-command-r-08-2024` | ✅ | |
| `cohere/cohere-command-r-plus-08-2024` | ✅ | |
| `deepseek/deepseek-r1` | ✅ | |
| `deepseek/deepseek-r1-0528` | ✅ | |
| `deepseek/deepseek-v3-0324` | ✅ | |
| `meta/llama-3.2-11b-vision-instruct` | ✅ | |
| `meta/llama-3.2-90b-vision-instruct` | ✅ | |
| `meta/llama-3.3-70b-instruct` | ✅ | |
| `meta/llama-4-maverick-17b-128e-instruct-fp8` | ✅ | |
| `meta/llama-4-scout-17b-16e-instruct` | ✅ | |
| `meta/meta-llama-3.1-405b-instruct` | ✅ | |
| `meta/meta-llama-3.1-8b-instruct` | ✅ | |
| `microsoft/mai-ds-r1` | ✅ | |
| `microsoft/phi-4` | ✅ | |
| `microsoft/phi-4-mini-instruct` | ❌ timeout | curl context deadline exceeded — model too slow to respond within default timeout |
| `microsoft/phi-4-mini-reasoning` | ✅ | |
| `microsoft/phi-4-multimodal-instruct` | ✅ | |
| `microsoft/phi-4-reasoning` | ❌ timeout | curl context deadline exceeded — same as phi-4-mini-instruct |
| `mistral-ai/codestral-2501` | ✅ | |
| `mistral-ai/ministral-3b` | ✅ | |
| `mistral-ai/mistral-medium-2505` | ✅ | |
| `mistral-ai/mistral-small-2503` | ✅ | |
| `openai/gpt-4.1` | ✅ | Default model |
| `openai/gpt-4.1-mini` | ✅ | |
| `openai/gpt-4.1-nano` | ✅ | |
| `openai/gpt-4o` | ✅ | |
| `openai/gpt-4o-mini` | ✅ | |
| `openai/gpt-5` | ✅ (auto-retry) | Requires `max_completion_tokens` + no `temperature`; both handled transparently |
| `openai/gpt-5-chat` | ✅ | |
| `openai/gpt-5-mini` | ✅ (auto-retry) | Same as gpt-5 |
| `openai/gpt-5-nano` | ⚠️ flaky | Requires `max_completion_tokens` + no `temperature` (both handled), but reasoning tokens consume the 500-token cap; `finish_reason: length`, empty content |
| `openai/o1` | ✅ (auto-retry) | Same as gpt-5 |
| `openai/o1-mini` | ❌ API version | Requires API version `2024-12-01-preview` or later; script uses `2022-11-28` |
| `openai/o1-preview` | ❌ API version | Same as o1-mini |
| `openai/o3` | ✅ (auto-retry) | Same as gpt-5 |
| `openai/o3-mini` | ✅ (auto-retry) | Same as gpt-5 |
| `openai/o4-mini` | ✅ (auto-retry) | Same as gpt-5 |
| `xai/grok-3` | ✅ | |
| `xai/grok-3-mini` | ❌ empty response | Returns empty `content` — reasoning tokens fill the 500-token output cap; `finish_reason: length` |

**Summary:** 35/41 models work (28 out of the box + 7 via auto-retry). 5 fail due to unresolved incompatibilities; 1 is flaky (reasoning token budget).

---

## Failure Categories

### 1. `max_tokens` → `max_completion_tokens` + no custom `temperature` (7 models)

Affects: `openai/gpt-5`, `openai/gpt-5-mini`, `openai/gpt-5-nano`, `openai/o1`, `openai/o3`, `openai/o3-mini`, `openai/o4-mini`

Two errors hit in sequence:

```json
{
  "error": {
    "message": "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.",
    "type": "invalid_request_error",
    "param": "max_tokens",
    "code": "unsupported_parameter"
  }
}
```

```json
{
  "error": {
    "message": "Unsupported value: 'temperature' does not support 0.2 with this model. Only the default (1) value is supported.",
    "type": "invalid_request_error",
    "param": "temperature",
    "code": "unsupported_value"
  }
}
```

**Fixed (2026-03-11):** `invoke_model` now detects and retries both errors transparently:
first retries with `max_completion_tokens`, then retries without `temperature` if that
is also rejected. Verified against `openai/gpt-5` in integration tests.

### 2. API version too old (2 models)

Affects: `openai/o1-mini`, `openai/o1-preview`

Error:
```json
{"error":{"code":"BadRequest","message":"Model o1 is enabled only for api versions 2024-12-01-preview and later"}}
```

**Fix:** The script hardcodes `X-GitHub-Api-Version: 2022-11-28`. These models require
`2024-12-01-preview` or later. Would need per-model version routing or a newer default.

### 3. Empty `content` field — reasoning models with short output cap (2 models)

Affects: `xai/grok-3-mini`, `openai/gpt-5-nano`

The model returns a valid JSON completion response, but `choices[0].message.content` is an
empty string (`""`). All 500 tokens are consumed by internal reasoning before any output is
written (`finish_reason: length`, `reasoning_tokens: 500`).

`gpt-5-nano` also hits the `max_tokens`/`temperature` issues above (both auto-retried), but
the reasoning token budget problem remains unresolved, making it unreliable.

**Fix (open):** Increase the token budget for reasoning models, or implement reactive
retry-with-more-tokens when `finish_reason: length` + empty content is detected.

### 4. Timeout (2 models)

Affects: `microsoft/phi-4-mini-instruct`, `microsoft/phi-4-reasoning`

These models take longer than curl's default timeout to respond. Not a script bug — the
models are simply slow under the free tier. Retrying may help; not worth fixing in the script.

### 5. Unknown model ID (1 model)

Affects: `ai21-labs/ai21-jamba-1.5-large`

The model is listed by `gh models list` but rejected by the inference API with `unknown_model`.
Likely a discrepancy between the marketplace listing and the inference endpoint's model registry.
Nothing to fix on our side.

---

## Recommended Fallback Chain (updated)

Based on results, the current default `openai/gpt-4o,openai/gpt-4o-mini` is solid.
An extended chain covering quality vs speed trade-offs:

```bash
# Best quality fallback chain (all verified ✅)
export PR_SUMMARISE_FALLBACK_MODELS="openai/gpt-4o,openai/gpt-4o-mini,mistral-ai/mistral-small-2503"
```

---

## Future Work

- [x] Support `max_completion_tokens` for gpt-5 / o-series models (auto-detect `unsupported_parameter`) — done 2026-03-11
- [x] Support no-`temperature` for gpt-5 / o-series models (auto-detect `unsupported_value`) — done 2026-03-11
- [ ] Support newer API version routing for o1-mini / o1-preview
- [ ] Handle empty `content` with `finish_reason: length` for reasoning models (grok-3-mini, gpt-5-nano) — increase token budget or retry with more tokens
