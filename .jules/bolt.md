## 2024-05-24 - Bash built-in regex matching over subprocesses in loops
**Learning:** In Bash scripts, especially within loops, spawning subprocesses like `grep`, `sed`, `head`, `cut`, or `tr` incurs significant overhead compared to using Bash built-in regular expression matching (`[[ $var =~ regex ]]`). A simple loop with `[[ =~ ]]` took 0.036s compared to 8.637s when using `echo | grep | sed`.
**Action:** When performing string matching and extraction in Bash scripts, prefer using `[[ $var =~ regex ]]` and `${BASH_REMATCH[1]}` over piping to subprocesses.
## 2024-05-24 - Cache subshell outputs for external commands in Bash
**Learning:** Calling external commands like `gh auth token` dynamically inside functions via subshells (e.g. `$(gh auth token)`) can introduce noticeable overhead, especially when these functions are called repeatedly in retry loops or fallback chains.
**Action:** Always fetch and cache the output of static or long-lived external commands into global variables at script startup, and use these variables instead of spawning subshells inside frequently executed functions.
