# Reasoning / thinking mode support per model

Verified by inspecting each model's `chat_template.jinja` directly from the mlx-community HF quant (the file the tokenizer actually applies). Source URLs in `## References` below.

## Per-model summary

| Shortcut | Model | Built-in thinking mode? | Parameter | Allowed values | Template default |
| --- | --- | --- | --- | --- | --- |
| `scout` | Llama 4 Scout 17B/16E Instruct | **No** | n/a | n/a | n/a |
| `mistral-medium` | Mistral Medium 3.5 128B | **Yes** | `reasoning_effort` | `"none"`, `"high"` (template raises on others) | `"none"` |
| `gemma-31b` | Gemma 4 31B Dense OptiQ | **Yes** | `enable_thinking` | `true` / `false` | `false`, but **see Gemma trigger quirk below** |
| `gemma-26b-moe` | Gemma 4 26B A4B MoE OptiQ | **Yes** | `enable_thinking` | `true` / `false` | `false`, **same quirk** |

## How to invoke per request

All three thinking-capable models accept the parameter via `chat_template_kwargs` in the `/v1/chat/completions` body:

```json
// Mistral Medium 3.5 — extended reasoning
{
  "model": "mlx-community/Mistral-Medium-3.5-128B-4bit",
  "messages": [...],
  "chat_template_kwargs": {"reasoning_effort": "high"}
}
```

```json
// Gemma 4 (either variant) — thinking on
{
  "model": "mlx-community/gemma-4-26B-A4B-it-OptiQ-4bit",
  "messages": [...],
  "chat_template_kwargs": {"enable_thinking": true}
}
```

For Llama 4 Scout, there's no flag — chain-of-thought happens (or doesn't) based on the prompt itself.

## Server-wide defaults via `mlx-serve`

To set a default reasoning behavior at server start, pass `--chat-template-args` (JSON) through `mlx-serve`'s extra-args slot:

```bash
mlx-serve gemma-26b-moe --chat-template-args '{"enable_thinking": false}'
mlx-serve mistral-medium --chat-template-args '{"reasoning_effort": "high"}'
```

Per-request `chat_template_kwargs` still override the server default.

## Gemma trigger quirk (important)

The Gemma 4 chat template enables thinking when **any** of the following is true (line 179 of `chat_template.jinja`):

```jinja
{%- if (enable_thinking is defined and enable_thinking)
       or tools
       or messages[0]['role'] in ['system', 'developer'] -%}
```

Practical consequence: **a request with a system message triggers thinking mode, even without `enable_thinking=true`**. The response then contains `message.reasoning` and an empty `message.content` — same failure mode as explicitly opting in.

Workarounds:
- Drop the system message and put system instructions into the first user turn, or
- Explicitly pass `chat_template_kwargs: {"enable_thinking": false}` — but note: because the template's `if` is an `or`, **`enable_thinking=false` does NOT override a system-message trigger**. The `false` only suppresses the first clause; the system clause still fires.
- The only reliable way to fully suppress thinking on Gemma 4 is to *also* avoid system messages and tools.

This is a Gemma-template behavior, not an mlx-lm bug.

## Output shape when thinking is on

mlx-lm 0.31.3 returns the reasoning trace in:

```json
"choices": [{"message": {"role": "assistant", "reasoning": "..."}}]
```

Note: this is `message.reasoning`, not OpenAI's `message.reasoning_content` (used by o1/o3 models). Standard OpenAI clients reading `message.content` get an empty string.

## References

- Gemma 4 26B A4B (local): `~/.cache/huggingface/hub/models--mlx-community--gemma-4-26B-A4B-it-OptiQ-4bit/.../chat_template.jinja`
- Gemma 4 31B: `https://huggingface.co/mlx-community/gemma-4-31B-it-OptiQ-4bit/resolve/main/chat_template.jinja`
- Mistral Medium 3.5: `https://huggingface.co/mlx-community/Mistral-Medium-3.5-128B-4bit/resolve/main/chat_template.jinja`
- Llama 4 Scout: `https://huggingface.co/mlx-community/Llama-4-Scout-17B-16E-Instruct-4bit/resolve/main/tokenizer_config.json` (chat_template field; no thinking hooks)
- Google Gemma thinking docs: `https://ai.google.dev/gemma/docs/capabilities/thinking`
- Mistral Medium 3.5 reasoning announcement: `https://mistral.ai/news/vibe-remote-agents-mistral-medium-3-5`
