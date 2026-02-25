# Roadmap

Planned improvements, roughly in priority order.

## `--version` flag

Add a `VERSION` variable at the top of the script and a `--version` flag that prints `gh pr-summarise <version>` and exits 0. Bump manually on each release.

## CI with shellcheck

Add a GitHub Actions workflow (`.github/workflows/ci.yml`) that runs on every push and pull request:
- `shellcheck gh-pr-summarise` for static analysis
- bats test suite once it exists

## Input validation

Validate that `--max-diff-chars` is a positive integer. Exit 1 with a clear error message if not.

## Spinner during API call

Show an animated spinner on stderr between "Generating summary…" and the result. The GitHub Models call takes 3–5 seconds; the spinner makes the wait feel acknowledged. Suppress it when stdout is not a TTY (i.e. when piped or used with `--yes` in scripts).

## Bats test suite

Add a `tests/` directory with bats-core tests covering at least:
- `--help` exits 0 and prints usage
- `--version` exits 0 and prints the version
- Unknown flag exits 1 and mentions `--help`
- `--max-diff-chars` with a non-integer exits 1

## Makefile

Add a `Makefile` with targets: `test`, `shellcheck`, `install-deps-macos`, `install-deps-ubuntu`.
