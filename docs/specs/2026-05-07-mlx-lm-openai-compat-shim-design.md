# mlx-lm OpenAI-compat shim — design

**Date:** 2026-05-07
**Status:** approved (brainstorm), pending implementation plan
**Scope:** single-Mac local stack only

## Problem

`mlx_lm.server` (0.31.3) speaks an incomplete OpenAI surface. Real consumer harnesses — agent frameworks, dev tools, CLIs that expose an "OpenAI custom provider" URL — hit gaps that aren't documented and aren't trivially mappable from upstream sources. We need a way to use SwiftBar-launched local models with arbitrary OpenAI-compatible clients while progressively closing those gaps as we observe them.

## Goal

A standalone, framework-agnostic OpenAI-compat proxy in front of `mlx_lm.server` that (1) lets any OpenAI-compatible client work transparently against local mlx-lm models, (2) captures enough observability that gaps can be diagnosed and patched, and (3) provides a place to land patches as either declarative config or Python code.

Hermes is explicitly **not** the target. It is one possible consumer of many.

## Non-goals

- Replacing `mlx_lm.server` or its loader.
- Multi-model routing in v1 (single backend per shim).
- A management UI, metrics dashboard, or CLI review tool.
- Conversation threading (`conv_id`). Dropped — no high-confidence signal exists for stateless chat.completions; revisit only if we adopt `/v1/responses` or a header convention.
- Cross-machine deployment. This Mac only.

## Architecture

```
client (any OpenAI-compatible) ──► :64080   shim (Starlette + httpx)
                                     │
                                     └─► 127.0.0.1:64180   mlx_lm.server (loopback-only)
                                          │
                                          └─► ./tmp/{traffic,gaps}.jsonl  (rolling, project-local)
```

Ports are deliberately picked from the dynamic range to avoid common collisions (Ollama 11434, LM Studio 1234, Gradio 7860, Jupyter 8888, AirPlay 5000/7000, Vite 5173, Spark 4040, gRPC 50051, etc.). Both end in `…080` for visual familiarity with the old `:8080`.

`mlx-serve <model>` becomes responsible for launching **both** processes: `mlx_lm.server` on `127.0.0.1:64180`, then the shim on `:64080` with `MLX_BACKEND_URL=http://127.0.0.1:64180`. `--stop` and `--status` extend to manage the pair.

## Components

### `<repo>/shim/server.py`

Single-file Starlette app. Contents:

- Route table for `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/models`, plus a catch-all that proxies and logs unknown paths so they surface in `gaps.jsonl` instead of 404'ing silently.
- Each known endpoint: a small async function calling a shared `proxy()` helper (httpx async client → `MLX_BACKEND_URL`) with pre/post no-op hooks that pass through today (placeholder functions you replace when patching a gap).
- An explicit **OpenAI field allowlist** dict at the top of the file enumerating fields the shim recognizes today. Anything in a request body outside the allowlist becomes a `gaps.jsonl(kind:"unknown_field")` entry; the field is forwarded to the backend untouched.
- Entrypoint reads `MLX_BACKEND_URL`, `MLX_SHIM_PORT`, `MLX_SHIM_LOG_DIR` from env, runs uvicorn.
- Rolling-log code stays inline unless it grows past ~30 lines, at which point it gets promoted to `shim/logs.py`.

### `~/.local/bin/mlx-serve` (modified)

- `mlx-serve <model>` starts `mlx_lm.server --port 64180 --host 127.0.0.1 ...` then the shim on `:64080`.
- PID files: `./tmp/mlx-<model>.pid` (backend), `./tmp/mlx-shim.pid` (shim). Both project-local under `MLX_PROJECT_DIR` (= the repo root, which the launcher derives from its own script location and exports near the top).
- `--stop`: kills both PIDs, removes both PID files.
- `--status`: reports both processes.
- Stays bash 3.2 compatible.

### `~/.venvs/mlx` (in place, no new venv)

Adds `starlette`, `httpx`, `uvicorn[standard]`. Recorded in `shim/requirements.txt` for reproducible install via `~/.venvs/mlx/bin/pip install -r shim/requirements.txt`.

## Data flow

```
client → shim:64080
  1. assign request_id (uuid4 short)
  2. write traffic.jsonl: {request_id, ts, dir:"in", method, path, headers, body}
  3. allowlist-check body fields → any unknown → gaps.jsonl(kind:"unknown_field"); forward unchanged
  4. pre-hook (no-op default; wrapped per error policy)
  5. httpx async → mlx_lm.server 127.0.0.1:64180 (timeout, retries=0)
  6. on backend response:
       non-stream: read full body, post-hook, write traffic.jsonl(dir:"out") paired by request_id
       stream:     open-stream marker in traffic.jsonl, async-iterate SSE chunks straight to client,
                   buffer chunks in memory; on close, write single dir:"out" entry with joined body
  7. return to client
```

- Pairing key: `request_id` on every entry in both logs. `grep -F <id>` reconstructs a call.
- Timestamps: ISO-8601 with millis, UTC.
- Bodies: parsed JSON when possible; else raw string with `body_kind:"raw"` flag.
- Header redaction: `authorization`, `cookie`, `x-api-key` → `***` (Drive-backup safety).
- `/v1/models`: proxied unchanged. Mismatches surface via the backend's own 4xx, captured as `gaps.jsonl(kind:"backend_status")`.

## Failure & gap-capture policy

There must be no path through the shim where a failure occurs and leaves no trace.

- **Top-level handler wrapper.** Every request goes through one try/except that, on any exception, writes `gaps.jsonl(kind:"exception")` with full request context, partial response state, and traceback, then returns a 5xx whose body includes the gaps-entry id.
- **Backend errors** (connect/timeout/invalid JSON) — `kind:"backend_error"` with backend URL + httpx exception class. 502 to client.
- **Backend non-2xx** — `kind:"backend_status"` with status, body, request that triggered it. Passed through to client unchanged so the gap is visible client-side too.
- **Hook errors** — caught at the hook boundary only; `kind:"hook_error"`; hook treated as no-op so traffic still flows. The one place we deliberately swallow, because a buggy patch shouldn't take down the proxy. Recorded in full.
- **Unknown paths** — catch-all writes a `dir:"in"` traffic entry + a `kind:"unknown_path"` gap, then returns 404 directly without proxying. Implementation deviated from the original "proxies anyway" intent: an unknown path has no reason to round-trip, and proxying would surface as `backend_status` and mask the `unknown_path` signal. The traffic entry preserves the "no path leaves no trace" invariant.
- **Unknown fields on known paths** — checked against the allowlist; outside it → `kind:"unknown_field"`. Field forwarded unchanged.
- **SSE stream errors** — async generator wrapped in try/except that captures everything up to failure, writes `kind:"stream_error"`, closes the stream cleanly.
- **SSE stream buffer overflow** — the close-time `dir:"out"` log entry's in-memory accumulator is bounded by `MLX_SHIM_STREAM_BUFFER_BYTES` (default 16 MiB). On overflow, `kind:"stream_truncated"` is emitted exactly once. The relay to the client is unaffected — only observability is best-effort, the proxy is not.
- **Log writer errors** — never swallowed. Failures go to stderr (captured by the launcher's log) so we still know an entry was lost.
- **Backend death between requests** — pre-flight health check on `127.0.0.1:64180`; if down, `kind:"backend_down"` and 503.
- **Oversized request bodies** — pre-flight Content-Length check. If the declared length exceeds `MLX_SHIM_MAX_BODY_BYTES` (default 50 MiB), `kind:"body_too_large"` gap with the declared content-length and the cap; 413 to client. The body is never read, so unbounded allocation through the shim is bounded by the cap. Chunked-encoded requests (no Content-Length) bypass this check — accepted trade-off at the single-Mac scope.

## Logging shape

Two rolling JSONL files in `MLX_SHIM_LOG_DIR` (default `<repo>/tmp/`, i.e., project-local `./tmp/`):

- `traffic.jsonl` — every request and response, paired by `request_id`. One entry per direction; for streams, one open-stream entry and one close entry with joined body.
- `gaps.jsonl` — only entries that need attention (any of the `kind:` values listed above). Same `request_id` so they correlate to traffic entries.

Rotation: size-based (e.g., 50 MB per file, keep 5 prior). Files are JSONL so editor-readable directly, no CLI required.

## Testing

**Hard rule: no unit tests, no mocks, no stubs of any kind. All testing is live e2e against the actual models.** This shim's purpose is to surface real backend behavior; anything fake immediately drifts from reality and would mask the gaps we're trying to find. Model-loading itself is in scope — surprises during load (memory pressure, missing weights, version traps) are part of what we want to shake out.

One live e2e smoke script: `shim/test.sh`.

- **Request matrix against `gemma-26b-moe`** (KB-designated smoke-test model, fastest of the four):
  - Non-streaming chat completion.
  - Streaming chat completion.
  - Request with a deliberately unknown field (`foo: 42`) → expect `gaps.jsonl(kind:"unknown_field")`.
  - Request to an unknown path (`/v1/embeddings/garbage`) → expect `gaps.jsonl(kind:"unknown_path")`.
  - Backend killed mid-flight → expect `gaps.jsonl(kind:"backend_error"|"stream_error")`.
  - Shim started with backend down (no `mlx_lm.server` listening) → expect `gaps.jsonl(kind:"backend_down")`.
  - For each: assert paired `traffic.jsonl` + `gaps.jsonl` entries on `request_id`. Diff non-streaming shim response against a direct-to-backend call.
- **Model-load cycle** — separately, walk through all four catalog models (`scout`, `mistral-medium`, `gemma-31b`, `gemma-26b-moe`) via `mlx-serve <model>` and assert the shim+backend pair comes up cleanly for each (health probe responds, `/v1/models` returns the loaded model, single non-streaming request succeeds). This shakes out per-model load issues that only show up against the real weights — the prior `kb/known-model-failures.md` exists precisely because of these.
- **Manual** roundtrip with one real client (e.g., `llm` CLI) once the script passes.

Failure modes that can't be live-induced (e.g., malformed JSON from `mlx_lm.server`) are deliberately **not** tested. We discover them through `gaps.jsonl` in real traffic, which is the entire point of the shim.

No pytest layer, no CI. Reassess only if traffic-driven discovery proves insufficient.

## Out of scope (explicit)

- Conversation threading (no high-confidence signal exists; would mislead more than it helps).
- Hermes-specific install/config bugs (separate work; the gateway/doctor errors from prior session belong in the hermes-agent fork).
- Multi-model routing (defer until a real second model is in active use simultaneously).
- DSL / config-mapping engine (defer until `gaps.jsonl` shows the same trivial transform repeating across endpoints; that's the signal a config layer earns its weight).

## File layout summary

```
<repo>/
├── kb/                                         # existing, unchanged
├── docs/superpowers/specs/
│   └── 2026-05-07-mlx-lm-openai-compat-shim-design.md   # this file
└── shim/
    ├── server.py                               # Starlette app + handlers + logging
    ├── requirements.txt                        # starlette, httpx, uvicorn[standard]
    └── test.sh                                 # live e2e smoke

~/.local/bin/mlx-serve                          # modified to launch the pair
~/.venvs/mlx/                                   # existing venv, augmented in place
<repo>/tmp/{traffic,gaps}.jsonl # rolling log output (project-local, gitignored)
<repo>/tmp/mlx-shim.pid         # shim PID
<repo>/tmp/mlx-<model>.pid      # backend PID
```

## Open questions for the implementation plan

These are deliberately not answered here; `writing-plans` will pin them down with verification per step:

- Exact rotation sizes and retention counts.
- Initial allowlist contents (start permissive or start strict?).
- Health-check shape (HEAD `/v1/models`? TCP probe? Cached for N seconds?).
- Exact `mlx-serve` ordering and timing (start backend, wait for readiness, then start shim) and how readiness is detected.
- Streaming buffer cap (in case a runaway response makes us OOM the in-memory buffer).
