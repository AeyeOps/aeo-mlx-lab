# Environment, layout, model catalog

## Hardware / shell

- **Apple M5 Max**, 128 GB unified memory (137 GB raw, ~115 GB recommended working set), `applegpu_g17s`.
- User shell: zsh. System shell: **bash 3.2** — anything in `~/.local/bin/` must stay 3.2-compatible (no associative arrays, no `[[`-only constructs that drift).
- Terminal: **Ghostty** (`com.mitchellh.ghostty`). Set as LaunchServices default for `public.unix-executable`.

## File layout

| Path | Purpose |
| --- | --- |
| `~/.venvs/mlx/` | Python 3.14 venv (Homebrew `python@3.14`) — current install: mlx-lm 0.31.3, mlx 0.31.2 |
| `~/.local/bin/mlx-serve` | Bash launcher for `mlx_lm.server`; supports `--stop`, `--status`, `--help`, single-model |
| `~/.local/bin/ghostty-run` | One-line wrapper: `exec /usr/bin/open -na Ghostty.app --args -e "$@"` |
| `~/.config/mlx-lm/config.yaml` | **Inert** — written for a multi-model server flag that doesn't exist upstream |
| `~/.config/mlx-lm/duo.yaml` | **Inert** — same |
| `~/Library/Application Support/SwiftBar/Plugins/mlx.30s.sh` | SwiftBar menu-bar plugin (symlinked into the repo) |
| Repo root (this project) | Holds `kb/`, `shim/`, `backends/`, `eval/`, `integrations/` |
| `<repo>/tmp/mlx-<model>.log` | Per-launch server log, e.g. `tmp/mlx-gemma-26b-moe.log` |

## Model catalog

All four are verified live on HuggingFace as of 2026-05-07 (HTTP 200 for each).

| Shortcut name (in `mlx-serve`) | HF repo | Approx size | Notes |
| --- | --- | --- | --- |
| `scout` | `mlx-community/Llama-4-Scout-17B-16E-Instruct-4bit` | ~61 GB | 109B MoE / 17B active, 10M ctx, vision-capable |
| `mistral-medium` | `mlx-community/Mistral-Medium-3.5-128B-4bit` | ~73 GB | 256K ctx, frontier dense, supersedes Devstral for code |
| `gemma-31b` | `mlx-community/gemma-4-31B-it-OptiQ-4bit` | ~16 GB | OptiQ mixed-precision quant |
| `gemma-26b-moe` | `mlx-community/gemma-4-26B-A4B-it-OptiQ-4bit` | ~14 GB | 4B active params, 256K ctx — fastest, smoke-test target |

**Memory budget on 128 GB:** Mistral (~73 GB) + Gemma 26B MoE (~14 GB) = ~87 GB, fits with KV/cache headroom. Scout (~61 GB) + Mistral (~73 GB) = ~134 GB, won't fit.

**Note:** `mlx_lm.server` exposes models by full HF path — the shortcut names are local-only, the API `model` field needs the full `mlx-community/...` path.
