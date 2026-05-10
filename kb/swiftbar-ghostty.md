# SwiftBar + Ghostty terminal handling

## The gotcha

SwiftBar's `terminal=true` plugin parameter **always launches Terminal.app**. It ignores the system LaunchServices default. There is no built-in option in SwiftBar Preferences to point it at Ghostty (or iTerm, or anything else).

Setting Ghostty as the LaunchServices default for `public.unix-executable` (via `defaults write com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers ...`) does *not* help here, because SwiftBar bypasses LaunchServices.

## Workaround

All interactive plugin entries set `terminal=false` and route through `~/.local/bin/ghostty-run`:

```bash
#!/bin/bash
# ~/.local/bin/ghostty-run CMD [ARGS...]
exec /usr/bin/open -na Ghostty.app --args -e "$@"
```

Ghostty's `-e` follows the xterm convention — it consumes the rest of argv as the command and its arguments. So `open -na Ghostty.app --args -e /path/to/cmd arg1 arg2` runs `cmd arg1 arg2` in a new Ghostty window.

In the SwiftBar plugin, an entry looks like:

```
Start [gemma-26b-moe] | bash='~/.local/bin/ghostty-run' param1='~/.local/bin/mlx-serve' param2='gemma-26b-moe' terminal=false refresh=true
```

`terminal=false` keeps SwiftBar from launching Terminal.app; `ghostty-run` opens a new Ghostty window with the real command.

## Diagnosis tip

When a SwiftBar entry "opens nothing," verify two things in order:

1. Is the underlying command crashing? Tail `/tmp/mlx-*.log` — many silent failures here are argparse errors with stdout/stderr already redirected.
2. Is SwiftBar actually launching a terminal at all? With `terminal=true`, expect Terminal.app to flash. If it flashes-and-closes, see (1).
