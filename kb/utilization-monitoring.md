# Confirming MLX is fully using the GPU

## Tool: `macmon`

```bash
brew install macmon
```

Sudoless. Uses Apple's IOReport private API. Supports M1–M5. Has TUI, JSON pipe (`macmon pipe`), and HTTP server modes (`macmon serve` exposes Prometheus + JSON).

```bash
# live TUI
macmon

# JSON stream, 1s interval, parseable
macmon pipe -i 1000

# 30s sample to file while a generation runs
macmon pipe -i 1000 > /tmp/m.jsonl &
# ...kick off /v1/chat/completions...
kill %1
```

## What "fully utilized" looks like

Reference numbers from gemma-26b-moe (4-bit, 4B active) on M5 Max generating 1200 tokens:

| Metric | Idle | Under load |
| --- | --- | --- |
| GPU utilization | ~1.5% | **100% (every 1s sample)** |
| GPU frequency | 338 MHz | **1620 MHz (pegged at max)** |
| GPU power | ~0.07 W | **24–26 W** (~360× idle) |
| ANE power | 0 W | **0 W** — MLX never uses ANE; expected |
| Total package | ~0.5 W | ~32 W |
| pcpu utilization | ~2% | ~17–20% (Metal dispatch overhead) |
| Throughput | n/a | 92.6 tok/s decode |

## Failure signatures

- **GPU power stays low (<5 W) during inference** → MLX silently fell back to CPU. Check `mx.default_device()`; look for stray `mx.set_default_device(mx.cpu)` calls.
- **pcpu pegged across all cores while GPU idle** → CPU-bound, probably an unsupported op forcing CPU fallback for a hot kernel.
- **GPU < 100% with low CPU and slow tok/s** → memory-bandwidth-bound (rare for inference) or pipeline stall — try increasing `--prefill-step-size`, `--decode-concurrency`.
- **ANE > 0 W** → not from MLX. Something else on the system is using Core ML.

## Other tools (for reference, not currently installed)

- `asitop` (PyPI, tlkh/asitop) — Python; needs sudo (wraps `powermetrics`). More mature, less convenient.
- `mactop` (Go, context-labs/mactop or metaspartan/mactop) — TUI; metaspartan fork is sudoless via IOReport.
- `pumas` (Rust, graelo/pumas) — power-focused.
- macOS Activity Monitor → Window → GPU History — graphical, no install.
