# aeo-mlx-lab

A personal lab for serving local LLMs on Apple Silicon, end-to-end.

The OpenAI-compat shim, the launcher, the SwiftBar control plugin, the
operational knowledge base, and the validation harness — all in one repo so
the system is reproducible from a clean clone.

## What's in here

```
src/aeo_mlx_lab/       Python package (single source of truth):
  shim/                  Starlette + httpx OpenAI-compat proxy on :64080
                         fronting mlx_lm.server on 127.0.0.1:64180.
  mlx_prepare.py         HF-cache verifier (resumes via snapshot_download
                         with stall detection).

backends/
  mlx-lm/              Bash launcher (mlx-serve) + per-backend model
                       registry (config.yaml). Console-script wiring
                       (mlx-shim, mlx-prepare) is via pyproject.toml.
                       More backends slot in here as siblings.

integrations/
  swiftbar/            Menu-bar control plugin (start/stop, log tails,
                       gap counter, per-model launchers).
  ghostty/             Wrapper that runs commands in a fresh Ghostty
                       window, used by SwiftBar entries.

eval/
  e2e-swiftbar/        Validation mission: SwiftBar click → real OpenAI
                       client → correct response, for all 4 configured
                       models. Generates per-iteration JSON + decision
                       log; floors are calibrated empirically.

shim/                  Bash live-e2e test (test.sh).
kb/                    Operational knowledge — model quirks, server
                       flags, version traps, GPU monitoring, the
                       SwiftBar+Ghostty pattern.
docs/                  specs/, adr/, ROADMAP.md.

pyproject.toml         single source of truth: version, deps, ruff/ty
uv.lock                exact resolved versions for reproducible installs
CHANGELOG.md, LICENSE (MIT)
```

`tmp/` (gitignored) holds runtime artifacts: `traffic.jsonl`, `gaps.jsonl`,
PID files, per-model backend logs, evaluator results.

## Ports

- **`:64080`** — shim (clients hit this; the shim is the public surface)
- **`127.0.0.1:64180`** — `mlx_lm.server` backend, loopback-only

Picked from the dynamic range to dodge collisions with Ollama (11434),
LM Studio (1234), Gradio (7860), Jupyter (8888), AirPlay (5000/7000),
Vite (5173), Spark (4040), gRPC (50051).

## Prerequisites

- macOS with Apple Silicon (M-series), tuned for M5 Max / 128 GB
- [Homebrew](https://brew.sh)
- Python 3.14 (latest stable as of this writing)
- [uv](https://docs.astral.sh/uv/) — package + venv management (`brew install uv`)
- [SwiftBar](https://swiftbar.app) — menu-bar control plugin
- [Ghostty](https://ghostty.org) — terminal (Accessibility permission required for the evaluator)
- `jq`, `macmon` — utilities used by the evaluator (`brew install jq macmon`)

## Setup on a fresh clone

```bash
# 1. Clone wherever you keep your projects, then cd in.
git clone https://github.com/AeyeOps/aeo-mlx-lab.git
cd aeo-mlx-lab

# 2. Install everything into ~/.venvs/mlx (shared with mlx-lm per CLAUDE.md).
#    uv resolves from pyproject.toml + uv.lock — exact versions, reproducible.
UV_PROJECT_ENVIRONMENT="$HOME/.venvs/mlx" uv sync

# 3. Copy the env template. Edit `.env` only if your venv / launcher / secrets
#    paths differ from the defaults documented in .env.example.
cp .env.example .env

# 4. Symlink launcher + helpers + plugin to their system locations.
#    The mlx-shim and mlx-prepare console scripts are installed into the venv
#    by step 2; we just point ~/.local/bin at them. The bash launchers resolve
#    REPO_ROOT from their own script location, so they work regardless of
#    where you cloned the repo.
mkdir -p ~/.local/bin ~/.config/mlx-lm "$HOME/Library/Application Support/SwiftBar/Plugins"
ln -s "$PWD/backends/mlx-lm/mlx-serve"        ~/.local/bin/mlx-serve
ln -s "$HOME/.venvs/mlx/bin/mlx-prepare"      ~/.local/bin/mlx-prepare
ln -s "$PWD/integrations/ghostty/ghostty-run" ~/.local/bin/ghostty-run
ln -s "$PWD/backends/mlx-lm/config.yaml"      ~/.config/mlx-lm/config.yaml
ln -s "$PWD/integrations/swiftbar/mlx.30s.sh" \
      "$HOME/Library/Application Support/SwiftBar/Plugins/mlx.30s.sh"

# 5. (Optional, only if you'll run the e2e evaluator) Create the judge-token file.
#    The evaluator reads up to 3 Claude OAuth tokens for its semantic-judge
#    LLM call, rotating across them. File is gitignored everywhere by intent.
#    The path is configurable via KEYS_ENV in .env (default below).
mkdir -p ~/.config/secrets
cat > ~/.config/secrets/keys.env <<'EOF'
CLAUDE_CODE_OAUTH_TOKEN=<your-token-1>
CLAUDE_CODE_OAUTH_TOKEN=<your-token-2>
CLAUDE_CODE_OAUTH_TOKEN=<your-token-3>
EOF
chmod 600 ~/.config/secrets/keys.env

# 6. Grant Ghostty Accessibility permission once.
#    System Settings → Privacy & Security → Accessibility → enable Ghostty.
#    Required for the evaluator's osascript-driven SwiftBar clicks.
```

After this, edits to Python in the repo take effect immediately (uv installed
the package in editable mode). Edits to the bash launchers and SwiftBar
plugin take effect immediately because they're symlinked.

## Common workflows

```bash
uv sync                          # bring venv in line with pyproject + uv.lock
uv lock --upgrade                # bump everything to latest within ranges
uv lock --upgrade-package httpx  # bump just one package
uv build                         # build a wheel (uses uv_build backend)
ruff check src/ && ruff format src/
ty check src/
```

## Quickstart

Start a model:
```bash
mlx-serve gemma-26b-moe          # or gemma-31b, mistral-medium, scout
mlx-serve --status               # backend + shim health
mlx-serve --stop                 # tear down both
```

Send a request to the shim:
```bash
curl -s http://127.0.0.1:64080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"mlx-community/gemma-4-26B-A4B-it-OptiQ-4bit",
       "messages":[{"role":"user","content":"Count to five."}],
       "max_tokens":64}' | jq .
```

Run the e2e validation across all 4 models:
```bash
bash eval/e2e-swiftbar/evaluate.sh \
  > eval/e2e-swiftbar/runs/run-0002/evaluations/iteration-0001.json \
  2> eval/e2e-swiftbar/runs/run-0002/evaluations/iteration-0001.stderr.log
```
(takes 30–120 min depending on cold/warm model loads).

## Operating principles

- **Live testing only.** No mocks, no stubs. The shim mirrors backend
  behavior; anything fake drifts from reality. See `CLAUDE.md` (local) for
  the full rule.
- **One stack at a time.** `mlx-serve` auto-stops any running backend+shim
  before starting a new one — load/unload per model for true benchmarking.
- **Honest measurement.** The evaluator samples GPU state for 5 s before
  each test; non-idle pre-test state is flagged in the JSON output so
  unstable readings can be correlated with system activity.
- **Single venv.** All Python in this repo runs in `~/.venvs/mlx`. The
  (Python, mlx, mlx-lm, transformers) tuple is pinned per
  `kb/server-flags-and-versions.md`; a second venv drifts.

## Hardware

Built and tuned on Apple **M5 Max / 128 GB unified memory**. Smaller
machines may need to drop the larger models (`mistral-medium`, `scout`)
or tighten per-model `--prompt-cache-bytes` and `--max-tokens`. See
per-model flag dispatch in `backends/mlx-lm/mlx-serve`.

## Where to read next

- `docs/ROADMAP.md` — where this lab is heading
- `docs/specs/` — design rationale for the shim and the e2e mission
- `kb/` — battle-tested operational knowledge
- `eval/e2e-swiftbar/runs/run-0001/decision-log.md` — narrative of the
  first validation run (5 iterations, the bugs we found, how the floors
  got calibrated)
