# Roadmap

## What this could become

> A local AI lab where every claim is reproducible, every regression is caught
> in the dark before it reaches the light, and every quirk of running real
> models on real silicon gets written down before it's forgotten.

This lab starts as one shim, one launcher, one menu-bar plugin, one validation
run. The interesting question isn't *"does it work today"* — we already know
it does. The interesting question is what shape it takes when given consistent
investment over weeks, months, years.

This document is the answer to that question, in three horizons.

## Themes (the through-lines)

Three principles run through every horizon below. They're invariant; only
how they manifest changes.

- **Honest measurement, every time.** No claim about throughput, quality, or
  correctness lives in the repo without a reproducible measurement that
  generated it. When the measurement disagrees with intuition, the
  measurement wins.
- **One stack at a time.** Concurrency is a benchmarking lie on a single-GPU
  Mac. Load, measure, unload. Each model gets its full slice of silicon.
- **Boring wins over flashy.** The launcher is bash, the shim is one Python
  file, the evaluator is one bash script. Each runs without orchestration.
  Each can be read in one sitting. Each fits in a single human head.

## Near horizon — months 1–3

> "Get the foundations boring."

Cement what's here. Catch the second wave of bugs that only show up under
real use over time.

- A second eval mission alongside `e2e-swiftbar/`: **shim throughput** at
  varying concurrency (1, 2, 4 simultaneous `/v1/chat/completions`). Catches
  prefill-cache contention before it bites in mixed workloads.
- A third eval mission: **streaming correctness** — every model, SSE token
  boundaries verified, reconnection mid-stream, partial-message handling.
- A small `eval/_lib/` of shared helpers (the GPU-idle sampler, the OAuth
  rotation, the temp-file pattern) extracted from `e2e-swiftbar/evaluate.sh`
  so new missions don't copy-paste.
- A **trend-analysis** script: read every
  `runs/run-*/evaluations/iteration-*.json`, plot tok/s and semantic score
  over time per model. Flag the day a regression started.
- The KB grows naturally. Each new model quirk becomes an article. Each
  operational surprise becomes an article. Goal: when something breaks at
  11 PM, the answer is already written down.

## Mid horizon — months 3–9

> "Make it comparative."

The lab stops being about *one* serving stack and starts being about
*choosing* between them.

- `backends/omlx/` arrives. The shim grows a tiny route table: per-model
  config picks `mlx-lm` or `oMLX`, transparent to clients on `:64080`.
  Every existing eval mission runs against both backends; deltas surface
  in the trend dashboard.
- `backends/llama-cpp/` if and when the GGUF quants on Apple Silicon
  catch up enough to be interesting. Same routing pattern — the shim is
  the fixed boundary, backends come and go behind it.
- A real **prompt corpus**: not just "count to 50". Code completions,
  JSON extraction, refusal-resistance probes, long-context recall. The
  semantic judge stays the gate; new prompts feed the judge new tasks.
- ADRs accumulate in `docs/adr/`. *Why we picked Starlette over FastAPI.
  Why backends are loopback-only. Why the evaluator uses PID files
  instead of `/v1/models` to verify the loaded model.* Future-you stops
  repeating the same arguments.

## Far horizon — year 1+

> "Make it useful to others."

The lab becomes a thing other people can pick up and run on their own
Mac. The README stops being a private memo and becomes a real welcome.

- A small Python client SDK (`clients/python/`) that wraps `requests`
  against `:64080` with retry and streaming helpers. Used internally
  first; the shape of its API tells us where the shim's API has rough
  edges.
- A real **dashboard** — not SwiftBar — pulling from `traffic.jsonl` and
  `gaps.jsonl` over the local network. Maybe a single static HTML page
  served by the shim at `/dashboard`. Maybe a separate small Tauri app.
  Decided when the data is interesting enough to warrant the surface.
- A **lab-notebook tradition**: every interesting failure, surprise, or
  design pivot gets a dated markdown post in `docs/notebook/`. The
  decision logs in `eval/*/runs/*/` are the prototype; the notebook
  generalizes the format.
- **Comparative reports**: *Best decode tok/s per dollar across a year
  of Apple Silicon Macs. How `mistral-medium` quality drifted across
  three mlx-lm version bumps. Why the M5 Max's MoE routing variance
  isn't reproducible on the M4 Max.* The lab earns the right to make
  these claims by having the receipts.

## What this is not

A few non-goals worth naming out loud, because the temptation to chase
them is real and the cost of chasing them is high.

- **Not a production serving platform.** No multi-tenant auth, no quota
  management, no SLOs. Single Mac, single user.
- **Not a model-training repo.** Inference and evaluation only. Training
  belongs somewhere else.
- **Not a framework.** Each component is one file you can read in 20
  minutes. When that stops being true, we've done something wrong.
- **Not coupled to one model family.** The shim, launcher, and evaluator
  are model-agnostic. New models slot in; old models retire; the
  scaffolding outlives both.

---

*This roadmap is aspirational and directional. Specific tickets,
priorities, and dates do not live here — they live in `CHANGELOG.md`
once shipped and in conversation before then. This document exists to
keep the lab pointed somewhere coherent across months when investment
is necessarily irregular.*
