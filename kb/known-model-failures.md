# Known per-model loading failures

These are *upstream* issues — the SwiftBar → ghostty-run → mlx-serve → mlx_lm.server invocation path itself works. The model fails to load after launch.

## scout (`mlx-community/Llama-4-Scout-17B-16E-Instruct-4bit`)

**Symptom:** download completes (~57 GB), `mlx_lm.server` starts, then errors on first request:

```
huggingface_hub.errors.StrictDataclassFieldValidationError:
    Validation error for field 'attn_temperature_tuning':
    TypeError: Field 'attn_temperature_tuning' expected bool, got int (value: 4)
```

The `mlx_lm.server` process stays alive (FastAPI loop keeps running) but every chat completion fails because the model never loaded. `/v1/models` returns `200` but inference returns errors — so don't trust `/v1/models` as a readiness signal.

**Cause:** Llama 4 Scout's `config.json` has `attn_temperature_tuning: 4` (int), but `huggingface_hub`'s strict dataclass validator expects a bool. Mismatch is in the upstream config or the strict-validation behavior.

**Workarounds (untested here, in order of preference):**

1. Patch the cached `config.json` to coerce the field to a bool:
   ```bash
   f=~/.cache/huggingface/hub/models--mlx-community--Llama-4-Scout-17B-16E-Instruct-4bit/snapshots/*/config.json
   python3 -c "import json,glob,sys; p=glob.glob('$f')[0]; d=json.load(open(p)); d['attn_temperature_tuning']=bool(d['attn_temperature_tuning']); json.dump(d,open(p,'w'),indent=2)"
   ```
   Edits the cached snapshot only; HF re-downloads will revert it.
2. Pin `huggingface_hub` to a version with lenient validation. Check release notes around the time strict validation was added.
3. Wait for upstream to fix either Scout's config or hub's validator.

## mistral-medium (`mlx-community/Mistral-Medium-3.5-128B-4bit`)

**Symptom (observed 2026-05-07):** download made progress for ~49 minutes (7 of 15 shards complete, 8 partials underway), then went completely quiet at 03:34 — last filesystem write to any blob. Server stayed alive for 2+ more hours doing nothing but refreshing `xet-read-token` GETs (auth refresh runs every ~15 min); zero bytes of payload transferred.

**Diagnosis: HF/xet-side stall, not anything we did.** Confirmed by elimination:

| Could it have been our setup? | Answer |
| --- | --- |
| `LOAD_TIMEOUT_SEC` in test script | No — only times out the chat polling loop, doesn't kill the server or downloads |
| urlopen `INFER_TIMEOUT_SEC=300s` | No — applies only to client probe calls, not server-side download |
| mlx_lm.server / mlx-lm | Neither has a download timeout |
| huggingface_hub | Has only per-chunk read timeout, no overall-operation timeout |

Likely upstream causes: xet protocol entering a deadlocked retry state, or a transient network connection broken without a clean exception (so hub kept "trying" without progress).

**Diagnostic checks before retrying:**

```bash
# verify HF reachable + token if needed
curl -sf "https://huggingface.co/api/models/mlx-community/Mistral-Medium-3.5-128B-4bit" | python3 -m json.tool | head -5

# clear partial downloads
rm -rf ~/.cache/huggingface/hub/models--mlx-community--Mistral-Medium-3.5-128B-4bit

# launch with verbose hub logging
HF_HUB_VERBOSITY=debug ~/.local/bin/mlx-serve mistral-medium
```

## Tested-OK models

- `gemma-26b-moe` — load 31s (cached), chat 0.5s, clean response.
- `gemma-31b` — load 161s (~16 GB download + load), chat 130s (first-request weight load + inference), clean response.

Both with `enable_thinking: false` confirmed returning standard `message.content`.
