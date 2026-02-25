#!/usr/bin/env bats
# Integration tests — require gh auth and GitHub Models API access.
# These tests modify the live test PR. Run with: make integration-test

SCRIPT="$BATS_TEST_DIRNAME/../gh-pr-summarise"
TEST_PR_URL="https://github.com/xpepper/gh-pr-summarise/pull/1"
MARKER="<!-- pr-summarise -->"

@test "generates and applies a description to the test PR" {
  run "$SCRIPT" --force --yes "$TEST_PR_URL"

  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #1 description updated"* ]]

  body=$(gh pr view --repo xpepper/gh-pr-summarise 1 --json body -q '.body')
  [[ "$body" == *"$MARKER"* ]]
}
