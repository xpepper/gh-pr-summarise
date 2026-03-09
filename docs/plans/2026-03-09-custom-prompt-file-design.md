# Design: Custom Prompt File

**Date:** 2026-03-09
**Status:** Approved

## Problem

The prompt used to generate PR descriptions is hardcoded in the script. Users who want
a different tone, format, or structure have no way to customise it without forking the script.

## Solution

Allow the user to supply a custom prompt via a file, either as a CLI flag or a persistent
environment variable. The diff is always appended after the prompt content (built-in or custom).

## Design Decisions

### Prompt delivery: file-based only

The prompt text is read from a file rather than passed inline. This avoids the awkwardness
of embedding long multi-line text in a shell argument or an env var value.

### Insertion point: always append

The diff is always appended at the end of the prompt, matching the current built-in behaviour.
No placeholder syntax is introduced — users write only the instruction text.

### stdin / pipe: parked

Supporting `--prompt-file -` (stdin) is a natural Unix extension but is deferred to a
future iteration. The file-based approach covers the primary use case.

## Interface

### CLI flag (takes precedence)

```
-p, --prompt-file <path>    Path to a file containing a custom prompt.
                            The diff is appended after the prompt text.
```

### Environment variable (persistent default)

```
PR_SUMMARISE_PROMPT_FILE=<path>
```

Behaviour: `--prompt-file` overrides `PR_SUMMARISE_PROMPT_FILE`. If neither is set, the
built-in prompt is used (no behaviour change).

### Error handling

- If the specified file does not exist or is not readable, the script exits immediately
  with a clear error message before fetching the diff.

## Example custom prompt file

```
Write a detailed GitHub PR description in Markdown.
Use the following structure:
1. A one-sentence summary.
2. A "## Motivation" section explaining why the change was needed.
3. A "## Changes" section with bullet points.
4. A "## Testing" section describing how to verify the change.
Output only Markdown, nothing else.
```

## Scope

Changes are confined to the single `gh-pr-summarise` script:

- Parse `--prompt-file` / `-p` flag
- Read `PR_SUMMARISE_PROMPT_FILE` env var as fallback default
- Validate the file exists and is readable
- Replace the hardcoded prompt string with the file content (or built-in default)
- Update `usage()` to document the new flag and env var

No new files, no new dependencies.
