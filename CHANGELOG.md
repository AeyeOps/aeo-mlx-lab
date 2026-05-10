# Changelog

All notable changes to **aeo-mlx-lab** are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it
reaches `1.0.0`.

## [Unreleased]

## [0.1.0] - 2026-05-09

### Changed
- **Path-agnostic scripts + `.env` for local overrides** — bash launchers (`mlx-serve`, `mlx.30s.sh`, `evaluate.sh`, `test.sh`) now derive `REPO_ROOT` from their own script location (following symlinks) instead of hardcoding `$HOME/Developer/aeo/aeo-mlx-lab`. Anything that legitimately differs per machine — venv path, launcher symlinks, judge-token file, claude binary — is read from `.env` (gitignored) with sensible defaults that match the README install. A tracked `.env.example` documents every key.
- **Python entry points load `.env`** — `python-dotenv` added as a dep; `mlx-shim` and `mlx-prepare` call `aeo_mlx_lab.load_env()` at startup so direct invocations (not just via `mlx-serve`) pick up the same overrides. Existing process env always wins.
- **`mlx-prepare` uses `sys.executable`** instead of a hardcoded venv-python path for the `snapshot_download` subprocess.
- **Adopted Astral toolchain** — pyproject.toml is now the single source of truth for version, dependencies, and tooling config. `uv` manages the venv and lockfile, `ruff` lints + formats, `ty` (Astral's type checker, beta) type-checks. Aligns with AeyeOps repo conventions.
- **Restructured Python into a real package** — `shim/server.py` and `shim/logs.py` moved to `src/aeo_mlx_lab/shim/`; `backends/mlx-lm/mlx-prepare` moved to `src/aeo_mlx_lab/mlx_prepare.py`. The `shim/` and `backends/mlx-lm/` directories now hold only bash artifacts (`shim/test.sh`, `backends/mlx-lm/{mlx-serve, config.yaml}`).
- **Console scripts via `[project.scripts]`** — `mlx-shim` (the proxy entry) and `mlx-prepare` (the cache verifier) are installed by uv into `~/.venvs/mlx/bin/`. The bash launcher `mlx-serve` calls `python -m aeo_mlx_lab.shim.server`; the system-level `~/.local/bin/mlx-prepare` is a symlink to the venv's console script.
- **Dependency style** — pyproject uses `>=current_minor,<next_major` ranges (e.g., `starlette>=0.52,<1.0`). Reproducibility comes from the committed `uv.lock`, not from minor-version pins. `pip install -r requirements.lock` workflow replaced with `uv sync`.
- **Linted + formatted** — ruff + ty pass clean across the package.

### Removed
- `shim/requirements.txt` and `shim/requirements.lock` — superseded by `pyproject.toml [project.dependencies]` + `uv.lock`.

### Added
- Initial repo layout: `shim/`, `backends/mlx-lm/`, `integrations/{swiftbar,ghostty}/`, `eval/e2e-swiftbar/`, `kb/`, `docs/{specs,adr}/`.
- `shim/server.py` — Starlette + httpx OpenAI-compat proxy on `:64080` fronting `mlx_lm.server` on `127.0.0.1:64180`. Includes:
  - `x-shim-request-id` response header (written direct to `raw_headers` to bypass Starlette's MutableHeaders cache trap).
  - `MLX_SHIM_MAX_BODY_BYTES` request-size guardrail (default 50 MiB).
  - `traffic.jsonl` and `gaps.jsonl` rolling structured logs with header redaction.
- `backends/mlx-lm/mlx-serve` — bash 3.2 launcher owning lifecycle for both backend (`mlx_lm.server`) and shim. PID files at `tmp/mlx-<model>.pid` + `tmp/mlx-shim.pid`; `--stop` and `--status` subcommands.
- `backends/mlx-lm/mlx-prepare` — Python helper that verifies an mlx-community model is fully cached (HF API authoritative file list + size check) before the launcher starts the backend; resumes via `snapshot_download` with stall detection.
- `backends/mlx-lm/config.yaml` — model registry (currently inert; mlx-lm 0.31.x has no `--config` flag, but kept as source of truth for per-model intent).
- `integrations/swiftbar/mlx.30s.sh` — SwiftBar plugin reporting backend+shim status, gap counts, and per-model start/stop entries.
- `integrations/ghostty/ghostty-run` — `open -na Ghostty.app -e <cmd>` wrapper used by SwiftBar to launch interactive entries in Ghostty.
- `eval/e2e-swiftbar/evaluate.sh` — end-to-end validation harness covering all 4 configured models. Per-model checks: `x-shim-request-id` header, instruction-following (digits 1–5 in order), no-refusal, performance (tok/s vs floor), semantic coherence (LLM-judge), traffic-pairing, and zero gaps. Includes:
  - PID-file-based loaded-model verification (mlx-lm's `/v1/models` lists ALL configured models, so it's not a reliable signal).
  - 5-second pre-test GPU-idle sample via `macmon pipe -i 500` to flag competing GPU activity that would skew measurement.
  - Random-shuffled OAuth-token rotation with retry, falling back across all 3 tokens before giving up on the judge.
  - `launchctl setenv MLX_BACKEND_READY_TIMEOUT` propagation so the timeout reaches `mlx-serve` inside the SwiftBar→Ghostty session (which `open -na` would otherwise strip).
  - EXIT/INT/TERM trap that always runs `mlx-serve --stop` on script exit.
- `eval/e2e-swiftbar/runs/run-0001/decision-log.md` — chronological per-iteration narrative for the first run (5 iterations, first PASS at iteration 5 after diagnosing model-mismatch race, mlx-lm `/v1/models` semantics, MoE perf variance, and KB-baseline-vs-e2e measurement mismatch).
- `eval/e2e-swiftbar/baselines.json` — per-model first-run e2e tok/s baselines (used as the basis for per-model floors via the 80% rule).
- `kb/` — 8 knowledge-base articles (environment, server flags, swiftbar/ghostty integration, model-specific failures and reasoning modes, GPU utilization monitoring, operations).
- `docs/specs/` — design specs for the shim and the e2e autoresearch mission.

### Notes
- This release is the initial import; no prior versions exist.
- The repo absorbs work that was previously scattered across `~/Developer/mlx-server/` (shim, kb, docs), `~/.local/bin/` (launcher, helpers), `~/Library/Application Support/SwiftBar/Plugins/` (status plugin), and `.omc/autoresearch/` (transient evaluator artifacts produced via the OMC autoresearch skill — only OUR products are imported, not the framework itself).
- System integration is via symlinks from canonical system locations into the repo, so edits in the repo take effect immediately. See `README.md` for symlink setup.
