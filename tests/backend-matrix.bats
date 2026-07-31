#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/backend-matrix.sh"

run_backend_matrix_function() {
  local function_name="$1"
  local input="$2"

  run bash -lc '
    script="$1"
    function_name="$2"
    input="$3"

    # Source only the helper functions, not the script main body.
    # shellcheck disable=SC1090
    source <(sed -n "/^_analyze_output()/,/^# ── Main/{ /^# ── Main/!p; }" "$script")
    "$function_name" "$input"
  ' bash "$SCRIPT" "$function_name" "$input"
}

@test "a successful run is classified as success" {
  run_backend_matrix_function classify "Generating summary via claude: haiku...
──── Generated description (claude: haiku) ────
Some summary."

  [ "$status" -eq 0 ]
  [ "$output" = "✅" ]
}

# An uninstalled CLI is not a compatibility failure, and reporting it as one
# would make the table lie about backends the reader simply has not set up.
@test "an unavailable backend is skipped rather than reported as broken" {
  run_backend_matrix_function classify "Error: no usable backend found.
Backend 'opencode' is not available — is its CLI installed and its API key set?"

  [ "$status" -eq 0 ]
  [ "$output" = "⏭️ unavailable" ]
}

@test "an unknown backend is reported as invalid rather than unavailable" {
  local input="Error: unknown backend: typo
Known backends: claude copilot openrouter"

  run_backend_matrix_function classify "$input"
  [ "$status" -eq 0 ]
  [ "$output" = "❌ invalid backend" ]

  run_backend_matrix_function notes "$input"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown backend name" ]
}

@test "a backend that ran but returned nothing is reported as no output" {
  run_backend_matrix_function classify "Generating summary via opencode...
Backend opencode produced no summary.
Error: no backend could generate a summary."

  [ "$status" -eq 0 ]
  [ "$output" = "❌ no output" ]
}

@test "a truncated response is called out separately from a missing one" {
  run_backend_matrix_function classify "Response was truncated (finish_reason=length) — output budget of 1200 tokens was too small.
Error: no backend could generate a summary."

  [ "$status" -eq 0 ]
  [ "$output" = "❌ truncated" ]
}

@test "the truncation note explains the cause" {
  run_backend_matrix_function notes "Response was truncated (finish_reason=length) — output budget of 1200 tokens was too small."

  [ "$status" -eq 0 ]
  [ "$output" = "output budget too small for this model" ]
}
