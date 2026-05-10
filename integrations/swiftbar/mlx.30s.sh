#!/usr/bin/env bash
# <swiftbar.title>MLX Server Control</swiftbar.title>
# <swiftbar.author>Steve</swiftbar.author>
# <swiftbar.desc>Start/stop the local MLX server stack (backend + shim), per-model launchers, log tailing.</swiftbar.desc>
# <swiftbar.version>1.2</swiftbar.version>
# <swiftbar.runInBash>true</swiftbar.runInBash>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

# Refresh cadence: filename suffix .30s = every 30s.
#
# Phase D dual-process model:
#   backend = mlx_lm.server   on 127.0.0.1:64180  (PID: tmp/mlx-<model>.pid)
#   shim    = shim.server     on :64080           (PID: tmp/mlx-shim.pid)
# The plugin reads both PID files (project-local under $PROJECT_DIR/tmp/)
# and verifies liveness with kill -0.
#
# Header convention:
#   - both up    : "MLX 🟢/🟢 <model>"  (1st dot = backend, 2nd dot = shim)
#   - mixed      : "MLX 🟢/⚫"  or  "MLX ⚫/🟢"
#   - both down  : "MLX ⚫"             (single dot, less menu-bar noise)
# Optional gap-count tail: " — N gaps" appended only if gaps.jsonl has >0 lines.
#
# Stale PID files (file exists, kill -0 fails) are reported as stopped here.
# Cleanup is owned by ~/.local/bin/mlx-serve, NOT this plugin.
#
# Terminal handling: SwiftBar's `terminal=true` always launches Terminal.app
# (no Ghostty option in its prefs). Every interactive entry uses
# `terminal=false` and routes through `~/.local/bin/ghostty-run` per
# kb/swiftbar-ghostty.md.

set -u

# Resolve REPO_ROOT from this script's location, following symlinks. SwiftBar
# loads the plugin via a symlink at ~/Library/Application Support/SwiftBar/Plugins/.
__src="${BASH_SOURCE[0]}"
while [ -L "$__src" ]; do
  __dir="$(cd -P "$(dirname "$__src")" >/dev/null 2>&1 && pwd)"
  __src="$(readlink "$__src")"
  case "$__src" in /*) ;; *) __src="$__dir/$__src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$__src")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
unset __src __dir

# Source repo-local .env (untracked) for any local overrides. See .env.example.
if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.env"
  set +a
fi

MLX="${MLX_SERVE_BIN:-$HOME/.local/bin/mlx-serve}"
GR="${GHOSTTY_RUN_BIN:-$HOME/.local/bin/ghostty-run}"
PROJECT_DIR="${MLX_PROJECT_DIR:-$REPO_ROOT}"
TMP_DIR="$PROJECT_DIR/tmp"
SHIM_PID_FILE="$TMP_DIR/mlx-shim.pid"
SHIM_LOG="$TMP_DIR/shim.log"
TRAFFIC_LOG="$TMP_DIR/traffic.jsonl"
GAPS_LOG="$TMP_DIR/gaps.jsonl"
BACKEND_PORT=64180
SHIM_PORT=64080

# is_backend_running -- echo a single status line:
#   "running|<model>|<pid>"  or  "stopped"
# Scans tmp/mlx-*.pid, skips mlx-shim.pid, returns the first live one.
# Stale PID files (process dead) are silently skipped here; the launcher
# owns cleanup.
is_backend_running() {
  local f base name pid
  for f in "$TMP_DIR"/mlx-*.pid; do
    [ -e "$f" ] || continue
    [ "$f" = "$SHIM_PID_FILE" ] && continue
    base=$(basename "$f" .pid)
    name="${base#mlx-}"
    pid=$(cat "$f" 2>/dev/null)
    [ -z "$pid" ] && continue
    if kill -0 "$pid" 2>/dev/null; then
      echo "running|$name|$pid"
      return 0
    fi
  done
  echo "stopped"
}

# is_shim_running -- echo a single status line:
#   "running|<pid>"  or  "stopped"
is_shim_running() {
  local pid
  [ -f "$SHIM_PID_FILE" ] || { echo "stopped"; return 0; }
  pid=$(cat "$SHIM_PID_FILE" 2>/dev/null)
  [ -z "$pid" ] && { echo "stopped"; return 0; }
  if kill -0 "$pid" 2>/dev/null; then
    echo "running|$pid"
    return 0
  fi
  echo "stopped"
}

BACKEND_STATUS=$(is_backend_running)
SHIM_STATUS=$(is_shim_running)

# Parse backend status with cut (bash 3.2-safe; no read-with-IFS arrays).
case "$BACKEND_STATUS" in
  running*)
    BACKEND_UP=1
    BACKEND_MODEL=$(echo "$BACKEND_STATUS" | cut -d'|' -f2)
    BACKEND_PID=$(echo "$BACKEND_STATUS" | cut -d'|' -f3)
    ;;
  *)
    BACKEND_UP=0
    BACKEND_MODEL=""
    BACKEND_PID=""
    ;;
esac

case "$SHIM_STATUS" in
  running*)
    SHIM_UP=1
    SHIM_PID=$(echo "$SHIM_STATUS" | cut -d'|' -f2)
    ;;
  *)
    SHIM_UP=0
    SHIM_PID=""
    ;;
esac

# ---- Header --------------------------------------------------------------
HEADER="MLX"
if [ "$BACKEND_UP" -eq 1 ] && [ "$SHIM_UP" -eq 1 ]; then
  HEADER="$HEADER 🟢/🟢 $BACKEND_MODEL"
elif [ "$BACKEND_UP" -eq 1 ] && [ "$SHIM_UP" -eq 0 ]; then
  HEADER="$HEADER 🟢/⚫ $BACKEND_MODEL"
elif [ "$BACKEND_UP" -eq 0 ] && [ "$SHIM_UP" -eq 1 ]; then
  HEADER="$HEADER ⚫/🟢"
else
  # Both down: single dot to keep the menu bar uncluttered.
  HEADER="$HEADER ⚫"
fi

# Optional gap-count tail. Skip silently when file is missing or empty.
if [ -f "$GAPS_LOG" ]; then
  GAP_COUNT=$(wc -l < "$GAPS_LOG" 2>/dev/null | tr -d ' ')
  case "$GAP_COUNT" in
    ''|0) : ;;
    *) HEADER="$HEADER — $GAP_COUNT gaps" ;;
  esac
fi

echo "$HEADER"
echo "---"

# ---- Status block --------------------------------------------------------
if [ "$BACKEND_UP" -eq 1 ]; then
  echo "Backend :${BACKEND_PORT}  running (pid ${BACKEND_PID}, ${BACKEND_MODEL}) | color=green"
else
  echo "Backend :${BACKEND_PORT}  stopped | color=gray"
fi
if [ "$SHIM_UP" -eq 1 ]; then
  echo "Shim    :${SHIM_PORT}  running (pid ${SHIM_PID}) | color=green"
else
  echo "Shim    :${SHIM_PORT}  stopped | color=gray"
fi

# ---- Stop both -----------------------------------------------------------
# `--stop` is fast and silent (kills both, removes both PID files); no
# Ghostty needed.
if [ "$BACKEND_UP" -eq 1 ] || [ "$SHIM_UP" -eq 1 ]; then
  echo "Stop both | bash='$MLX' param1='--stop' terminal=false refresh=true"
fi

# ---- Tail rows (only meaningful when something is up) -------------------
if [ "$BACKEND_UP" -eq 1 ] || [ "$SHIM_UP" -eq 1 ]; then
  echo "---"
  if [ "$BACKEND_UP" -eq 1 ]; then
    BACKEND_LOG="$TMP_DIR/mlx-${BACKEND_MODEL}.log"
    if [ -f "$BACKEND_LOG" ]; then
      echo "Tail backend log (${BACKEND_MODEL}) | bash='$GR' param1='/usr/bin/tail' param2='-F' param3='$BACKEND_LOG' terminal=false"
    fi
  fi
  if [ "$SHIM_UP" -eq 1 ] && [ -f "$SHIM_LOG" ]; then
    echo "Tail shim log | bash='$GR' param1='/usr/bin/tail' param2='-F' param3='$SHIM_LOG' terminal=false"
  fi
  if [ -f "$TRAFFIC_LOG" ]; then
    echo "Tail traffic.jsonl | bash='$GR' param1='/usr/bin/tail' param2='-F' param3='$TRAFFIC_LOG' terminal=false"
  fi
  if [ -f "$GAPS_LOG" ]; then
    echo "Tail gaps.jsonl | bash='$GR' param1='/usr/bin/tail' param2='-F' param3='$GAPS_LOG' terminal=false"
  fi
fi

echo "---"
echo "Single-model launchers (auto-stops any running stack)"

# ---- Per-model entries (must mirror MODELS in mlx-serve) ----------------
print_model_entry() {
  local key="$1" label="$2" note="$3"
  local log="$TMP_DIR/mlx-${key}.log"
  echo "${label}"
  echo "-- Description: ${note}"
  echo "-- Start [${key}] | bash='$GR' param1='$MLX' param2='${key}' terminal=false refresh=true"
  if [ -f "$log" ]; then
    local size
    size=$(du -h "$log" 2>/dev/null | cut -f1)
    echo "-- Tail log (${size}) | bash='$GR' param1='/usr/bin/tail' param2='-n' param3='200' param4='-F' param5='${log}' terminal=false"
    echo "-- Open log in TextEdit | bash='/usr/bin/open' param1='-a' param2='TextEdit' param3='${log}' terminal=false"
  else
    echo "-- (no log yet) | color=gray"
  fi
}

print_model_entry "scout"          "Llama 4 Scout (17B/109B MoE, ~61GB)" "Top all-rounder, 10M context, vision-capable"
print_model_entry "mistral-medium" "Mistral Medium 3.5 (128B dense, ~73GB)" "Frontier dense, 256K context, supersedes Devstral"
print_model_entry "gemma-31b"      "Gemma 4 31B Dense OptiQ (~16GB)" "Apple-Silicon-optimized mixed precision"
print_model_entry "gemma-26b-moe"  "Gemma 4 26B A4B MoE OptiQ (~14GB)" "4B active params, fastest tok/s, 256K context"

echo "---"
MACMON=$(command -v macmon || echo "/opt/homebrew/bin/macmon")
if [ -x "$MACMON" ]; then
  echo "Open GPU/power monitor (macmon) | bash='$GR' param1='$MACMON' terminal=false"
fi
echo "Open config | bash='/usr/bin/open' param1='-a' param2='TextEdit' param3='$HOME/.config/mlx-lm/config.yaml' terminal=false"
echo "Open repo ($(basename "$PROJECT_DIR")) | bash='/usr/bin/open' param1='$PROJECT_DIR' terminal=false"
echo "Refresh | refresh=true"
