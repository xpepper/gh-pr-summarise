# Roadmap

Planned improvements, roughly in priority order.

## Spinner during API call

Show an animated spinner on stderr between "Generating summary…" and the result. The GitHub Models call takes 3–5 seconds; the spinner makes the wait feel acknowledged. Suppress it when stdout is not a TTY (i.e. when piped or used with `--yes` in scripts).
