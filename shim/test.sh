#!/usr/bin/env bash
# shim/test.sh — Phase F live e2e for the mlx-server shim stack.
#
# No mocks, no stubs. Live against real models loaded by mlx_lm.server. Per
# the repo CLAUDE.md: "All testing is live e2e against real models. Failure
# modes that can't be live-induced are deliberately not tested; we discover
# them through gaps.jsonl in real traffic."
#
# Nine sections, each PASS/FAIL with explicit assertions:
#   1. Setup + readiness
#   2. Non-streaming chat (validates enable_thinking:false + paired traffic)
#   3. Streaming chat (validates SSE relay + paired stream_open/close)
#   4. Unknown field (validates allowlist gap_capture)
#   5. Unknown path (validates catch-all gap)
#   6. Header redaction smoke (validates Authorization + Cookie masked in traffic.jsonl)
#   7. Backend killed mid-flight (validates premature stream termination is visible)
#   8. Backend down on startup (validates backend_down + 503)
#   9. Four-model load cycle (validates per-model dispatch + Scout patch)
#
# Bash 3.2 compatible. set -uo pipefail (NOT -e — we want every section to
# run and report). Trap on EXIT|INT|TERM cleans up processes regardless of
# how the script exits.

set -uo pipefail

# Resolve REPO_ROOT from this script's location, following symlinks.
__src="${BASH_SOURCE[0]}"
while [ -L "$__src" ]; do
  __dir="$(cd -P "$(dirname "$__src")" >/dev/null 2>&1 && pwd)"
  __src="$(readlink "$__src")"
  case "$__src" in /*) ;; *) __src="$__dir/$__src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$__src")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
unset __src __dir

# Source repo-local .env (untracked) for any local overrides. See .env.example.
if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.env"
  set +a
fi

# --- paths and config ------------------------------------------------------

MLX_PROJECT_DIR="${MLX_PROJECT_DIR:-$REPO_ROOT}"
TMP_DIR="$MLX_PROJECT_DIR/tmp"
TRAFFIC_LOG="$TMP_DIR/traffic.jsonl"
GAPS_LOG="$TMP_DIR/gaps.jsonl"
SUMMARY_FILE="$TMP_DIR/test-summary.txt"
SHIM_LOG="$TMP_DIR/shim.log"

MLX_SERVE="${MLX_SERVE_BIN:-$HOME/.local/bin/mlx-serve}"
VENV_PY="${VENV_DIR:-$HOME/.venvs/mlx}/bin/python"
SHIM_PORT="64080"
BACKEND_PORT="64180"
SHIM_BASE="http://127.0.0.1:$SHIM_PORT"
BACKEND_URL="http://127.0.0.1:$BACKEND_PORT"

# Section 8 model order. Cheapest/most-reliable first; Scout last because it
# is the one we expect to be flaky.
LOAD_CYCLE_MODELS="gemma-26b-moe gemma-31b mistral-medium scout"

# Cold-cache loads can take minutes. Allow override.
export MLX_BACKEND_READY_TIMEOUT="${MLX_BACKEND_READY_TIMEOUT:-600}"

# Track overall pass/fail.
OVERALL_FAIL=0

# Section results captured for the summary file. Each entry is
# "<section>|<status>|<note>". One per line in $SECTION_RESULTS_FILE so we
# don't have to deal with bash 3.2 array escaping for arbitrary text.
SECTION_RESULTS_FILE=""

# --- output helpers --------------------------------------------------------

log() {
  printf '[test] %s\n' "$*"
}

pass() {
  local name="$1"
  local note="${2:-}"
  printf '[PASS] %s' "$name"
  if [ -n "$note" ]; then
    printf ' — %s' "$note"
  fi
  printf '\n'
  if [ -n "$SECTION_RESULTS_FILE" ]; then
    printf '%s|PASS|%s\n' "$name" "$note" >> "$SECTION_RESULTS_FILE"
  fi
}

fail() {
  local name="$1"
  local note="${2:-}"
  printf '[FAIL] %s' "$name"
  if [ -n "$note" ]; then
    printf ' — %s' "$note"
  fi
  printf '\n'
  OVERALL_FAIL=1
  if [ -n "$SECTION_RESULTS_FILE" ]; then
    printf '%s|FAIL|%s\n' "$name" "$note" >> "$SECTION_RESULTS_FILE"
  fi
}

# --- cleanup trap ----------------------------------------------------------

# We track standalone shim PID separately for section 8. The mlx-serve
# launcher owns its own PID files for the normal case.
STANDALONE_SHIM_PID=""

cleanup() {
  # Run on every exit path. Idempotent.
  if [ -n "$STANDALONE_SHIM_PID" ]; then
    kill -TERM "$STANDALONE_SHIM_PID" 2>/dev/null || true
    # brief wait
    local i=0
    while [ "$i" -lt 10 ]; do
      kill -0 "$STANDALONE_SHIM_PID" 2>/dev/null || break
      sleep 0.2
      i=$(( i + 1 ))
    done
    kill -KILL "$STANDALONE_SHIM_PID" 2>/dev/null || true
    STANDALONE_SHIM_PID=""
  fi
  "$MLX_SERVE" --stop >/dev/null 2>&1 || true
  # Last-resort safety net: if any stray shim.server python is still around
  # (e.g. crashed mid-test before its PID was registered), kill it.
  pkill -f 'shim\.server' >/dev/null 2>&1 || true
  pkill -f 'mlx_lm\.server' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# --- json helpers ----------------------------------------------------------

# Extract message.content from a chat completion JSON body. Empty string if
# missing or unparseable.
json_message_content() {
  jq -r '.choices[0].message.content // ""' 2>/dev/null
}

# --- traffic.jsonl helpers -------------------------------------------------

# Most recent JSONL line in $1 matching grep pattern $2 (literal).
last_line_with() {
  local file="$1"
  local pat="$2"
  [ -f "$file" ] || { echo ""; return; }
  grep -F "$pat" "$file" 2>/dev/null | tail -1
}

# Most-recent dir:"in" entry's request_id, optionally matching path $2.
last_in_request_id() {
  local path_pat="${1:-}"
  if [ -n "$path_pat" ]; then
    grep -F '"dir": "in"' "$TRAFFIC_LOG" 2>/dev/null \
      | grep -F "\"path\": \"$path_pat\"" \
      | tail -1 \
      | jq -r '.request_id // ""' 2>/dev/null
  else
    grep -F '"dir": "in"' "$TRAFFIC_LOG" 2>/dev/null \
      | tail -1 \
      | jq -r '.request_id // ""' 2>/dev/null
  fi
}

# Count lines in $1 matching ALL of the literal patterns in $2..
# Implements a chained -F grep without eval (the patterns can contain
# embedded double-quotes, which break naive eval-based command building).
count_lines_matching() {
  local file="$1"; shift
  [ -f "$file" ] || { echo 0; return; }
  local tmp_a tmp_b
  tmp_a="$TMP_DIR/.grep-chain.a.$$"
  tmp_b="$TMP_DIR/.grep-chain.b.$$"
  cp "$file" "$tmp_a" 2>/dev/null || { echo 0; return; }
  while [ "$#" -gt 0 ]; do
    grep -F "$1" "$tmp_a" > "$tmp_b" 2>/dev/null || true
    mv "$tmp_b" "$tmp_a"
    shift
  done
  local n
  n=$(wc -l < "$tmp_a" 2>/dev/null | tr -d ' ')
  rm -f "$tmp_a" "$tmp_b"
  [ -z "$n" ] && n=0
  echo "$n"
}

# --- setup -----------------------------------------------------------------

setup() {
  log "preparing test environment"

  # Make sure tmp/ exists.
  mkdir -p "$TMP_DIR"

  # Rotate aside any pre-existing logs so the test run starts clean but no
  # real evidence is destroyed.
  local stamp
  stamp=$(date +%Y%m%dT%H%M%S)
  if [ -s "$TRAFFIC_LOG" ]; then
    mv "$TRAFFIC_LOG" "$TMP_DIR/traffic.jsonl.pre-test-$stamp"
    log "rotated traffic.jsonl -> traffic.jsonl.pre-test-$stamp"
  else
    rm -f "$TRAFFIC_LOG"
  fi
  if [ -s "$GAPS_LOG" ]; then
    mv "$GAPS_LOG" "$TMP_DIR/gaps.jsonl.pre-test-$stamp"
    log "rotated gaps.jsonl -> gaps.jsonl.pre-test-$stamp"
  else
    rm -f "$GAPS_LOG"
  fi
  : > "$TRAFFIC_LOG"
  : > "$GAPS_LOG"

  # Also reset the section-results file used to render the summary.
  SECTION_RESULTS_FILE="$TMP_DIR/.test-section-results.$$"
  : > "$SECTION_RESULTS_FILE"

  # Belt-and-braces: stop anything that might still be running.
  "$MLX_SERVE" --stop >/dev/null 2>&1 || true
}

# --- section 1: setup + initial readiness ---------------------------------

section_1_setup() {
  local name="1. setup + initial readiness"
  log "$name"

  # Start gemma-26b-moe (smallest, fastest, most reliable).
  if ! "$MLX_SERVE" gemma-26b-moe > "$TMP_DIR/.section1-launch.log" 2>&1; then
    fail "$name" "mlx-serve gemma-26b-moe failed; see $TMP_DIR/.section1-launch.log"
    return 1
  fi

  # mlx-serve already blocks until both backend and shim are ready, so a
  # quick re-confirm here is all we need.
  if ! curl -fs --max-time 2 "$SHIM_BASE/healthz" > /dev/null 2>&1; then
    fail "$name" "shim /healthz did not respond after launch"
    return 1
  fi
  if ! curl -fs --max-time 2 "$BACKEND_URL/v1/models" > /dev/null 2>&1; then
    fail "$name" "backend /v1/models did not respond after launch"
    return 1
  fi

  # Confirm both ports listening per the launcher's contract.
  local ports_listening
  ports_listening=$(lsof -nP -iTCP:$SHIM_PORT -iTCP:$BACKEND_PORT -sTCP:LISTEN 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
  if [ "$ports_listening" -lt 2 ]; then
    fail "$name" "expected 2 listening ports ($SHIM_PORT + $BACKEND_PORT), found $ports_listening"
    return 1
  fi

  pass "$name" "backend+shim up; ports $SHIM_PORT + $BACKEND_PORT listening"
  return 0
}

# --- section 2: non-streaming chat ---------------------------------------

section_2_nonstream() {
  local name="2. non-streaming chat"
  log "$name"

  local model_path
  model_path=$(hf_path_for "gemma-26b-moe")
  local before_lines
  before_lines=$(wc -l < "$TRAFFIC_LOG" 2>/dev/null | tr -d ' ')

  local resp_file="$TMP_DIR/.section2-resp.json"
  local hdr_file="$TMP_DIR/.section2-resp.hdr"
  local http_status
  http_status=$(curl -s -o "$resp_file" -D "$hdr_file" -w '%{http_code}' \
    --max-time 120 \
    "$SHIM_BASE/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$model_path\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one short sentence.\"}],\"max_tokens\":32}")

  if [ "$http_status" != "200" ]; then
    fail "$name" "expected HTTP 200, got $http_status; body: $(head -c 300 "$resp_file" 2>/dev/null)"
    return 1
  fi

  local content
  content=$(json_message_content < "$resp_file")
  if [ -z "$content" ]; then
    fail "$name" "empty message.content (validates enable_thinking:false defaults)"
    return 1
  fi

  # Pick up the most-recent in-traffic entry on /v1/chat/completions.
  local rid
  rid=$(last_in_request_id "/v1/chat/completions")
  if [ -z "$rid" ]; then
    fail "$name" "could not find request_id in traffic.jsonl"
    return 1
  fi

  # Independent header check — traffic.jsonl alone wouldn't catch a
  # Starlette MutableHeaders write-trap regression.
  local hdr_rid
  hdr_rid=$(grep -i '^x-shim-request-id:' "$hdr_file" 2>/dev/null | tr -d '\r' | awk '{print $2}' | tail -1)
  if [ -z "$hdr_rid" ]; then
    fail "$name" "response missing x-shim-request-id header"
    return 1
  fi
  if [ "$hdr_rid" != "$rid" ]; then
    fail "$name" "x-shim-request-id mismatch: header=$hdr_rid traffic=$rid"
    return 1
  fi

  local in_count out_count gap_count
  in_count=$(count_lines_matching "$TRAFFIC_LOG" "\"request_id\": \"$rid\"" "\"dir\": \"in\"")
  out_count=$(count_lines_matching "$TRAFFIC_LOG" "\"request_id\": \"$rid\"" "\"dir\": \"out\"")
  gap_count=$(count_lines_matching "$GAPS_LOG" "\"request_id\": \"$rid\"")

  if [ "$in_count" != "1" ] || [ "$out_count" != "1" ]; then
    fail "$name" "expected 1 in + 1 out for $rid; got in=$in_count out=$out_count"
    return 1
  fi
  if [ "$gap_count" != "0" ]; then
    fail "$name" "expected 0 gaps for $rid; got $gap_count"
    return 1
  fi

  pass "$name" "rid=$rid in=$in_count out=$out_count gaps=0 content=\"$(printf '%s' "$content" | head -c 60)\""
  return 0
}

# --- section 3: streaming chat -------------------------------------------

section_3_stream() {
  local name="3. streaming chat"
  log "$name"

  local model_path
  model_path=$(hf_path_for "gemma-26b-moe")
  local resp_file="$TMP_DIR/.section3-resp.txt"
  local hdr_file="$TMP_DIR/.section3-resp.hdr"

  curl -sN --max-time 120 -D "$hdr_file" \
    "$SHIM_BASE/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$model_path\",\"messages\":[{\"role\":\"user\",\"content\":\"Count to five.\"}],\"max_tokens\":80,\"stream\":true}" \
    > "$resp_file" 2>&1

  if [ ! -s "$resp_file" ]; then
    fail "$name" "no SSE bytes received"
    return 1
  fi

  if ! grep -q '^data:' "$resp_file"; then
    fail "$name" "no 'data:' lines in SSE response"
    return 1
  fi

  if ! grep -q '^data: \[DONE\]' "$resp_file"; then
    fail "$name" "SSE response missing terminal 'data: [DONE]'"
    return 1
  fi

  # Most-recent stream_open in traffic.jsonl is ours.
  local open_line rid
  open_line=$(last_line_with "$TRAFFIC_LOG" '"kind": "stream_open"')
  if [ -z "$open_line" ]; then
    fail "$name" "no stream_open entry in traffic.jsonl"
    return 1
  fi
  rid=$(printf '%s' "$open_line" | jq -r '.request_id // ""' 2>/dev/null)
  if [ -z "$rid" ]; then
    fail "$name" "could not parse request_id from stream_open"
    return 1
  fi

  # Independent header check — traffic.jsonl alone wouldn't catch a
  # Starlette MutableHeaders write-trap regression.
  local hdr_rid
  hdr_rid=$(grep -i '^x-shim-request-id:' "$hdr_file" 2>/dev/null | tr -d '\r' | awk '{print $2}' | tail -1)
  if [ -z "$hdr_rid" ]; then
    fail "$name" "response missing x-shim-request-id header"
    return 1
  fi
  if [ "$hdr_rid" != "$rid" ]; then
    fail "$name" "x-shim-request-id mismatch: header=$hdr_rid traffic=$rid"
    return 1
  fi

  local open_count close_count gap_count
  open_count=$(count_lines_matching "$TRAFFIC_LOG" "\"request_id\": \"$rid\"" '"kind": "stream_open"')
  close_count=$(count_lines_matching "$TRAFFIC_LOG" "\"request_id\": \"$rid\"" '"kind": "stream_close"')
  gap_count=$(count_lines_matching "$GAPS_LOG" "\"request_id\": \"$rid\"")

  if [ "$open_count" != "1" ] || [ "$close_count" != "1" ]; then
    fail "$name" "expected 1 stream_open + 1 stream_close for $rid; got open=$open_count close=$close_count"
    return 1
  fi
  if [ "$gap_count" != "0" ]; then
    fail "$name" "expected 0 gaps for $rid; got $gap_count"
    return 1
  fi

  pass "$name" "rid=$rid stream_open=$open_count stream_close=$close_count gaps=0"
  return 0
}

# --- section 4: unknown field --------------------------------------------

section_4_unknown_field() {
  local name="4. unknown field"
  log "$name"

  local model_path
  model_path=$(hf_path_for "gemma-26b-moe")
  local resp_file="$TMP_DIR/.section4-resp.json"
  local http_status
  http_status=$(curl -s -o "$resp_file" -w '%{http_code}' \
    --max-time 60 \
    "$SHIM_BASE/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$model_path\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":16,\"foo\":42}")

  if [ "$http_status" != "200" ]; then
    fail "$name" "expected HTTP 200 (unknown field is logged but doesn't break the call); got $http_status"
    return 1
  fi

  # Most-recent unknown_field gap on field "foo" is ours.
  local gap_line rid
  gap_line=$(grep -F '"kind": "unknown_field"' "$GAPS_LOG" 2>/dev/null \
    | grep -F '"field": "foo"' \
    | tail -1)
  if [ -z "$gap_line" ]; then
    fail "$name" "no kind:unknown_field gap with field:foo found"
    return 1
  fi
  rid=$(printf '%s' "$gap_line" | jq -r '.request_id // ""' 2>/dev/null)
  if [ -z "$rid" ]; then
    fail "$name" "could not parse request_id from unknown_field gap"
    return 1
  fi

  # Same request_id should appear in traffic.jsonl as in + out.
  local in_count out_count
  in_count=$(count_lines_matching "$TRAFFIC_LOG" "\"request_id\": \"$rid\"" '"dir": "in"')
  out_count=$(count_lines_matching "$TRAFFIC_LOG" "\"request_id\": \"$rid\"" '"dir": "out"')

  if [ "$in_count" != "1" ] || [ "$out_count" != "1" ]; then
    fail "$name" "expected paired in/out for $rid; got in=$in_count out=$out_count"
    return 1
  fi

  pass "$name" "rid=$rid gap=unknown_field/foo + in=$in_count out=$out_count"
  return 0
}

# --- section 5: unknown path ---------------------------------------------

section_5_unknown_path() {
  local name="5. unknown path"
  log "$name"

  local resp_file="$TMP_DIR/.section5-resp.json"
  local http_status
  http_status=$(curl -s -o "$resp_file" -w '%{http_code}' \
    --max-time 10 \
    "$SHIM_BASE/v1/embeddings/garbage")

  if [ "$http_status" != "404" ]; then
    fail "$name" "expected HTTP 404, got $http_status"
    return 1
  fi

  local gap_line rid
  gap_line=$(grep -F '"kind": "unknown_path"' "$GAPS_LOG" 2>/dev/null \
    | grep -F '"path": "/v1/embeddings/garbage"' \
    | tail -1)
  if [ -z "$gap_line" ]; then
    fail "$name" "no kind:unknown_path gap for /v1/embeddings/garbage"
    return 1
  fi
  rid=$(printf '%s' "$gap_line" | jq -r '.request_id // ""' 2>/dev/null)
  if [ -z "$rid" ]; then
    fail "$name" "could not parse request_id from unknown_path gap"
    return 1
  fi

  pass "$name" "rid=$rid path=/v1/embeddings/garbage status=404"
  return 0
}

# --- section 6: header redaction smoke -----------------------------------

section_6_header_redaction() {
  local name="6. header redaction smoke"
  log "$name"

  # Probe 1: Authorization header — secret must NOT appear; redacted entry must.
  curl -sS -o /dev/null --max-time 10 \
    "$SHIM_BASE/v1/models" \
    -H 'Authorization: Bearer sk-secretvalue'

  if grep -qF 'sk-secretvalue' "$TRAFFIC_LOG" 2>/dev/null; then
    fail "$name" "Authorization secret 'sk-secretvalue' found unredacted in traffic.jsonl"
    return 1
  fi
  if ! grep -qF 'authorization' "$TRAFFIC_LOG" 2>/dev/null; then
    fail "$name" "no 'authorization' key found in traffic.jsonl — request may not have been logged"
    return 1
  fi

  # Probe 2: Cookie header — secret must NOT appear; redacted entry must.
  curl -sS -o /dev/null --max-time 10 \
    "$SHIM_BASE/v1/models" \
    -H 'Cookie: session=topsecret'

  if grep -qF 'topsecret' "$TRAFFIC_LOG" 2>/dev/null; then
    fail "$name" "Cookie secret 'topsecret' found unredacted in traffic.jsonl"
    return 1
  fi
  if ! grep -qF 'cookie' "$TRAFFIC_LOG" 2>/dev/null; then
    fail "$name" "no 'cookie' key found in traffic.jsonl — request may not have been logged"
    return 1
  fi

  pass "$name" "Authorization + Cookie secrets absent; redacted keys present in traffic.jsonl"
  return 0
}

# --- section 7: backend killed mid-flight --------------------------------

section_7_backend_killed_midflight() {
  local name="7. backend killed mid-flight"
  log "$name"

  # Find current backend PID file.
  local pid_file
  pid_file=$(ls "$TMP_DIR"/mlx-*.pid 2>/dev/null | grep -v 'mlx-shim\.pid' | head -1)
  if [ -z "$pid_file" ] || [ ! -f "$pid_file" ]; then
    fail "$name" "no backend PID file found"
    return 1
  fi
  local backend_pid
  backend_pid=$(cat "$pid_file" 2>/dev/null)
  if [ -z "$backend_pid" ]; then
    fail "$name" "backend PID file empty: $pid_file"
    return 1
  fi

  local model_path
  model_path=$(hf_path_for "gemma-26b-moe")
  local resp_file="$TMP_DIR/.section7-resp.txt"

  # Start a long streaming chat in the background.
  ( curl -sN --max-time 120 \
      "$SHIM_BASE/v1/chat/completions" \
      -H 'content-type: application/json' \
      -d "{\"model\":\"$model_path\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a long detailed essay about the history of computing. At least 1500 words.\"}],\"max_tokens\":2000,\"stream\":true}" \
      > "$resp_file" 2>&1 ) &
  local curl_pid=$!

  # Let the stream warm up — we want to be MID-flight when we kill the backend.
  sleep 5

  # Kill the backend.
  log "  killing backend pid $backend_pid mid-flight"
  kill -KILL "$backend_pid" 2>/dev/null || true

  # Wait for the curl to exit (with a sanity ceiling).
  local i=0
  while [ "$i" -lt 60 ]; do
    kill -0 "$curl_pid" 2>/dev/null || break
    sleep 0.5
    i=$(( i + 1 ))
  done
  kill -KILL "$curl_pid" 2>/dev/null || true
  wait "$curl_pid" 2>/dev/null || true

  # Give the shim a moment to finalize its close-time logging.
  sleep 1

  # Find the most-recent stream_open's request_id (the one we just made).
  local open_line rid
  open_line=$(last_line_with "$TRAFFIC_LOG" '"kind": "stream_open"')
  if [ -z "$open_line" ]; then
    fail "$name" "no stream_open entry found in traffic.jsonl"
    return 1
  fi
  rid=$(printf '%s' "$open_line" | jq -r '.request_id // ""' 2>/dev/null)
  if [ -z "$rid" ]; then
    fail "$name" "could not parse request_id from stream_open"
    return 1
  fi

  # Primary assertion (per Phase B docs): stream_close body does NOT end with
  # 'data: [DONE]' (premature termination).
  # Fallback: a kind:stream_error gap is present on the same request_id.
  local close_line close_body
  close_line=$(grep -F "\"request_id\": \"$rid\"" "$TRAFFIC_LOG" 2>/dev/null \
    | grep -F '"kind": "stream_close"' \
    | tail -1)
  if [ -z "$close_line" ]; then
    fail "$name" "no stream_close entry for $rid"
    return 1
  fi
  close_body=$(printf '%s' "$close_line" | jq -r '.body // ""' 2>/dev/null)

  local has_done="0"
  if printf '%s' "$close_body" | grep -q 'data: \[DONE\]'; then
    has_done="1"
  fi

  local stream_error_count
  stream_error_count=$(count_lines_matching "$GAPS_LOG" "\"request_id\": \"$rid\"" '"kind": "stream_error"')

  if [ "$has_done" = "0" ] || [ "$stream_error_count" -ge 1 ]; then
    local note="rid=$rid has_DONE=$has_done stream_error_gaps=$stream_error_count"
    pass "$name" "$note"
    # Restart backend before the next section.
    log "  restarting backend"
    "$MLX_SERVE" --stop >/dev/null 2>&1 || true
    if ! "$MLX_SERVE" gemma-26b-moe > "$TMP_DIR/.section7-restart.log" 2>&1; then
      fail "$name (restart)" "could not restart backend; see $TMP_DIR/.section7-restart.log"
      return 1
    fi
    return 0
  fi

  fail "$name" "stream completed cleanly with [DONE] AND no stream_error gap — backend kill not visible (may be a timing race — try increasing the prompt length or reducing the kill delay)"
  return 1
}

# --- section 8: backend down on startup ----------------------------------

section_8_backend_down() {
  local name="8. backend down on startup"
  log "$name"

  # Stop everything.
  "$MLX_SERVE" --stop >/dev/null 2>&1 || true
  sleep 1

  # Confirm backend port is free.
  if lsof -nP -iTCP:$BACKEND_PORT -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
    fail "$name" "backend port $BACKEND_PORT still listening after --stop"
    return 1
  fi

  # Start standalone shim (no backend behind it).
  log "  starting standalone shim with no backend"
  ( cd "$MLX_PROJECT_DIR" && \
    MLX_BACKEND_URL="$BACKEND_URL" \
    MLX_SHIM_PORT="$SHIM_PORT" \
    "$VENV_PY" -m aeo_mlx_lab.shim.server > "$TMP_DIR/.section8-shim.log" 2>&1 ) &
  STANDALONE_SHIM_PID=$!

  # Wait for shim to come up.
  local i=0
  local up=0
  while [ "$i" -lt 20 ]; do
    if curl -fs --max-time 1 "$SHIM_BASE/healthz" > /dev/null 2>&1; then
      up=1
      break
    fi
    sleep 0.5
    i=$(( i + 1 ))
  done
  if [ "$up" != "1" ]; then
    fail "$name" "standalone shim did not come up; tail of log:"
    tail -n 20 "$TMP_DIR/.section8-shim.log" >&2 2>/dev/null || true
    return 1
  fi

  # Send a chat — should 503 because backend is down.
  local resp_file="$TMP_DIR/.section8-resp.json"
  local http_status
  http_status=$(curl -s -o "$resp_file" -w '%{http_code}' \
    --max-time 10 \
    "$SHIM_BASE/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d '{"model":"x","messages":[{"role":"user","content":"hi"}],"max_tokens":4}')

  if [ "$http_status" != "503" ]; then
    fail "$name" "expected HTTP 503, got $http_status; body: $(head -c 200 "$resp_file" 2>/dev/null)"
    # tear down standalone shim before returning
    kill -TERM "$STANDALONE_SHIM_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$STANDALONE_SHIM_PID" 2>/dev/null || true
    STANDALONE_SHIM_PID=""
    return 1
  fi

  # Look for the matching backend_down gap.
  local gap_line rid
  gap_line=$(last_line_with "$GAPS_LOG" '"kind": "backend_down"')
  if [ -z "$gap_line" ]; then
    fail "$name" "no kind:backend_down gap entry"
    kill -TERM "$STANDALONE_SHIM_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$STANDALONE_SHIM_PID" 2>/dev/null || true
    STANDALONE_SHIM_PID=""
    return 1
  fi
  rid=$(printf '%s' "$gap_line" | jq -r '.request_id // ""' 2>/dev/null)

  # Tear down the standalone shim.
  log "  stopping standalone shim"
  kill -TERM "$STANDALONE_SHIM_PID" 2>/dev/null || true
  i=0
  while [ "$i" -lt 10 ]; do
    kill -0 "$STANDALONE_SHIM_PID" 2>/dev/null || break
    sleep 0.2
    i=$(( i + 1 ))
  done
  kill -KILL "$STANDALONE_SHIM_PID" 2>/dev/null || true
  STANDALONE_SHIM_PID=""

  pass "$name" "rid=$rid status=503 backend_down gap recorded"
  return 0
}

# --- section 9: four-model load cycle ------------------------------------

# Capture peak unified memory usage. macOS `ioreg` exposes the kernel-level
# "In use system memory" hex value; we convert and round to GB.
peak_unified_memory_gb() {
  local raw
  raw=$(ioreg -l -w 0 2>/dev/null | grep -E '"In use system memory"' | head -1 \
    | sed -E 's/^.*= 0x([0-9a-fA-F]+).*$/\1/' )
  if [ -z "$raw" ]; then
    # Fallback to vm_stat.
    raw=$(vm_stat 2>/dev/null | awk '/Pages active|Pages wired/ {gsub(/\./,""); s+=$NF} END {printf "%d", s*16384}')
    if [ -z "$raw" ] || [ "$raw" = "0" ]; then
      echo "?"
      return
    fi
    "$VENV_PY" -c "print(round($raw / 1073741824, 1))" 2>/dev/null || echo "?"
    return
  fi
  "$VENV_PY" -c "print(round(int('$raw', 16) / 1073741824, 1))" 2>/dev/null || echo "?"
}

# Run a single non-streaming chat against the shim. Echoes "ok|<content>" or
# "fail|<reason>". Caller parses.
single_chat_probe() {
  local model_path="$1"
  local resp_file="$TMP_DIR/.section9-probe.json"
  local http_status
  http_status=$(curl -s -o "$resp_file" -w '%{http_code}' \
    --max-time 600 \
    "$SHIM_BASE/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$model_path\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word.\"}],\"max_tokens\":16}")
  if [ "$http_status" != "200" ]; then
    echo "fail|HTTP $http_status; body: $(head -c 200 "$resp_file" 2>/dev/null)"
    return
  fi
  local content
  content=$(json_message_content < "$resp_file")
  if [ -z "$content" ]; then
    echo "fail|empty message.content"
    return
  fi
  echo "ok|$content"
}

# Map test name -> hf model_path (mirror of mlx-serve's lookup_model).
hf_path_for() {
  case "$1" in
    scout)          echo "mlx-community/Llama-4-Scout-17B-16E-Instruct-4bit" ;;
    mistral-medium) echo "mlx-community/Mistral-Medium-3.5-128B-4bit" ;;
    gemma-31b)      echo "mlx-community/gemma-4-31B-it-OptiQ-4bit" ;;
    gemma-26b-moe)  echo "mlx-community/gemma-4-26B-A4B-it-OptiQ-4bit" ;;
    *) return 1 ;;
  esac
}

section_9_load_cycle() {
  local name="9. four-model load cycle"
  log "$name"

  # Make sure prior section's stack is fully down before starting.
  "$MLX_SERVE" --stop >/dev/null 2>&1 || true
  sleep 1

  local cycle_fail=0
  local m hf_path probe_result probe_status probe_content peak_gb t_start t_end dur
  for m in $LOAD_CYCLE_MODELS; do
    log "  cycle: $m"
    hf_path=$(hf_path_for "$m")
    if [ -z "$hf_path" ]; then
      fail "$name ($m)" "unknown model name"
      cycle_fail=1
      continue
    fi

    t_start=$(date +%s)
    if ! "$MLX_SERVE" "$m" > "$TMP_DIR/.section9-launch-$m.log" 2>&1; then
      fail "$name ($m)" "mlx-serve $m failed to start; see $TMP_DIR/.section9-launch-$m.log"
      cycle_fail=1
      "$MLX_SERVE" --stop >/dev/null 2>&1 || true
      sleep 2
      continue
    fi
    t_end=$(date +%s)
    dur=$(( t_end - t_start ))

    # CRITICAL for Scout: do NOT trust /v1/models. Probe with a real chat.
    # This validates the four-model cycle as much as it validates the shim.
    probe_result=$(single_chat_probe "$hf_path")
    probe_status="${probe_result%%|*}"
    probe_content="${probe_result#*|}"
    peak_gb=$(peak_unified_memory_gb)

    if [ "$probe_status" = "ok" ]; then
      pass "$name ($m)" "load=${dur}s peak_mem=${peak_gb}GB content=\"$(printf '%s' "$probe_content" | head -c 50)\""
    else
      # Don't abort the script — Scout being broken doesn't invalidate the
      # other three.
      fail "$name ($m)" "load=${dur}s peak_mem=${peak_gb}GB probe failed: $probe_content"
      cycle_fail=1
    fi

    log "  stopping $m"
    "$MLX_SERVE" --stop >/dev/null 2>&1 || true
    sleep 2
  done

  if [ "$cycle_fail" = "0" ]; then
    pass "$name" "all 4 models loaded + responded"
  fi
  return 0
}

# --- summary writer -------------------------------------------------------

write_summary() {
  {
    printf 'mlx-server shim test summary\n'
    printf 'Run: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Project: %s\n' "$MLX_PROJECT_DIR"
    printf 'Skip-load-cycle: %s\n' "${MLX_TEST_SKIP_LOAD_CYCLE:-0}"
    printf 'Overall: %s\n' "$([ "$OVERALL_FAIL" = "0" ] && echo PASS || echo FAIL)"
    printf '\nSections:\n'
    if [ -n "$SECTION_RESULTS_FILE" ] && [ -f "$SECTION_RESULTS_FILE" ]; then
      while IFS='|' read -r sec st note; do
        printf '  [%s] %s' "$st" "$sec"
        if [ -n "$note" ]; then
          printf '  %s' "$note"
        fi
        printf '\n'
      done < "$SECTION_RESULTS_FILE"
    fi
    printf '\nLog files:\n'
    printf '  traffic: %s (%s lines)\n' "$TRAFFIC_LOG" "$(wc -l < "$TRAFFIC_LOG" 2>/dev/null | tr -d ' ')"
    printf '  gaps:    %s (%s lines)\n' "$GAPS_LOG"    "$(wc -l < "$GAPS_LOG" 2>/dev/null | tr -d ' ')"
  } > "$SUMMARY_FILE"
  log "wrote summary to $SUMMARY_FILE"
}

# --- main -----------------------------------------------------------------

main() {
  setup

  section_1_setup       || true
  section_2_nonstream   || true
  section_3_stream      || true
  section_4_unknown_field || true
  section_5_unknown_path  || true
  section_6_header_redaction || true
  section_7_backend_killed_midflight || true
  section_8_backend_down  || true

  if [ "${MLX_TEST_SKIP_LOAD_CYCLE:-0}" = "1" ]; then
    log "skipping section 9 (MLX_TEST_SKIP_LOAD_CYCLE=1)"
  else
    section_9_load_cycle || true
  fi

  write_summary

  # Clean up our scratch result file.
  if [ -n "$SECTION_RESULTS_FILE" ] && [ -f "$SECTION_RESULTS_FILE" ]; then
    rm -f "$SECTION_RESULTS_FILE"
  fi

  printf '\n'
  if [ "$OVERALL_FAIL" = "0" ]; then
    log "OVERALL: PASS"
    exit 0
  else
    log "OVERALL: FAIL"
    exit 1
  fi
}

main "$@"
