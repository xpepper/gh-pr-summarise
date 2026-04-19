## 2024-05-24 - Bash built-in regex matching over subprocesses in loops
**Learning:** In Bash scripts, especially within loops, spawning subprocesses like `grep`, `sed`, `head`, `cut`, or `tr` incurs significant overhead compared to using Bash built-in regular expression matching (`[[ $var =~ regex ]]`). A simple loop with `[[ =~ ]]` took 0.036s compared to 8.637s when using `echo | grep | sed`.
**Action:** When performing string matching and extraction in Bash scripts, prefer using `[[ $var =~ regex ]]` and `${BASH_REMATCH[1]}` over piping to subprocesses.

## 2026-04-19 - Expensive external CLI command cache
**Learning:** In Bash scripts, especially within loops, spawning subprocesses like `gh auth token` multiple times incurs significant overhead. Caching the result in a global variable improves performance.
**Action:** Extract expensive external CLI command calls like `gh auth token` to a global variable after argument parsing and before loops or function definitions to prevent repeatedly spawning subprocesses.
