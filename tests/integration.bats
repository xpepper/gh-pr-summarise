#!/usr/bin/env bats
# Integration tests — require gh auth and a working backend.
# These tests modify the live test PR. Run with: make integration-test
#
# Set PR_SUMMARISE_BACKEND to choose which backend is exercised; it defaults to
# openrouter because that one is free, so a full run costs nothing.

SCRIPT="$BATS_TEST_DIRNAME/../gh-pr-summarise"
TEST_PR_URL="https://github.com/xpepper/gh-pr-summarise/pull/1"
MARKER="<!-- pr-summarise -->"

export PR_SUMMARISE_BACKEND="${PR_SUMMARISE_BACKEND:-openrouter}"

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

@test "the generated body is never a truncated response" {
  run "$SCRIPT" --force --yes "$TEST_PR_URL"

  [ "$status" -eq 0 ]
  [[ "$output" != *"was truncated"* ]]

  body=$(gh pr view --repo xpepper/gh-pr-summarise 1 --json body -q '.body')
  [[ "$body" == *"$MARKER"* ]]
  # The marker is appended last, so its presence means generation ran to completion.
  [[ "$body" == *"$MARKER" ]]
}

@test "the banner names the backend that produced the description" {
  run "$SCRIPT" --force --yes "$TEST_PR_URL"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated description ($PR_SUMMARISE_BACKEND"* ]]
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
