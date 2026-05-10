# `mlx_lm.server` reality + Python/mlx-lm version compatibility

## What `mlx_lm.server` actually supports (0.31.3)

Verified via `mlx_lm.server --help` and reading
`~/.venvs/mlx/lib/python3.14/site-packages/mlx_lm/server.py`:

- **Model:** `--model <path>`, `--adapter-path`, `--draft-model`, `--num-draft-tokens`, `--trust-remote-code`, `--chat-template`, `--use-default-chat-template`, `--chat-template-args`
- **Networking:** `--host`, `--port`, `--allowed-origins`, `--log-level`
- **Sampling:** `--temp`, `--top-p`, `--top-k`, `--min-p`, `--max-tokens`
- **Throughput / cache:** `--decode-concurrency`, `--prompt-concurrency`, `--prefill-step-size`, `--prompt-cache-size`, `--prompt-cache-bytes`, `--pipeline`

## What it does NOT support (across all released mlx-lm on PyPI)

- **`--config` / YAML multi-model.** There is no built-in way to serve >1 model from one `mlx_lm.server` process. The `~/.config/mlx-lm/*.yaml` files use a vLLM-style schema (`served_model_name`, `tool_call_parser`) that `mlx_lm.server` does not parse.
- **`--max-kv-size`, `--kv-bits`, `--kv-group-size`, `--quantized-kv-start`.** These exist in `mlx_lm.generate` (the one-shot CLI), not in the HTTP server. Don't conflate the two binaries' flag sets.

When unrecognized args are passed, `mlx_lm.server` exits immediately with `unrecognized arguments`. If the launcher redirects stdout/stderr to a log, the failure is silent from outside — **always tail `/tmp/mlx-*.log` first** when a launch appears to do nothing.

## Python version trap

The venv's Python interpreter caps mlx-lm. Resolution chain hides this:

- On **Python 3.9**: `mlx-lm 0.29.1` is the ceiling.
  - `mlx-lm 0.30.2` pins `transformers==5.0.0rc1`, which requires Python ≥ 3.10.
  - `mlx-lm 0.31.x` requires `mlx>=0.31.2`, but `mlx` ships no Python 3.9 wheels past 0.29.3.
- On **Python 3.10+**: latest mlx-lm installs cleanly. `mlx 0.31.2` ships cp310–cp314 wheels.

**Current install:** rebuilt on `python3.14` (Homebrew `python@3.14`) → mlx-lm 0.31.3 + mlx 0.31.2.

Rebuild recipe:
```bash
mv ~/.venvs/mlx ~/.venvs/mlx.bak.$(date +%Y%m%d)
python3.14 -m venv ~/.venvs/mlx
~/.venvs/mlx/bin/pip install --upgrade pip
~/.venvs/mlx/bin/pip install mlx-lm
```

## Multi-model: alternatives if/when needed

Since `mlx_lm.server` is single-model only, options are:

1. **Multiple ports, one model each.** Easiest, works today. Run `mlx_lm.server --model A --port 8080` and `--model B --port 8081`. Clients pick by URL. Loses the "model in request body" pattern.
2. **`mlx-omni-server`** (PyPI) — fork claiming OpenAI-compatible multi-model. Flag set and YAML schema not yet validated against this Mac's setup.
3. **`mlx-openai-server` / `mlx-llm-server`** (PyPI) — same space, similarly unvalidated.

If we adopt (2) or (3), `~/.config/mlx-lm/duo.yaml` likely needs to be rewritten to match the chosen fork's schema.
