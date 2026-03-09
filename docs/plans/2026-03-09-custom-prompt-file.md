# Custom Prompt File Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow users to supply a custom prompt via `--prompt-file <path>` (CLI flag) or `PR_SUMMARISE_PROMPT_FILE` (env var), with the diff always appended after the prompt text.

**Architecture:** All changes are confined to the single `gh-pr-summarise` script. A `PROMPT_FILE` variable is resolved (CLI flag beats env var), validated early (before fetching the diff), and its content replaces the hardcoded prompt string in the `jq` payload. If neither is set, the existing built-in prompt is used unchanged.

**Tech Stack:** Bash, bats (unit tests in `tests/gh-pr-summarise.bats`), `make test` to run all checks.

---

## How the tests work

The test file at `tests/gh-pr-summarise.bats` uses helper `setup_mock_gh` to put fake `gh` and `curl` binaries early on `$PATH`.

To verify that the custom prompt reaches the API call, we need the mock `curl` to record the arguments it receives (the `-d` payload is passed as a CLI arg, not stdin). We will add a helper `setup_mock_gh_capturing_curl` that writes `$@` to `$_MOCK_DIR/curl_args` so tests can inspect it.

Run tests with: `bats tests/gh-pr-summarise.bats`
Run all checks with: `make test`

---

### Task 1: Test – `--prompt-file` with a missing file exits 1 with a clear error

**Files:**
- Modify: `tests/gh-pr-summarise.bats`

**Step 1: Add the failing test**

Append to `tests/gh-pr-summarise.bats`:

```bash
@test "--prompt-file with missing file exits 1 with clear error" {
  run "$SCRIPT" --prompt-file /nonexistent/prompt.txt 123
  [ "$status" -eq 1 ]
  [[ "$output" == *"prompt file not found"* ]]
}
```

**Step 2: Run to confirm it fails**

```
bats tests/gh-pr-summarise.bats --filter "missing file"
```

Expected: FAIL — the script currently doesn't know about `--prompt-file` and exits with "unknown option".

**Step 3: Implement minimal flag parsing + file validation**

In `gh-pr-summarise`, add to the argument-parsing `case` block (after the `-f|--force` branch):

```bash
    -p|--prompt-file)
      PROMPT_FILE="$2"; shift 2 ;;
```

Add the variable initialisation near the other defaults (top of script):

```bash
PROMPT_FILE="${PR_SUMMARISE_PROMPT_FILE:-}"
```

Add the validation block right after argument parsing ends (before the PR-number resolution block):

```bash
# ── Validate prompt file ───────────────────────────────────────────────────────
if [[ -n "$PROMPT_FILE" && ! -r "$PROMPT_FILE" ]]; then
  echo "Error: prompt file not found or not readable: $PROMPT_FILE" >&2
  exit 1
fi
```

**Step 4: Run to confirm it passes**

```
bats tests/gh-pr-summarise.bats --filter "missing file"
```

Expected: PASS

**Step 5: Commit**

```bash
git add tests/gh-pr-summarise.bats gh-pr-summarise
git commit -m "feat(prompt): add --prompt-file flag with missing-file validation"
```

---

### Task 2: Test – `--prompt-file` with a valid file uses the custom prompt in the API call

**Files:**
- Modify: `tests/gh-pr-summarise.bats`

**Step 1: Add a capturing-curl helper and the test**

Append to `tests/gh-pr-summarise.bats`:

```bash
# Sets up mocks like setup_mock_gh but curl saves its args for inspection.
setup_mock_gh_capturing_curl() {
  local body="$1"
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"pr view"* ]]; then
  echo '$body'
elif [[ "\$*" == *"pr diff"* ]]; then
  echo "diff --git a/foo b/foo"
elif [[ "\$*" == *"auth token"* ]]; then
  echo "fake-token"
else
  echo ""
fi
EOF
  chmod +x "$mock_dir/gh"

  cat > "$mock_dir/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$mock_dir/curl_args"
cat <<'JSON'
{"choices":[{"message":{"content":"Generated summary."}}]}
JSON
EOF
  chmod +x "$mock_dir/curl"

  export PATH="$mock_dir:$PATH"
  export _MOCK_DIR="$mock_dir"
}

@test "--prompt-file uses custom prompt text in API call" {
  setup_mock_gh_capturing_curl ""
  local prompt_file
  prompt_file="$(mktemp)"
  echo "My totally custom prompt instructions." > "$prompt_file"

  run bash -c "echo n | $SCRIPT --prompt-file '$prompt_file' 123"
  [ "$status" -eq 0 ]
  grep -q "My totally custom prompt instructions." "$_MOCK_DIR/curl_args"
}
```

**Step 2: Run to confirm it fails**

```
bats tests/gh-pr-summarise.bats --filter "custom prompt text"
```

Expected: FAIL — the custom prompt text is not yet wired into the API call.

**Step 3: Wire custom prompt into the API call**

In `gh-pr-summarise`, replace the hardcoded prompt string in the `jq` payload.
Before the `curl` call, resolve the prompt to use:

```bash
# ── Resolve prompt ─────────────────────────────────────────────────────────────
if [[ -n "$PROMPT_FILE" ]]; then
  PROMPT_TEXT="$(cat "$PROMPT_FILE")"
else
  PROMPT_TEXT="Write a concise GitHub PR description in Markdown for this diff.
Format:
1) One short summary paragraph.
2) A \"## Changes\" section with bullet points.
3) A \"## Notes for reviewers\" section (optional, only if useful).
Output only Markdown, nothing else."
fi
```

Then in the `jq` call, replace the hardcoded multiline string with `$prompt`:

```bash
RESPONSE=$(curl -sS -L "$ENDPOINT" \
  -H "Authorization: Bearer $(gh auth token)" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg model  "$MODEL" \
    --arg prompt "$PROMPT_TEXT" \
    --arg diff   "$DIFF" \
    '{
      model: $model,
      temperature: 0.2,
      max_tokens: 500,
      messages: [{
        role: "user",
        content: $prompt + "\n\n" + $diff
      }]
    }')")
```

**Step 4: Run to confirm it passes**

```
bats tests/gh-pr-summarise.bats --filter "custom prompt text"
```

Expected: PASS

**Step 5: Also confirm existing tests still pass**

```
make test
```

Expected: all tests PASS (built-in prompt behaviour unchanged).

**Step 6: Commit**

```bash
git add tests/gh-pr-summarise.bats gh-pr-summarise
git commit -m "feat(prompt): wire custom prompt file content into API call"
```

---

### Task 3: Test – `PR_SUMMARISE_PROMPT_FILE` env var is used as fallback

**Files:**
- Modify: `tests/gh-pr-summarise.bats`

**Step 1: Add the failing test**

Append to `tests/gh-pr-summarise.bats`:

```bash
@test "PR_SUMMARISE_PROMPT_FILE env var is used when no flag is given" {
  setup_mock_gh_capturing_curl ""
  local prompt_file
  prompt_file="$(mktemp)"
  echo "Env var custom prompt." > "$prompt_file"

  run bash -c "echo n | PR_SUMMARISE_PROMPT_FILE='$prompt_file' $SCRIPT 123"
  [ "$status" -eq 0 ]
  grep -q "Env var custom prompt." "$_MOCK_DIR/curl_args"
}
```

**Step 2: Run to confirm it fails**

```
bats tests/gh-pr-summarise.bats --filter "env var is used"
```

Expected: FAIL — env var is not yet read.

**Step 3: Confirm the implementation already handles it**

The default initialisation added in Task 1 (`PROMPT_FILE="${PR_SUMMARISE_PROMPT_FILE:-}"`) already reads the env var. Run the test — it should pass without any further code changes.

**Step 4: Run to confirm it passes**

```
bats tests/gh-pr-summarise.bats --filter "env var is used"
```

Expected: PASS

**Step 5: Commit**

```bash
git add tests/gh-pr-summarise.bats
git commit -m "test(prompt): verify PR_SUMMARISE_PROMPT_FILE env var fallback"
```

---

### Task 4: Test – `--prompt-file` flag takes precedence over `PR_SUMMARISE_PROMPT_FILE`

**Files:**
- Modify: `tests/gh-pr-summarise.bats`

**Step 1: Add the failing test**

Append to `tests/gh-pr-summarise.bats`:

```bash
@test "--prompt-file flag overrides PR_SUMMARISE_PROMPT_FILE env var" {
  setup_mock_gh_capturing_curl ""
  local flag_file env_file
  flag_file="$(mktemp)"
  env_file="$(mktemp)"
  echo "Flag prompt wins." > "$flag_file"
  echo "Env var prompt loses." > "$env_file"

  run bash -c "echo n | PR_SUMMARISE_PROMPT_FILE='$env_file' $SCRIPT --prompt-file '$flag_file' 123"
  [ "$status" -eq 0 ]
  grep -q "Flag prompt wins." "$_MOCK_DIR/curl_args"
  ! grep -q "Env var prompt loses." "$_MOCK_DIR/curl_args"
}
```

**Step 2: Run to confirm it fails**

```
bats tests/gh-pr-summarise.bats --filter "overrides"
```

Expected: FAIL — flag does not yet override env var (both resolve to same variable).

**Step 3: Fix precedence in argument parsing**

The issue is that `PROMPT_FILE` is initialised from the env var before arg parsing, and the `--prompt-file` arg already overwrites it. This should already work correctly since arg parsing runs after initialisation and overwrites the value. Run the test first to check — if it passes, no code change is needed.

If it fails, ensure the `-p|--prompt-file` case sets `PROMPT_FILE="$2"` unconditionally (which it does).

**Step 4: Run to confirm it passes**

```
bats tests/gh-pr-summarise.bats --filter "overrides"
```

Expected: PASS

**Step 5: Run full test suite**

```
make test
```

Expected: all tests PASS.

**Step 6: Commit**

```bash
git add tests/gh-pr-summarise.bats
git commit -m "test(prompt): verify --prompt-file flag overrides env var"
```

---

### Task 5: Update `usage()` and env var documentation

**Files:**
- Modify: `gh-pr-summarise` (the `usage()` function only)

**Step 1: Add a test for help text**

Append to `tests/gh-pr-summarise.bats`:

```bash
@test "--help documents --prompt-file and PR_SUMMARISE_PROMPT_FILE" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--prompt-file"* ]]
  [[ "$output" == *"PR_SUMMARISE_PROMPT_FILE"* ]]
}
```

**Step 2: Run to confirm it fails**

```
bats tests/gh-pr-summarise.bats --filter "documents"
```

Expected: FAIL — help text does not yet mention these.

**Step 3: Update `usage()`**

In `gh-pr-summarise`, add to the Options section of `usage()`:

```
  -p, --prompt-file PATH        Path to a file containing a custom prompt.
                                The diff is always appended after the prompt text.
                                Overrides PR_SUMMARISE_PROMPT_FILE.
```

And add to the Environment variables section:

```
  PR_SUMMARISE_PROMPT_FILE      Path to a file containing a custom prompt.
                                Overridden by --prompt-file.
```

**Step 4: Run to confirm it passes**

```
bats tests/gh-pr-summarise.bats --filter "documents"
```

Expected: PASS

**Step 5: Run the full test suite**

```
make test
```

Expected: all tests PASS, shellcheck clean.

**Step 6: Commit**

```bash
git add gh-pr-summarise tests/gh-pr-summarise.bats
git commit -m "docs(prompt): document --prompt-file flag and PR_SUMMARISE_PROMPT_FILE env var"
```
