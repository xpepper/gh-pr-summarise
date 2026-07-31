#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../gh-pr-summarise"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Sets up a mock `gh` that returns a fixed PR body for `gh pr view`.
# Usage: setup_mock_gh "body text"
setup_mock_gh() {
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
  echo "" # gh pr edit, etc.
fi
EOF
  chmod +x "$mock_dir/gh"

  cat > "$mock_dir/curl" <<'EOF'
#!/usr/bin/env bash
# Return a minimal valid GitHub Models response
cat <<'JSON'
{"choices":[{"message":{"content":"Generated summary."}}]}
JSON
EOF
  chmod +x "$mock_dir/curl"

  export PATH="$mock_dir:$PATH"
  export _MOCK_DIR="$mock_dir"
  pin_http_backend
}

# Pins the backend so tests never auto-detect a real CLI that happens to be
# installed on the developer's machine (claude, copilot, ...). The openrouter
# backend speaks HTTP, so the existing `curl` mocks drive it.
pin_http_backend() {
  export PR_SUMMARISE_BACKEND="openrouter"
  export OPENROUTER_API_KEY="fake-key"
}

teardown() {
  unset PR_SUMMARISE_BACKEND OPENROUTER_API_KEY PR_SUMMARISE_BACKENDS
  if [[ -n "${_MOCK_DIR:-}" ]]; then
    rm -rf "$_MOCK_DIR"
    unset _MOCK_DIR
  fi
}

@test "--help exits 0 and prints usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: gh pr-summarise"* ]]
}

@test "-h is an alias for --help" {
  run "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: gh pr-summarise"* ]]
}

@test "--version exits 0 and prints version" {
  run "$SCRIPT" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "gh pr-summarise "* ]]
}

@test "-v is an alias for --version" {
  run "$SCRIPT" -v
  [ "$status" -eq 0 ]
  [[ "$output" == "gh pr-summarise "* ]]
}

@test "unknown flag exits 1 and mentions --help" {
  run "$SCRIPT" --no-such-flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"--help"* ]]
}

@test "--max-diff-chars with a non-integer exits 1" {
  run "$SCRIPT" --max-diff-chars abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "--max-diff-chars with zero exits 1" {
  run "$SCRIPT" --max-diff-chars 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "--max-diff-chars with a negative number exits 1" {
  run "$SCRIPT" --max-diff-chars -5
  [ "$status" -eq 1 ]
  [[ "$output" == *"--help"* || "$output" == *"positive integer"* ]]
}

# ── Behaviour: skip / proceed based on existing PR body ───────────────────────

@test "skips PR with human-written description" {
  setup_mock_gh "This is a hand-crafted description."
  run "$SCRIPT" 123
  [ "$status" -eq 0 ]
  [[ "$output" == *"already has a human-written description"* ]]
}

@test "proceeds when PR body is empty" {
  setup_mock_gh ""
  run bash -c "echo n | $SCRIPT 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated description"* ]]
}

@test "proceeds when PR body is a tracker URL only" {
  setup_mock_gh "https://example.atlassian.net/browse/PROJ-123"
  run bash -c "echo n | $SCRIPT 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated description"* ]]
}

@test "proceeds when PR body contains the pr-summarise marker" {
  setup_mock_gh "Previous summary.

<!-- pr-summarise -->"
  run bash -c "echo n | $SCRIPT 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated description"* ]]
}

@test "output banner includes the active backend and model name" {
  setup_mock_gh ""
  run bash -c "echo n | $SCRIPT --model openai/gpt-4o-mini 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated description (openrouter: openai/gpt-4o-mini)"* ]]
}

# The banner must name the backend that actually produced the text, not the one
# we started with — otherwise a silent fallback misattributes the output.
@test "output banner names the fallback backend after the first one fails" {
  setup_mock_gh ""
  cat > "$_MOCK_DIR/claude" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$_MOCK_DIR/claude"

  unset PR_SUMMARISE_BACKEND
  run bash -c "echo n | PR_SUMMARISE_BACKENDS=claude,openrouter bash '$SCRIPT' 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated description (openrouter:"* ]]
}

@test "preserves tracker URL prefix in generated body" {
  setup_mock_gh "https://example.atlassian.net/browse/PROJ-123"
  run bash -c "echo n | $SCRIPT 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://example.atlassian.net/browse/PROJ-123"* ]]
}

@test "skips PR with tracker URL prefix followed by human content" {
  setup_mock_gh "https://example.atlassian.net/browse/PROJ-123

This is a hand-crafted description."
  run "$SCRIPT" 123
  [ "$status" -eq 0 ]
  [[ "$output" == *"already has a human-written description"* ]]
}

@test "preserves tracker URL prefix when regenerating from marker" {
  setup_mock_gh "https://example.atlassian.net/browse/PROJ-123

Previous summary.

<!-- pr-summarise -->"
  run bash -c "echo n | $SCRIPT 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://example.atlassian.net/browse/PROJ-123"* ]]
}

@test "--prompt-file with missing file exits 1 with clear error" {
  run "$SCRIPT" --prompt-file /nonexistent/prompt.txt 123
  [ "$status" -eq 1 ]
  [[ "$output" == *"prompt file not found"* ]]
}

# Sets up mocks like setup_mock_gh but curl saves its args for inspection.
# Sets up a mock `gh` and a curl that echoes the request content back as the
# generated summary.  This lets tests assert against bats's $output without
# relying on cross-process file writes (which are unreliable on some CI runners).
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

  # Extract the -d body from curl args and echo it back as the "content" so
  # tests can verify what was sent to the API by inspecting $output.
  # Uses python3 for JSON handling to avoid jq availability issues in CI subshells.
  cat > "$mock_dir/curl" <<'CURLEOF'
#!/usr/bin/env bash
request_body=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-d" ]]; then
    request_body="$2"; shift 2
  else
    shift
  fi
done
python3 -c 'import sys,json;d=json.loads(sys.argv[1]);print(json.dumps({"choices":[{"message":{"content":d["messages"][0]["content"]}}]}))' "$request_body" 2>/dev/null \
  || echo '{"choices":[{"message":{"content":"Generated summary."}}]}'
CURLEOF
  chmod +x "$mock_dir/curl"

  export PATH="$mock_dir:$PATH"
  export _MOCK_DIR="$mock_dir"
  pin_http_backend
}

@test "--prompt-file uses custom prompt text in API call" {
  setup_mock_gh_capturing_curl ""
  local prompt_file="$_MOCK_DIR/prompt.txt"
  echo "My totally custom prompt instructions." > "$prompt_file"

  run bash -c "echo n | $SCRIPT --prompt-file '$prompt_file' 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"My totally custom prompt instructions."* ]]
}

@test "PR_SUMMARISE_PROMPT_FILE env var is used when no flag is given" {
  setup_mock_gh_capturing_curl ""
  local prompt_file="$_MOCK_DIR/env-prompt.txt"
  echo "Env var custom prompt." > "$prompt_file"

  run bash -c "echo n | PR_SUMMARISE_PROMPT_FILE='$prompt_file' $SCRIPT 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Env var custom prompt."* ]]
}

@test "--prompt-file flag overrides PR_SUMMARISE_PROMPT_FILE env var" {
  setup_mock_gh_capturing_curl ""
  local flag_file="$_MOCK_DIR/flag-prompt.txt"
  local env_file="$_MOCK_DIR/env-prompt.txt"
  echo "Flag prompt wins." > "$flag_file"
  echo "Env var prompt loses." > "$env_file"

  run bash -c "echo n | PR_SUMMARISE_PROMPT_FILE='$env_file' $SCRIPT --prompt-file '$flag_file' 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Flag prompt wins."* ]]
  [[ "$output" != *"Env var prompt loses."* ]]
}

@test "default prompt instructs the model not to wrap output in a code fence" {
  grep -q "code fence" "$SCRIPT"
}

@test "--help documents --prompt-file and PR_SUMMARISE_PROMPT_FILE" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--prompt-file"* ]]
  [[ "$output" == *"PR_SUMMARISE_PROMPT_FILE"* ]]
}

@test "--help documents --title and --conventional and their env vars" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--title"* ]]
  [[ "$output" == *"--conventional"* ]]
  [[ "$output" == *"PR_SUMMARISE_TITLE"* ]]
  [[ "$output" == *"PR_SUMMARISE_CONVENTIONAL"* ]]
}

@test "unknown --backend exits 1 and lists the known backends" {
  run "$SCRIPT" --backend nosuchbackend 123
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown backend"* ]]
  [[ "$output" == *"openrouter"* ]]
}

@test "--help documents --backend and its env vars" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--backend"* ]]
  [[ "$output" == *"PR_SUMMARISE_BACKEND"* ]]
  [[ "$output" == *"PR_SUMMARISE_BACKENDS"* ]]
}

@test "falls back to the next backend in the chain when the first one fails" {
  setup_mock_gh ""

  cat > "$_MOCK_DIR/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude exploded" >&2
exit 1
EOF
  chmod +x "$_MOCK_DIR/claude"

  unset PR_SUMMARISE_BACKEND
  run bash -c "echo n | PR_SUMMARISE_BACKENDS=claude,openrouter bash '$SCRIPT' 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated summary."* ]]
}

@test "falls back to the next backend when a backend returns empty output" {
  setup_mock_gh ""

  # Exits 0 but prints nothing — a silent failure mode real CLIs do exhibit.
  cat > "$_MOCK_DIR/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$_MOCK_DIR/claude"

  unset PR_SUMMARISE_BACKEND
  run bash -c "echo n | PR_SUMMARISE_BACKENDS=claude,openrouter bash '$SCRIPT' 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated summary."* ]]
}

@test "exits with helpful message when every backend in the chain fails" {
  setup_mock_gh ""

  cat > "$_MOCK_DIR/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"error":{"code":"rate_limit_exceeded","message":"Rate limit reached"}}'
EOF
  chmod +x "$_MOCK_DIR/curl"

  run bash "$SCRIPT" 123
  [ "$status" -ne 0 ]
  [[ "$output" == *"no backend could generate"* ]]
  [[ "$output" == *"PR_SUMMARISE_BACKENDS"* ]]
}

@test "exits with a helpful message when no backend is available at all" {
  setup_mock_gh ""
  unset PR_SUMMARISE_BACKEND OPENROUTER_API_KEY

  # Both HTTP backends gate on an env var rather than on a binary, so unsetting
  # those is a PATH-independent way to make every backend in the chain absent.
  run bash -c "unset PR_SUMMARISE_ENDPOINT; PR_SUMMARISE_BACKENDS=openai,openrouter bash '$SCRIPT' 123"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no usable backend"* ]]
}

@test "pinned backend that is unavailable does not silently fall through" {
  setup_mock_gh ""
  unset OPENROUTER_API_KEY

  run bash -c "unset PR_SUMMARISE_ENDPOINT; PR_SUMMARISE_BACKEND=openai bash '$SCRIPT' 123"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no usable backend"* ]]
  [[ "$output" == *"'openai' is not available"* ]]
}

# A truncated description must never be silently applied to the PR: the live
# OpenRouter run hit exactly this when reasoning tokens ate the output budget.
@test "treats finish_reason=length as a backend failure" {
  setup_mock_gh ""

  cat > "$_MOCK_DIR/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"choices":[{"finish_reason":"length","message":{"content":"This summary was cut off mid-"}}]}'
EOF
  chmod +x "$_MOCK_DIR/curl"

  run bash "$SCRIPT" 123
  [ "$status" -ne 0 ]
  [[ "$output" == *"truncated"* ]]
  [[ "$output" != *"This summary was cut off mid-"* ]]
}

@test "clamps the diff to the backend's own budget when it is smaller" {
  setup_mock_gh ""

  # A diff far larger than apfel's 8000-char budget.
  cat > "$_MOCK_DIR/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"pr view"* ]]; then
  echo ""
elif [[ "$*" == *"pr diff"* ]]; then
  head -c 20000 /dev/zero | tr '\0' 'x'
elif [[ "$*" == *"auth token"* ]]; then
  echo "fake-token"
else
  echo ""
fi
EOF
  chmod +x "$_MOCK_DIR/gh"

  # apfel echoes back how many characters of diff it actually received.
  cat > "$_MOCK_DIR/apfel" <<'EOF'
#!/usr/bin/env bash
diff_file=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-f" ]]; then diff_file="$2"; shift 2; else shift; fi
done
echo "RECEIVED_CHARS=$(wc -c < "$diff_file" | tr -d ' ')"
EOF
  chmod +x "$_MOCK_DIR/apfel"

  run bash -c "echo n | PR_SUMMARISE_BACKEND=apfel bash '$SCRIPT' 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECEIVED_CHARS=8000"* ]]
}

@test "--max-diff-chars still wins when smaller than the backend budget" {
  setup_mock_gh ""

  cat > "$_MOCK_DIR/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"pr view"* ]]; then
  echo ""
elif [[ "$*" == *"pr diff"* ]]; then
  head -c 20000 /dev/zero | tr '\0' 'x'
elif [[ "$*" == *"auth token"* ]]; then
  echo "fake-token"
else
  echo ""
fi
EOF
  chmod +x "$_MOCK_DIR/gh"

  cat > "$_MOCK_DIR/apfel" <<'EOF'
#!/usr/bin/env bash
diff_file=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-f" ]]; then diff_file="$2"; shift 2; else shift; fi
done
echo "RECEIVED_CHARS=$(wc -c < "$diff_file" | tr -d ' ')"
EOF
  chmod +x "$_MOCK_DIR/apfel"

  run bash -c "echo n | PR_SUMMARISE_BACKEND=apfel bash '$SCRIPT' --max-diff-chars 500 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECEIVED_CHARS=500"* ]]
}

@test "retries without temperature when model rejects it" {
  setup_mock_gh ""

  local sentinel="$_MOCK_DIR/curl_called"

  cat > "$_MOCK_DIR/curl" <<EOF
#!/usr/bin/env bash
if [[ ! -e "$sentinel" ]]; then
  touch "$sentinel"
  echo '{"error":{"code":"unsupported_value","message":"temperature not supported","param":"temperature","type":"invalid_request_error"}}'
else
  echo '{"choices":[{"message":{"content":"summary without temperature"}}]}'
fi
EOF
  chmod +x "$_MOCK_DIR/curl"

  run bash -c "echo n | bash '$SCRIPT' 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"summary without temperature"* ]]
}

@test "retries with max_completion_tokens when model rejects max_tokens" {
  setup_mock_gh ""

  local sentinel="$_MOCK_DIR/curl_called"

  cat > "$_MOCK_DIR/curl" <<EOF
#!/usr/bin/env bash
if [[ ! -e "$sentinel" ]]; then
  touch "$sentinel"
  echo '{"error":{"code":"unsupported_parameter","message":"max_tokens not supported","param":"max_tokens","type":"invalid_request_error"}}'
else
  echo '{"choices":[{"message":{"content":"summary via max_completion_tokens"}}]}'
fi
EOF
  chmod +x "$_MOCK_DIR/curl"

  run bash -c "echo n | bash '$SCRIPT' 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"summary via max_completion_tokens"* ]]
}

@test "retry request for max_completion_tokens models sends max_completion_tokens field" {
  setup_mock_gh ""

  local sentinel="$_MOCK_DIR/curl_called"

  # First call returns unsupported_parameter; second call echoes the request body
  # as the summary so we can inspect what was sent.
  cat > "$_MOCK_DIR/curl" <<EOF
#!/usr/bin/env bash
if [[ ! -e "$sentinel" ]]; then
  touch "$sentinel"
  echo '{"error":{"code":"unsupported_parameter","message":"max_tokens not supported","param":"max_tokens","type":"invalid_request_error"}}'
else
  request_body=""
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "-d" ]]; then request_body="\$2"; shift 2; else shift; fi
  done
  python3 -c 'import sys,json;d=json.loads(sys.argv[1]);print(json.dumps({"choices":[{"message":{"content":d["messages"][0]["content"]+" KEYS:"+",".join(d.keys())}}]}))' "\$request_body" 2>/dev/null \
    || echo '{"choices":[{"message":{"content":"fallback"}}]}'
fi
EOF
  chmod +x "$_MOCK_DIR/curl"

  run bash -c "echo n | bash '$SCRIPT' 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"max_completion_tokens"* ]]
  [[ "$output" != *"\"max_tokens\""* ]]
}

# ── PR title generation ───────────────────────────────────────────────────────

# Like setup_mock_gh but `gh pr view --json headRefName` returns a branch name,
# `gh pr edit` echoes its args (so apply-time assertions are possible), and curl
# returns a fixed title/summary content.
# Usage: setup_mock_gh_title "body" "branch-name" "model content"
setup_mock_gh_title() {
  local body="$1" branch="$2" content="$3"
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"headRefName"* ]]; then
  echo '$branch'
elif [[ "\$*" == *"pr edit"* ]]; then
  echo "EDIT_ARGS: \$*"
elif [[ "\$*" == *"pr view"* ]]; then
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
cat <<'JSON'
{"choices":[{"message":{"content":"$content"}}]}
JSON
EOF
  chmod +x "$mock_dir/curl"

  export PATH="$mock_dir:$PATH"
  export _MOCK_DIR="$mock_dir"
  pin_http_backend
}

# Guards against the whole CLI-backend path silently sending the wrong thing:
# a backend that merely returns *something* would pass every other assertion.
@test "CLI backends receive the resolved prompt and the diff" {
  setup_mock_gh ""
  local prompt_file="$_MOCK_DIR/prompt.txt"
  echo "SENTINEL custom instructions." > "$prompt_file"

  cat > "$_MOCK_DIR/claude" <<'EOF'
#!/usr/bin/env bash
# Echo back the prompt argument so the test can inspect what was sent.
for arg in "$@"; do :; done
echo "SENT>>> $arg"
EOF
  chmod +x "$_MOCK_DIR/claude"

  run bash -c "echo n | PR_SUMMARISE_BACKEND=claude bash '$SCRIPT' --prompt-file '$prompt_file' 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SENTINEL custom instructions."* ]]
  [[ "$output" == *"diff --git a/foo b/foo"* ]]
}

@test "--title adds an uppercased [CARD-ID] prefix parsed from the branch" {
  setup_mock_gh_title "" "intop-123-add-export-endpoint" "add export endpoint"
  run bash -c "echo n | $SCRIPT --title 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Suggested title: [INTOP-123] add export endpoint"* ]]
}

@test "--title handles a card id embedded in a path-style branch name" {
  setup_mock_gh_title "" "feature/intop-456-thing" "do the thing"
  run bash -c "echo n | $SCRIPT --title 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Suggested title: [INTOP-456] do the thing"* ]]
}

@test "--title omits the prefix when the branch has no card id" {
  setup_mock_gh_title "" "main" "add export endpoint"
  run bash -c "echo n | $SCRIPT --title 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Suggested title: add export endpoint"* ]]
  [[ "$output" != *"Suggested title: ["* ]]
}

@test "no --title means no suggested title is generated" {
  setup_mock_gh_title "" "intop-123-foo" "add export endpoint"
  run bash -c "echo n | $SCRIPT 123"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Suggested title:"* ]]
}

@test "--conventional sends conventional-commit instructions in the title request" {
  setup_mock_gh_title "" "intop-123-foo" "feat: add export endpoint"
  # Override curl to surface the request body so we can inspect what was sent.
  cat > "$_MOCK_DIR/curl" <<'EOF'
#!/usr/bin/env bash
request_body=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-d" ]]; then request_body="$2"; shift 2; else shift; fi
done
echo "API_REQUEST: $request_body" >&2
echo '{"choices":[{"message":{"content":"feat: add export endpoint"}}]}'
EOF
  chmod +x "$_MOCK_DIR/curl"

  run bash -c "echo n | $SCRIPT --conventional 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Conventional Commit"* ]]
  [[ "$output" == *"Suggested title: [INTOP-123] feat: add export endpoint"* ]]
}

@test "--conventional implies --title" {
  setup_mock_gh_title "" "intop-123-foo" "feat: add export endpoint"
  run bash -c "echo n | $SCRIPT --conventional 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Suggested title:"* ]]
}

@test "applying with --title passes --title to gh pr edit" {
  setup_mock_gh_title "" "intop-123-add-export-endpoint" "add export endpoint"
  run bash -c "$SCRIPT --title --yes 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EDIT_ARGS:"* ]]
  [[ "$output" == *"--title"* ]]
  [[ "$output" == *"[INTOP-123] add export endpoint"* ]]
}

@test "title generation failure is non-fatal; description is still applied" {
  setup_mock_gh ""

  local sentinel="$_MOCK_DIR/curl_called"
  # First call (summary) succeeds; subsequent calls (title) are rate-limited.
  cat > "$_MOCK_DIR/curl" <<EOF
#!/usr/bin/env bash
if [[ ! -e "$sentinel" ]]; then
  touch "$sentinel"
  echo '{"choices":[{"message":{"content":"the description"}}]}'
else
  echo '{"error":{"code":"rate_limit_exceeded","message":"Rate limit reached"}}'
fi
EOF
  chmod +x "$_MOCK_DIR/curl"

  # Disable fallback so the title call fails fast instead of cycling models.
  run bash -c "echo n | PR_SUMMARISE_FALLBACK_MODELS='' $SCRIPT --title 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not generate a title"* ]]
  [[ "$output" == *"the description"* ]]
  [[ "$output" != *"Suggested title:"* ]]
}

@test "banner omits the colon for backends that carry no model id" {
  setup_mock_gh ""
  cat > "$_MOCK_DIR/copilot" <<'MOCK'
#!/usr/bin/env bash
echo "summary from copilot"
MOCK
  chmod +x "$_MOCK_DIR/copilot"

  run bash -c "echo n | PR_SUMMARISE_BACKEND=copilot bash '$SCRIPT' 123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated description (copilot)"* ]]
  [[ "$output" != *"copilot: )"* ]]
}
