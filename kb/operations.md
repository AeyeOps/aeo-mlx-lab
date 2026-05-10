# Common operations

```bash
# status / stop
mlx-serve --status
mlx-serve --stop

# launch (single model)
mlx-serve gemma-26b-moe        # smallest, fastest — ~14 GB
mlx-serve gemma-31b            # ~16 GB
mlx-serve mistral-medium       # ~73 GB
mlx-serve scout                # ~61 GB

# verify endpoint (model id is the full HF path, not the shortcut)
curl -s http://127.0.0.1:8080/v1/models | python3 -m json.tool

# chat completion (Gemma-4 needs enable_thinking=false for standard `content`)
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "mlx-community/gemma-4-26B-A4B-it-OptiQ-4bit",
    "messages": [{"role":"user","content":"hi"}],
    "max_tokens": 64,
    "chat_template_kwargs": {"enable_thinking": false}
  }'

# live GPU/power stats (sudoless)
macmon
```
