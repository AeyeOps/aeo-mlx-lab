# Gemma-4 OptiQ models default to thinking mode

Affects (at minimum) `mlx-community/gemma-4-26B-A4B-it-OptiQ-4bit` and likely `mlx-community/gemma-4-31B-it-OptiQ-4bit`.

## Symptom

A normal `/v1/chat/completions` request returns:

```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "reasoning": "<chain of thought>"
    },
    "finish_reason": "length"
  }]
}
```

There is **no `message.content`** — only `message.reasoning`. OpenAI-standard clients that read `content` get an empty string.

The reasoning trace also burns tokens fast. Short prompts can hit `max_tokens` mid-reasoning before the model emits the final answer, so `finish_reason: "length"` shows up unexpectedly.

## Fix (per request)

```json
{
  "model": "mlx-community/gemma-4-26B-A4B-it-OptiQ-4bit",
  "messages": [{"role": "user", "content": "..."}],
  "chat_template_kwargs": {"enable_thinking": false}
}
```

Response then comes back with standard `message.content` populated.

## Fix (server-wide default)

Pass to `mlx_lm.server`:

```
--chat-template-args '{"enable_thinking": false}'
```

Add this to `DEFAULT_ARGS` in `~/.local/bin/mlx-serve` if you want every request to default to non-thinking mode. Per-request overrides still work via `chat_template_kwargs`.
