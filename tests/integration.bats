#!/usr/bin/env bats
# Integration tests — require gh auth and GitHub Models API access.
# These tests modify the live test PR. Run with: make integration-test

SCRIPT="$BATS_TEST_DIRNAME/../gh-pr-summarise"
TEST_PR_URL="https://github.com/xpepper/gh-pr-summarise/pull/1"
MARKER="<!-- pr-summarise -->"

@test "skips PR that has a human-written description" {
  gh pr edit --repo xpepper/gh-pr-summarise 1 \
    --body "This is a hand-written description with no marker."

  run "$SCRIPT" "$TEST_PR_URL"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already has a human-written description"* ]]

  body=$(gh pr view --repo xpepper/gh-pr-summarise 1 --json body -q '.body')
  [[ "$body" == "This is a hand-written description with no marker." ]]
}

@test "generates and applies a description to the test PR" {
  run "$SCRIPT" --force --yes "$TEST_PR_URL"

  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #1 description updated"* ]]

  body=$(gh pr view --repo xpepper/gh-pr-summarise 1 --json body -q '.body')
  [[ "$body" == *"$MARKER"* ]]
}

@test "regenerates and replaces a previously generated description (idempotency)" {
  # Ensure the PR already has a generated description (marker present)
  "$SCRIPT" --force --yes "$TEST_PR_URL"
  first_body=$(gh pr view --repo xpepper/gh-pr-summarise 1 --json body -q '.body')
  [[ "$first_body" == *"$MARKER"* ]]

  # Run again without --force — should detect the marker and regenerate
  run "$SCRIPT" --yes "$TEST_PR_URL"

  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #1 description updated"* ]]

  second_body=$(gh pr view --repo xpepper/gh-pr-summarise 1 --json body -q '.body')
  # Marker still present (not appended twice)
  [[ "$second_body" == *"$MARKER"* ]]
  marker_count=$(echo "$second_body" | grep -c "$MARKER")
  [ "$marker_count" -eq 1 ]
}

@test "works with openai/gpt-5-nano which requires max_completion_tokens" {
  run "$SCRIPT" --model openai/gpt-5-nano --force --yes "$TEST_PR_URL"

  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #1 description updated"* ]]

  body=$(gh pr view --repo xpepper/gh-pr-summarise 1 --json body -q '.body')
  [[ "$body" == *"$MARKER"* ]]
}

@test "preserves tracker URL prefix when generating a description" {
  tracker_url="https://example.atlassian.net/browse/PROJ-123"
  gh pr edit --repo xpepper/gh-pr-summarise 1 --body "$tracker_url"

  run "$SCRIPT" --yes "$TEST_PR_URL"

  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #1 description updated"* ]]

  body=$(gh pr view --repo xpepper/gh-pr-summarise 1 --json body -q '.body')
  # Tracker URL is preserved at the top
  [[ "$body" == "$tracker_url"* ]]
  # Generated content and marker follow
  [[ "$body" == *"$MARKER"* ]]
}
