#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/model-matrix.sh"

run_model_matrix_function() {
  local function_name="$1"
  local input="$2"

  run bash -lc '
    script="$1"
    function_name="$2"
    input="$3"

    # Source only the helper functions, not the script main body.
    # shellcheck disable=SC1090
    source <(sed -n "/^classify()/,/^# ── Main/{ /^# ── Main/!p; }" "$script")
    "$function_name" "$input"
  ' bash "$SCRIPT" "$function_name" "$input"
}

@test "notes omits max_completion_tokens guidance when diff-size retries are present" {
  local mixed_output="Model openai/gpt-5 requires max_completion_tokens, retrying...
Diff too large for openai/gpt-5. Retrying with --max-diff-chars 14000...
Error: Request too large for this model."

  run_model_matrix_function notes "$mixed_output"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "notes still reports max size when diff-size output includes the token limit" {
  local mixed_output="Model openai/gpt-5 requires max_completion_tokens, retrying...
Diff too large for openai/gpt-5. Retrying with --max-diff-chars 14000...
Error: Request body too large for gpt-5 model. Max size: 4000 tokens."

  run_model_matrix_function notes "$mixed_output"

  [ "$status" -eq 0 ]
  [ "$output" = "Max size: 4000 tokens" ]
}
