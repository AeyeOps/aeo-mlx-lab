# Deep Interview Spec: MLX Server E2E Autoresearch Mission

## Metadata
- Interview ID: mlx-server-autoresearch-e2e
- Rounds: 2 (+ Round 0 topology)
- Final Ambiguity Score: 17%
- Type: brownfield
- Hardware: Apple M5 Max, 128 GB unified memory
- Generated: 2026-05-09
- Threshold: 20%
- Status: PASSED

## Clarity Breakdown
| Dimension | Score | Weight | Weighted |
|-----------|-------|--------|----------|
| Goal Clarity | 0.88 | 35% | 0.31 |
| Constraint Clarity | 0.80 | 25% | 0.20 |
| Success Criteria | 0.78 | 25% | 0.20 |
| Context Clarity | 0.82 | 15% | 0.12 |
| **Total Clarity** | | | **0.83** |
| **Ambiguity** | | | **17%** |

## Topology
| Component | Status | Description | Coverage |
|-----------|--------|-------------|----------|
| Per-model E2E SwiftBar test | active | For each of 4 configured models: SwiftBar click → stack ready → real HTTP client → well-defined pass/fail | All 4 criteria covered |

## Goal
Prove end-to-end that a user clicking "Start [model]" in SwiftBar results in a correctly-functioning stack — for **all 4 configured models** — by running a structured evaluator that checks instruction-following, performance, no-refusal, and semantic coherence.

## Models Under Test
| Model key | HF path | Known baseline (M5 Max 128GB) | tok/s floor |
|-----------|---------|-------------------------------|-------------|
| gemma-26b-moe | mlx-community/gemma-4-26B-A4B-it-OptiQ-4bit | 92.6 tok/s | ≥ 74 tok/s |
| gemma-31b | mlx-community/gemma-4-31B-it-OptiQ-4bit | not yet established | ≥ 80% of first-run baseline |
| mistral-medium | mlx-community/Mistral-Medium-3.5-128B-4bit | not yet established | ≥ 80% of first-run baseline |
| scout | mlx-community/Llama-4-Scout-17B-16E-Instruct-4bit | not yet established | ≥ 80% of first-run baseline (soft — known flaky) |

## Constraints
- SwiftBar click must be via osascript (not direct mlx-serve call) — validates the user-facing launch path
- Judge for semantic coherence must be the local Claude CLI via `cldsaeo` alias (injects OAuth token from `~/.config/secrets/keys.env`, runs `clds`) — not the model under test (circular), not Anthropic REST API
- Evaluator must start and stop the stack for each model — no assumed-running state
- All Python in this project uses `~/.venvs/mlx`; evaluator is bash-only (no Python)
- Ports: shim on `:64080`, backend on `127.0.0.1:64180`
- Accessibility permission is granted for Ghostty (verified: `osascript UI elements enabled = true`)
- Scout is known flaky — its failure does not fail the overall autoresearch pass, but is tracked separately

## Non-Goals
- Testing specific prompt domains or model fine-tuning quality
- Multi-turn conversation or tool-use testing
- Non-mlx-community model weights
- Concurrent multi-user load testing

## Acceptance Criteria

### Per-model (gemma-26b-moe, gemma-31b, mistral-medium required; scout advisory)
- [ ] SwiftBar click of "Start [model]" succeeds (osascript exits 0, stack comes up)
- [ ] `/healthz` on `:64080` returns HTTP 200 within `MLX_BACKEND_READY_TIMEOUT` seconds
- [ ] `POST /v1/chat/completions` returns HTTP 200
- [ ] Response contains `x-shim-request-id` header
- [ ] **Instruction-following**: response to "Count to five. Reply only with the numbers." contains digits 1–5 (or words one–five) in correct order
- [ ] **No-refusal**: response does not match `I cannot|I'm unable|I'm sorry, I can't` (case-insensitive)
- [ ] **Performance**: decode throughput ≥ model tok/s floor (measured as `completion_tokens / elapsed_seconds`)
- [ ] **Semantic coherence**: `cldsaeo` judge scores response ≥ 7/10 on task-completion scale
- [ ] `traffic.jsonl` has matching `dir:in` + `dir:out` (or stream_open/stream_close) entries for the request
- [ ] `gaps.jsonl` has 0 entries for the request's `request_id`

### Overall pass condition
- All 3 required models (gemma-26b-moe, gemma-31b, mistral-medium) pass all checks
- Scout result is recorded and tracked but does not block overall `pass: true`

## Evaluator Design

### Test prompt
```
Count to five. Reply only with the numbers.
```

### Instruction-following check (deterministic)
Response must contain all of: `1`, `2`, `3`, `4`, `5` (digits) OR `one`, `two`, `three`, `four`, `five` (words), in that order. Check via grep/awk on the `choices[0].message.content` field.

### No-refusal check (deterministic)
```bash
echo "$content" | grep -qiE 'I cannot|I.m unable|I.m sorry.*I can.t' && FAIL
```

### Performance check
```bash
elapsed=$(( end_ts - start_ts ))          # seconds, from curl -w time_total
completion_tokens=$(jq '.usage.completion_tokens' resp.json)
tok_s=$(echo "scale=1; $completion_tokens / $elapsed" | bc)
[ "$(echo "$tok_s >= $FLOOR" | bc)" = "1" ] || FAIL
```

### Semantic judge invocation
```bash
SCORE=$(eval $(sed -n "$(jot -r 1 1 3)p" ~/.config/secrets/keys.env) \
  clds -p "$(cat <<'PROMPT'
You are a strict quality judge. Score the AI response below 0-10 for task completion.

Task: "Count to five. Reply only with the numbers."
Response: RESPONSE_PLACEHOLDER

10 = perfect (1 2 3 4 5 in order, nothing extraneous)
7-9 = good (numbers present, minor formatting)
4-6 = partial (some numbers missing or out of order)
0-3 = failed (refuses, gibberish, or completely off-task)

Respond ONLY with valid JSON: {"score": <int 0-10>, "reason": "<one sentence>"}
PROMPT
)" | jq '.score')
[ "$SCORE" -ge 7 ] || FAIL
```

### SwiftBar click (osascript)
```applescript
tell application "System Events"
  tell process "SwiftBar"
    click menu bar item 1 of menu bar 2
    delay 0.5
    click menu item "Single-model launchers (auto-stops any running stack)" of menu 1 of menu bar item 1 of menu bar 2
    delay 0.3
    click menu item "Start [MODEL_KEY]" of menu 1 of menu item "Single-model launchers (auto-stops any running stack)" of menu 1 of menu bar item 1 of menu bar 2
  end tell
end tell
```
Note: SwiftBar's exact menu bar item index (1 or 2) must be validated on first run.

### Evaluator output schema
```json
{
  "pass": true,
  "score": 0.875,
  "models": {
    "gemma-26b-moe": {
      "pass": true,
      "checks": {
        "swiftbar_click": true,
        "healthz": true,
        "http_200": true,
        "request_id_header": true,
        "instruction_following": true,
        "no_refusal": true,
        "tok_s": 88.3,
        "tok_s_floor": 74.0,
        "performance_pass": true,
        "semantic_score": 9,
        "semantic_pass": true,
        "traffic_paired": true,
        "no_gaps": true
      }
    }
  },
  "scout_advisory": {"pass": false, "reason": "flaky — tracked but not blocking"}
}
```

## Technical Context
- Shim: `shim/server.py` — Starlette proxy on `:64080` fronting `mlx_lm.server` on `127.0.0.1:64180`
- Launcher: `~/.local/bin/mlx-serve` — bash 3.2, owns both process lifecycles
- SwiftBar plugin: `~/Library/Application Support/SwiftBar/Plugins/mlx.30s.sh`
- Click path: SwiftBar → osascript → `ghostty-run` → `mlx-serve [model]`
- Logs: `tmp/traffic.jsonl`, `tmp/gaps.jsonl` (project-local, gitignored)
- Accessibility: Ghostty granted, `osascript UI elements enabled = true`
- Judge alias: `cldsaeo` = `eval $(sed -n "$(jot -r 1 1 3)p" ~/.config/secrets/keys.env) clds`

## Interview Transcript
<details>
<summary>Full Q&A (2 rounds + Round 0)</summary>

### Round 0
**Q:** Topology confirmation — 1 component: E2E SwiftBar Test for gemma-26b-moe?
**A:** All configured models, not just one. Success criteria must be well-defined beyond just receiving a response.

### Round 1
**Q:** What specific, automatable criteria define a genuine pass?
**A:** All four: instruction-following, performance thresholds (hardware-grounded), no-refusal, semantic coherence (LLM-judge). Performance floor = known benchmarks for M4/M5 Max 128GB, fallback to M3 Max 128GB.
**Ambiguity:** ~28%

### Round 2
**Q:** What powers the LLM judge?
**A:** Local Claude CLI via `cldsaeo` alias (eval OAuth token → clds).
**Ambiguity:** ~17% — below 20% threshold.
</details>
