#!/usr/bin/env bash
# eval/e2e-swiftbar/evaluate.sh
#
# Autoresearch evaluator: per-model E2E SwiftBar validation.
# Outputs one JSON line: {"pass":<bool>,"score":<float>,"models":{...},"scout_advisory":{...}}
#
# Required models (all must pass): gemma-26b-moe  gemma-31b  mistral-medium
# Advisory model (tracked, not blocking): scout
#
# Bash 3.2 compatible. No mocks. No stubs. Live against real mlx_lm.server.

set -uo pipefail

# Resolve REPO_ROOT from this script's location, following symlinks.
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

PROJ="${MLX_PROJECT_DIR:-$REPO_ROOT}"
TMP="$PROJ/tmp"
MLX_SERVE="${MLX_SERVE_BIN:-$HOME/.local/bin/mlx-serve}"
SHIM_BASE="http://127.0.0.1:64080"
BACKEND_BASE="http://127.0.0.1:64180"
BACKEND_READY_TIMEOUT="${MLX_BACKEND_READY_TIMEOUT:-600}"
BASELINES="$PROJ/eval/e2e-swiftbar/baselines.json"
RESULTS_DIR="$TMP/.eval-results-$$"
KEYS_ENV="${KEYS_ENV:-$HOME/.config/secrets/keys.env}"
# `clds` is a zsh interactive alias; in bash we expand it to the underlying
# binary. `--dangerously-skip-permissions` is the only flag actually required
# for non-interactive judge calls (debug/verbose are noise we don't need).
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"

# Perf-measurement prompt: long enough that decode time dominates total elapsed.
# Instruction-following check (digits 1-5 in order) still passes since they
# appear as a prefix of the count.
TEST_PROMPT="Count from 1 to 50. Reply only with the numbers separated by spaces, nothing else."
MAX_TOKENS=256
SEMANTIC_PASS_THRESHOLD=7   # judge score >= this = pass

# Propagate timeout to mlx-serve when launched via SwiftBar→ghostty-run
# (open -na breaks env inheritance from this shell). launchctl setenv puts
# the var in the GUI session's environment, where new processes inherit it.
launchctl setenv MLX_BACKEND_READY_TIMEOUT "$BACKEND_READY_TIMEOUT" 2>/dev/null || true

# ---- helpers ----------------------------------------------------------------

log() { printf '[eval] %s\n' "$*" >&2; }

cleanup_on_exit() {
  log "EXIT trap: stopping any running stack"
  "$MLX_SERVE" --stop >/dev/null 2>&1 || true
  launchctl unsetenv MLX_BACKEND_READY_TIMEOUT 2>/dev/null || true
  rm -rf "$RESULTS_DIR" 2>/dev/null || true
}
trap cleanup_on_exit EXIT INT TERM

hf_path_for() {
  case "$1" in
    gemma-26b-moe)  echo "mlx-community/gemma-4-26B-A4B-it-OptiQ-4bit" ;;
    gemma-31b)      echo "mlx-community/gemma-4-31B-it-OptiQ-4bit" ;;
    mistral-medium) echo "mlx-community/Mistral-Medium-3.5-128B-4bit" ;;
    scout)          echo "mlx-community/Llama-4-Scout-17B-16E-Instruct-4bit" ;;
    *) return 1 ;;
  esac
}

tok_s_floor_for() {
  local model="$1"
  if [ "$model" = "gemma-26b-moe" ]; then
    # 65 tok/s — empirical e2e floor for /v1/chat/completions on M5 Max 128GB.
    # The KB's 92.6 baseline was decode-only via mlx_lm.generate; e2e (HTTP +
    # prefill + 256-tok decode) ceilings around 70-72 with idle GPU (verified
    # iter 2 + iter 4). 65 leaves ~7-10 tok/s of headroom for normal variance.
    echo "65"
    return
  fi
  local baseline
  baseline=$(jq -r --arg m "$model" '.[$m] // empty' "$BASELINES" 2>/dev/null)
  if [ -n "$baseline" ]; then
    # awk produces leading-zero floats (bc's "scale=0" only handles integer truncation)
    awk -v b="$baseline" 'BEGIN{ printf "%.1f", b * 0.8 }'
  else
    echo "0"  # no baseline yet — any positive tok/s passes (first run)
  fi
}

store_baseline() {
  local model="$1" toks="$2"
  local current="{}"
  [ -f "$BASELINES" ] && current=$(cat "$BASELINES")
  printf '%s' "$current" \
    | jq --arg m "$model" --argjson t "$toks" '.[$m] = $t' \
    > "$BASELINES.tmp" && mv "$BASELINES.tmp" "$BASELINES"
}

display_name_for() {
  case "$1" in
    gemma-26b-moe)  echo "Gemma 4 26B A4B MoE OptiQ (~14GB)" ;;
    gemma-31b)      echo "Gemma 4 31B Dense OptiQ (~16GB)" ;;
    mistral-medium) echo "Mistral Medium 3.5 (128B dense, ~73GB)" ;;
    scout)          echo "Llama 4 Scout (17B/109B MoE, ~61GB)" ;;
    *) return 1 ;;
  esac
}

swiftbar_click() {
  local key="$1"
  local display_name
  display_name=$(display_name_for "$key") || return 1
  # menu bar 1, item 1 = SwiftBar status item
  # each model: top-level item is the display name; submenu contains "Start [key]"
  osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "System Events"
  tell process "SwiftBar"
    click menu bar item 1 of menu bar 1
    delay 0.7
    set m to menu 1 of menu bar item 1 of menu bar 1
    click menu item "$display_name" of m
    delay 0.5
    set sub to menu 1 of menu item "$display_name" of m
    click menu item "Start [$key]" of sub
  end tell
end tell
APPLESCRIPT
}

# Sample GPU state for ~5 seconds (10 samples at 500ms). Echoes a single line:
#   "<status>|<max_gpu_power>|<max_gpu_usage_pct>"
# status = "idle" if max gpu_power < 2.0 W AND max gpu_usage < 0.10
#          "busy" otherwise (something else is using the GPU)
# KB reference: idle gpu_power ~0.07 W, MLX-under-load ~24-26 W. 2.0 W threshold
# catches non-MLX background activity well below MLX inference levels.
sample_gpu_idle() {
  local samples; samples=$(macmon pipe -i 500 2>/dev/null | head -10)
  [ -z "$samples" ] && { printf 'unknown|0|0'; return; }
  local max_power max_usage
  max_power=$(printf '%s\n' "$samples" | jq -s 'map(.gpu_power) | max' 2>/dev/null)
  max_usage=$(printf '%s\n' "$samples" | jq -s 'map(.gpu_usage[1]) | max' 2>/dev/null)
  local status
  status=$(awk -v p="${max_power:-0}" -v u="${max_usage:-0}" \
    'BEGIN{ print (p+0 < 2.0 && u+0 < 0.10) ? "idle" : "busy" }')
  printf '%s|%.2f|%.4f' "$status" "${max_power:-0}" "${max_usage:-0}"
}

is_pid_alive() {
  local pid_file="$1"
  [ -f "$pid_file" ] || return 1
  local pid; pid=$(cat "$pid_file" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

# Wait for: (1) the EXPECTED model's PID file to exist with a live PID
# (proves the SwiftBar click triggered the right mlx-serve and it completed
# stop_all + new backend start), AND (2) shim healthz responds 200.
# mlx_lm.server's /v1/models lists every configured model regardless of which
# is loaded, and the chat-completion .model field just echoes the request, so
# the only reliable "is the right model up" signal is the PID file mlx-serve
# writes (one per model key, removed on stop_all).
wait_for_model_ready() {
  local expected_key="$1"
  local pid_file="$TMP/mlx-${expected_key}.pid"
  local deadline=$(( $(date +%s) + BACKEND_READY_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if is_pid_alive "$pid_file"; then
      if curl -fs --max-time 2 "$SHIM_BASE/healthz" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 5
  done
  return 1
}

# Try one OAuth token. Echoes "<score>|<reason>" on success, empty on failure.
try_judge_token() {
  local tok="$1" prompt="$2"
  local judge_tmp; judge_tmp=$(mktemp)
  CLAUDECODE="" CLAUDE_CODE_SESSION_ID="" CLAUDE_CODE_OAUTH_TOKEN="$tok" \
    "$CLAUDE_BIN" --dangerously-skip-permissions \
    -p "$prompt" \
    --no-session-persistence \
    --output-format json \
    --json-schema '{"type":"object","properties":{"score":{"type":"integer","minimum":0,"maximum":10},"reason":{"type":"string"}},"required":["score","reason"]}' \
    < /dev/null 2>/dev/null > "$judge_tmp" || true
  # Output is either a single object (no --verbose) or array (with --verbose).
  # Normalize both shapes through `if type=="array" then .[] else . end`.
  local out
  out=$(jq -r '(if type=="array" then .[] else . end) | select(.type=="result") | select(.structured_output != null) | "\(.structured_output.score)|\(.structured_output.reason)"' "$judge_tmp" 2>/dev/null | head -1)
  rm -f "$judge_tmp"
  printf '%s' "$out"
}

# Random-ordered iteration over the 3 OAuth tokens until one returns a
# non-empty result. Echoes "<score>|<reason>". Empty on total failure.
run_judge() {
  local content="$1"
  local prompt='Score this AI response 0-10 for the task "Count from 1 to 50. Reply only with the numbers separated by spaces, nothing else." Response: '"$content"'. 10=perfect (1 2 3 ... 50 in order, nothing extra), 7-9=good (numbers present, minor formatting drift), 4-6=partial (some numbers missing or out of order), 0-3=failed (refuses, gibberish, completely off-task). Respond ONLY with JSON: {"score": <int 0-10>, "reason": "<one sentence>"}'

  # Shuffle 1..3 and try each. First non-empty result wins.
  local order; order=$(jot -r 3 1 9999 | awk 'BEGIN{srand()}{print rand(), NR}' | sort -n | awk '{print $2}')
  local i tok result
  for i in $order; do
    tok=$(sed -n "${i}p" "$KEYS_ENV" 2>/dev/null | cut -d= -f2-)
    [ -z "$tok" ] && continue
    result=$(try_judge_token "$tok" "$prompt")
    [ -n "$result" ] && { printf '%s' "$result"; return; }
  done
  printf '0|judge_unavailable_all_tokens_failed'
}

last_in_rid() {
  grep -F '"dir": "in"' "$TMP/traffic.jsonl" 2>/dev/null \
    | grep -F '"path": "/v1/chat/completions"' \
    | tail -1 \
    | jq -r '.request_id // ""' 2>/dev/null
}

count_matching() {
  local file="$1"; shift
  [ -f "$file" ] || { echo 0; return; }
  local tmp; tmp=$(mktemp)
  cp "$file" "$tmp"
  local t
  while [ "$#" -gt 0 ]; do
    t=$(mktemp)
    grep -F "$1" "$tmp" > "$t" 2>/dev/null || true
    mv "$t" "$tmp"
    shift
  done
  wc -l < "$tmp" | tr -d ' '
  rm -f "$tmp"
}

jbool() { [ "$1" = "true" ] && echo true || echo false; }

# Always-leading-zero float formatter. bc emits ".2" for 0.2 which JSON.parse
# rejects; awk's printf gives "0.2".
fmt_float() {
  awk -v v="$1" 'BEGIN{ if (v=="" || v+0==0) print "0.0"; else printf "%.1f", v+0 }'
}

# Escape a string for embedding in a JSON value. Strips control chars, escapes
# backslashes and double quotes.
json_escape() {
  printf '%s' "$1" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read())[1:-1])'
}

# ---- per-model evaluation ---------------------------------------------------

eval_model() {
  local model_key="$1"
  local hf_path
  hf_path=$(hf_path_for "$model_key") || {
    echo '{"pass":false,"error":"unknown_model"}'
    return
  }

  # Pre-flight: ensure no stale stack. Without this, wait_for_model_ready
  # could (briefly) catch the prior model's shim still serving healthz before
  # SwiftBar's new mlx-serve runs stop_all in the new Ghostty session.
  log "[$model_key] pre-flight stop"
  "$MLX_SERVE" --stop >/dev/null 2>&1 || true
  sleep 1

  log "[$model_key] SwiftBar click"
  if ! swiftbar_click "$model_key"; then
    log "[$model_key] FAIL: SwiftBar click failed (check osascript menu path)"
    echo '{"pass":false,"error":"swiftbar_click_failed"}'
    return
  fi

  log "[$model_key] waiting for $model_key stack (timeout=${BACKEND_READY_TIMEOUT}s)"
  if ! wait_for_model_ready "$model_key"; then
    log "[$model_key] FAIL: timeout waiting for ${model_key} backend PID + shim healthz"
    "$MLX_SERVE" --stop >/dev/null 2>&1 || true
    echo '{"pass":false,"error":"stack_ready_timeout"}'
    return
  fi
  log "[$model_key] stack ready (PID file present, healthz 200)"

  # Pre-test GPU idle check (5s sample). If something else is using the GPU,
  # tok/s measurement will be unreliable. We don't fail on busy — we record
  # the state so unstable readings can be correlated with system activity.
  log "[$model_key] sampling GPU idle state for 5s"
  local gpu_check; gpu_check=$(sample_gpu_idle)
  local gpu_status; gpu_status=$(printf '%s' "$gpu_check" | cut -d'|' -f1)
  local gpu_max_power; gpu_max_power=$(printf '%s' "$gpu_check" | cut -d'|' -f2)
  local gpu_max_usage; gpu_max_usage=$(printf '%s' "$gpu_check" | cut -d'|' -f3)
  if [ "$gpu_status" = "busy" ]; then
    log "[$model_key] WARN: GPU busy before test — max_power=${gpu_max_power}W max_usage=${gpu_max_usage} (perf may be unreliable)"
  else
    log "[$model_key] GPU idle: max_power=${gpu_max_power}W max_usage=${gpu_max_usage}"
  fi

  # HTTP request — capture response body, headers, timing, status
  local resp_file="$TMP/.eval-resp-${model_key}.json"
  local hdr_file="$TMP/.eval-hdr-${model_key}.txt"
  local curl_out
  curl_out=$(curl -s \
    -o "$resp_file" \
    -D "$hdr_file" \
    -w '%{time_total}\n%{http_code}' \
    --max-time 600 \
    "$SHIM_BASE/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$hf_path\",\"messages\":[{\"role\":\"user\",\"content\":\"$TEST_PROMPT\"}],\"max_tokens\":$MAX_TOKENS}" \
    2>/dev/null)
  local elapsed http_status
  elapsed=$(printf '%s\n' "$curl_out" | head -1)
  http_status=$(printf '%s\n' "$curl_out" | tail -1)

  if [ "$http_status" != "200" ]; then
    log "[$model_key] FAIL: HTTP $http_status"
    "$MLX_SERVE" --stop >/dev/null 2>&1 || true
    echo "{\"pass\":false,\"error\":\"http_$http_status\"}"
    return
  fi

  local content completion_tokens
  content=$(jq -r '.choices[0].message.content // ""' "$resp_file" 2>/dev/null)
  completion_tokens=$(jq -r '.usage.completion_tokens // 1' "$resp_file" 2>/dev/null)

  # Check 1: x-shim-request-id header
  local hdr_rid
  hdr_rid=$(grep -i '^x-shim-request-id:' "$hdr_file" 2>/dev/null \
    | tr -d '\r' | awk '{print $2}' | tail -1)
  local has_rid=false
  [ -n "$hdr_rid" ] && has_rid=true

  # Check 2: instruction-following (digits 1-5 all present, in that order)
  local instr_ok=false
  if printf '%s' "$content" | grep -qE '1[^0-9]+2[^0-9]+3[^0-9]+4[^0-9]+5'; then
    instr_ok=true
  fi

  # Check 3: no refusal
  local no_refusal=true
  printf '%s' "$content" | grep -qiE "I cannot|I.m unable|I.m sorry.*I can.t|I am unable" \
    && no_refusal=false

  # Check 4: performance (tok/s) — long-output prompt makes decode dominate
  local tok_s tok_floor perf_ok=false first_run=false
  tok_s=$(fmt_float "$(awk -v c="$completion_tokens" -v e="$elapsed" 'BEGIN{ if (e>0) printf "%.4f", c/e; else print "0" }')")
  tok_floor=$(tok_s_floor_for "$model_key")

  if [ "$tok_floor" = "0" ]; then
    # No baseline yet — this is the first run; store and pass
    first_run=true
    perf_ok=true
    store_baseline "$model_key" "$tok_s"
    log "[$model_key] first-run baseline: $tok_s tok/s stored"
  else
    # Compare via awk to avoid bc precision quirks with leading-zero floats
    local pass_perf
    pass_perf=$(awk -v t="$tok_s" -v f="$tok_floor" 'BEGIN{ print (t+0 >= f+0) ? "1" : "0" }')
    [ "$pass_perf" = "1" ] && perf_ok=true
  fi

  # Check 5: semantic judge
  log "[$model_key] invoking semantic judge"
  local judge_result sem_score sem_reason sem_ok=false
  judge_result=$(run_judge "$content")
  sem_score=$(printf '%s' "$judge_result" | cut -d'|' -f1)
  sem_reason=$(printf '%s' "$judge_result" | cut -d'|' -f2-)
  [ "${sem_score:-0}" -ge "$SEMANTIC_PASS_THRESHOLD" ] 2>/dev/null && sem_ok=true

  # Check 6: traffic.jsonl paired + no gaps
  local rid traffic_ok=false no_gaps=false
  rid=$(last_in_rid)
  if [ -n "$rid" ]; then
    local in_c out_c gap_c
    in_c=$(count_matching "$TMP/traffic.jsonl" "\"request_id\": \"$rid\"" '"dir": "in"')
    out_c=$(count_matching "$TMP/traffic.jsonl" "\"request_id\": \"$rid\"" '"dir": "out"')
    gap_c=$(count_matching "$TMP/gaps.jsonl" "\"request_id\": \"$rid\"")
    [ "$in_c" = "1" ] && [ "$out_c" = "1" ] && traffic_ok=true
    [ "$gap_c" = "0" ] && no_gaps=true
  fi

  # Stop stack
  log "[$model_key] stopping stack"
  "$MLX_SERVE" --stop >/dev/null 2>&1 || true
  sleep 2

  # Overall pass for this model
  local pass=false
  if $has_rid && $instr_ok && $no_refusal && $perf_ok && $sem_ok && $traffic_ok && $no_gaps; then
    pass=true
  fi

  log "[$model_key] pass=$(jbool $pass) instr=$(jbool $instr_ok) norefusal=$(jbool $no_refusal) perf=$(jbool $perf_ok) [$tok_s vs $tok_floor tok/s, gpu=$gpu_status max_power=${gpu_max_power}W] sem=$(jbool $sem_ok) [$sem_score/10] traffic=$(jbool $traffic_ok) nogaps=$(jbool $no_gaps)"

  local sem_reason_esc; sem_reason_esc=$(json_escape "$sem_reason")
  printf '{"pass":%s,"checks":{"request_id_header":%s,"instruction_following":%s,"no_refusal":%s,"tok_s":%s,"tok_s_floor":%s,"performance_pass":%s,"first_run_baseline":%s,"gpu_pretest_status":"%s","gpu_pretest_max_power_w":%s,"gpu_pretest_max_usage":%s,"semantic_score":%s,"semantic_reason":"%s","semantic_pass":%s,"traffic_paired":%s,"no_gaps":%s}}' \
    "$(jbool $pass)" \
    "$(jbool $has_rid)" \
    "$(jbool $instr_ok)" \
    "$(jbool $no_refusal)" \
    "$tok_s" \
    "$tok_floor" \
    "$(jbool $perf_ok)" \
    "$(jbool $first_run)" \
    "$gpu_status" \
    "$gpu_max_power" \
    "$gpu_max_usage" \
    "${sem_score:-0}" \
    "$sem_reason_esc" \
    "$(jbool $sem_ok)" \
    "$(jbool $traffic_ok)" \
    "$(jbool $no_gaps)"
}

# ---- main -------------------------------------------------------------------

mkdir -p "$TMP" "$RESULTS_DIR"
[ -f "$BASELINES" ] || echo '{}' > "$BASELINES"

REQUIRED="gemma-26b-moe gemma-31b mistral-medium"
overall_pass=true

for m in $REQUIRED; do
  log "=== evaluating $m ==="
  result=$(eval_model "$m")
  printf '%s' "$result" > "$RESULTS_DIR/$m.json"
  mpass=$(printf '%s' "$result" | jq -r '.pass' 2>/dev/null || echo false)
  [ "$mpass" = "true" ] || overall_pass=false
done

log "=== evaluating scout (advisory) ==="
scout_result=$(eval_model "scout")
printf '%s' "$scout_result" > "$RESULTS_DIR/scout.json"

# score = fraction of (model x check) pairs passing across required models
CHECKS="request_id_header instruction_following no_refusal performance_pass semantic_pass traffic_paired no_gaps"
total=0 passed=0
for m in $REQUIRED; do
  r=$(cat "$RESULTS_DIR/$m.json" 2>/dev/null || echo '{}')
  for chk in $CHECKS; do
    total=$(( total + 1 ))
    v=$(printf '%s' "$r" | jq -r ".checks.$chk // false" 2>/dev/null || echo false)
    [ "$v" = "true" ] && passed=$(( passed + 1 ))
  done
done
score=$(awk -v p="$passed" -v t="$total" 'BEGIN{ if (t>0) printf "%.3f", p/t; else print "0.000" }')

# Build models JSON
models='{'
sep=''
for m in $REQUIRED; do
  r=$(cat "$RESULTS_DIR/$m.json" 2>/dev/null || echo '{}')
  models="${models}${sep}\"$m\":${r}"
  sep=','
done
models="${models}}"

scout_json=$(cat "$RESULTS_DIR/scout.json" 2>/dev/null || echo '{"pass":false,"error":"not_run"}')

printf '{"pass":%s,"score":%s,"models":%s,"scout_advisory":%s}\n' \
  "$(jbool $overall_pass)" \
  "$score" \
  "$models" \
  "$scout_json"
