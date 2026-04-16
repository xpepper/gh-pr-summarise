## 2024-05-24 - Bash built-in regex matching over subprocesses in loops
**Learning:** In Bash scripts, especially within loops, spawning subprocesses like `grep`, `sed`, `head`, `cut`, or `tr` incurs significant overhead compared to using Bash built-in regular expression matching (`[[ $var =~ regex ]]`). A simple loop with `[[ =~ ]]` took 0.036s compared to 8.637s when using `echo | grep | sed`.
**Action:** When performing string matching and extraction in Bash scripts, prefer using `[[ $var =~ regex ]]` and `${BASH_REMATCH[1]}` over piping to subprocesses.
## $(date +%Y-%m-%d) - Avoiding redundant subshells
**Learning:** Calling an external executable via a subshell (like `$(gh auth token)`) repeatedly inside a retry loop or frequently called function incurs process creation overhead.
**Action:** When a command's output is static for the duration of the script, fetch it once and cache it in a global variable, passing the variable to functions instead of invoking the command inline.
