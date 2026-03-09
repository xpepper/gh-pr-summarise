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
}

teardown() {
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
