"""mlx-lm OpenAI-compat shim.

Phase A: non-streaming proxy + allowlist + gap capture.
Phase B: SSE streaming relay with mid-flight error capture and bounded buffer.

See docs/superpowers/specs/2026-05-07-mlx-lm-openai-compat-shim-design.md.
"""

from __future__ import annotations

import asyncio
import json
import os
import time
import traceback
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager, suppress
from typing import Any

import httpx
import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

from aeo_mlx_lab.shim.logs import redact_headers, write_gap, write_traffic

# Per-endpoint OpenAI field allowlist. Any top-level key in a request JSON body
# that is NOT in the endpoint's set produces a kind:"unknown_field" gap entry.
# The field is forwarded unchanged. Source: plan Task 6 allowlist contents.
# Paths not in this dict (e.g. /v1/models) are not scanned — no body expected.
OPENAI_ALLOWLIST: dict[str, set[str]] = {
    "/v1/chat/completions": {
        "model",
        "messages",
        "temperature",
        "top_p",
        "n",
        "stream",
        "stop",
        "max_tokens",
        "max_completion_tokens",
        "presence_penalty",
        "frequency_penalty",
        "logit_bias",
        "user",
        "response_format",
        "seed",
        "tools",
        "tool_choice",
        "parallel_tool_calls",
        "logprobs",
        "top_logprobs",
        "service_tier",
        "stream_options",
        "store",
        "metadata",
        "reasoning_effort",
        "audio",
        "modalities",
        "prediction",
        # mlx-lm extension fields (not OpenAI-standard but accepted by backend)
        "top_k",
        "chat_template_kwargs",
    },
    "/v1/completions": {
        "model",
        "prompt",
        "suffix",
        "max_tokens",
        "temperature",
        "top_p",
        "n",
        "stream",
        "logprobs",
        "echo",
        "stop",
        "presence_penalty",
        "frequency_penalty",
        "best_of",
        "logit_bias",
        "user",
        "seed",
        "stream_options",
    },
    "/v1/embeddings": {
        "model",
        "input",
        "encoding_format",
        "dimensions",
        "user",
    },
}

# Hop-by-hop response headers we strip before relaying back to the client.
# Per RFC 7230 §6.1; httpx/Starlette would otherwise mis-frame the response.
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    # Content-Length / Content-Encoding are recomputed by Starlette from the body bytes.
    "content-length",
    "content-encoding",
}


# Streaming join-buffer cap (Phase B "Settled Decision"). On overflow, we
# stop appending to the in-memory buffer used for the close-time traffic
# entry and emit a kind:"stream_truncated" gap once. The relay to the
# client is unaffected — observability is best-effort, the proxy is not.
# Override via env var MLX_SHIM_STREAM_BUFFER_BYTES (e.g., to small caps for
# Phase B verification scenarios). Default 16 MiB (plan "Open questions" table).
def _stream_buffer_cap() -> int:
    raw = os.environ.get("MLX_SHIM_STREAM_BUFFER_BYTES")
    if raw is None:
        return 16 * 1024 * 1024
    try:
        n = int(raw)
        if n <= 0:
            return 16 * 1024 * 1024
        return n
    except ValueError:
        return 16 * 1024 * 1024


# Chunk size for httpx aiter_raw. 16 KiB balances syscall count vs. latency.
_STREAM_CHUNK_SIZE = 16 * 1024


def _backend_url() -> str:
    return os.environ.get("MLX_BACKEND_URL", "http://127.0.0.1:64180")


def _backend_host_port() -> tuple[str, int]:
    """Parse host+port out of MLX_BACKEND_URL for the TCP health probe."""
    url = httpx.URL(_backend_url())
    host = url.host or "127.0.0.1"
    port = url.port or (443 if url.scheme == "https" else 80)
    return host, port


# --- backend health: TCP connect with 100 ms timeout, 2 s cache -----------
# Timeout is 100 ms per plan "Open questions — pinned answers" table.

_HEALTH_TTL = 2.0
_HEALTH_TIMEOUT = 0.1
_health_state: dict[str, Any] = {"ts": 0.0, "up": False}
_health_lock = asyncio.Lock()


async def _probe_backend() -> bool:
    host, port = _backend_host_port()
    try:
        fut = asyncio.open_connection(host, port)
        _reader, writer = await asyncio.wait_for(fut, timeout=_HEALTH_TIMEOUT)
        writer.close()
        with suppress(Exception):
            await writer.wait_closed()
        return True
    except Exception:
        return False


async def backend_is_up() -> bool:
    """Return cached backend liveness. Lock-free fast path on cache hits.

    Python dict reads are GIL-atomic; a stale read within the 2 s TTL is
    acceptable. The lock is acquired only when a probe is needed, and
    re-checked under the lock to avoid redundant concurrent probes.
    """
    now = time.monotonic()
    if now - _health_state["ts"] < _HEALTH_TTL:  # lock-free fast path
        return bool(_health_state["up"])
    async with _health_lock:
        if now - _health_state["ts"] < _HEALTH_TTL:  # re-check under lock
            return bool(_health_state["up"])
        up = await _probe_backend()
        # Stamp the cache with the post-probe time so a slow probe doesn't
        # under-report TTL on the next request.
        _health_state["ts"] = time.monotonic()
        _health_state["up"] = up
        return up


# --- per-endpoint hook registry -------------------------------------------
#
# Hooks are called in _proxy() before and after the backend call. A buggy
# hook MUST NOT take down the proxy — _call_hook catches all exceptions and
# emits a kind:"hook_error" gap instead of propagating.
#
# Registry shape: {path: {"pre": fn, "post": fn}}
# Default: empty — no hooks registered. Wire a hook by assigning here.
#
# Hooks are observability-only. Their return values are discarded by
# _call_hook's call sites — they cannot mutate the forwarded body.
#
# Pre-hook signature:  fn(parsed_body: Any) -> Any   (sync or async)
#   Called with the parsed inbound JSON body before backend forwarding.
# Post-hook signature: fn(parsed_resp: Any) -> Any   (sync or async)
#   Called with the parsed backend response body before outbound traffic log.
#
# _call_hook handles both sync and async hooks transparently. A buggy hook
# emits kind:"hook_error" and is treated as a no-op.
#
_HOOK_REGISTRY: dict[str, dict[str, Callable]] = {}


async def _call_hook(hook_fn: Callable, *args: Any, request_id: str, hook_name: str) -> None:
    """Run an observability hook with all exceptions captured.

    Supports both sync and async hook functions: if hook_fn returns a
    coroutine, it is awaited. Hook return values are intentionally not
    propagated — call sites discard them. A failing hook emits a
    kind:"hook_error" gap and is treated as a no-op so a buggy patch
    cannot take down the proxy.
    """
    try:
        result = hook_fn(*args)
        if asyncio.iscoroutine(result):
            await result
    except Exception as e:
        write_gap(
            {
                "request_id": request_id,
                "kind": "hook_error",
                "hook": hook_name,
                "error": f"{type(e).__name__}: {e}",
                "error_type": type(e).__name__,
            }
        )


# --- lifespan: shared httpx.AsyncClient ------------------------------------


@asynccontextmanager
async def lifespan(app: Starlette):
    timeout = httpx.Timeout(connect=5.0, read=600.0, write=30.0, pool=30.0)
    client = httpx.AsyncClient(base_url=_backend_url(), timeout=timeout)
    app.state.http = client
    try:
        yield
    finally:
        await client.aclose()


# --- helpers ---------------------------------------------------------------


def _new_request_id() -> str:
    return uuid.uuid4().hex[:12]


def _try_parse_json(raw: bytes) -> tuple[Any | None, bool]:
    """Returns (parsed_or_None, parsed_ok). Empty body -> (None, True)."""
    if not raw:
        return None, True
    try:
        return json.loads(raw.decode("utf-8")), True
    except Exception:
        return None, False


def _body_kind(raw: bytes, parsed: Any, parsed_ok: bool) -> str:
    """Classify a body for the body_kind field on traffic entries.

    Spec: "Bodies: parsed JSON when possible; else raw string with
    body_kind:'raw' flag." Plan Task 3 uses "empty"|"json"|"raw".
    """
    if not raw:
        return "empty"
    if parsed_ok and parsed is not None:
        return "json"
    return "raw"


# Maximum request body size accepted before short-circuiting with 413.
# Override via MLX_SHIM_MAX_BODY_BYTES. Default 50 MiB — generous for legit
# OpenAI-shaped requests (long chat history, embedding inputs) but bounded
# so a misbehaving or hostile client cannot allocate unbounded memory
# through the shim. The check honors the Content-Length header; chunked-
# encoded requests bypass it (rare for OpenAI clients, and tightening that
# path would require stream-reading every body — not justified for the
# single-Mac scope today).
def _max_body_bytes() -> int:
    raw = os.environ.get("MLX_SHIM_MAX_BODY_BYTES")
    if raw is None:
        return 50 * 1024 * 1024
    try:
        n = int(raw)
        if n <= 0:
            return 50 * 1024 * 1024
        return n
    except ValueError:
        return 50 * 1024 * 1024


def _reject_if_too_large(
    request: Request, request_id: str, path: str, method: str
) -> Response | None:
    """Pre-flight body-size check. Returns 413 Response on overflow, None to proceed.

    Emits a kind:"body_too_large" gap with content_length + cap so the
    rejection leaves a trace per the spec's "no path leaves no trace"
    invariant. Does NOT write a dir:"in" traffic entry — by design the
    body is never read (it's too big), so there is no body to log; the
    gap carries all available context.
    """
    cap = _max_body_bytes()
    raw_cl = request.headers.get("content-length")
    if raw_cl is None:
        return None
    try:
        cl = int(raw_cl)
    except ValueError:
        return None
    if cl <= cap:
        return None
    write_gap(
        {
            "request_id": request_id,
            "kind": "body_too_large",
            "path": path,
            "method": method,
            "content_length": cl,
            "cap": cap,
        }
    )
    return JSONResponse(
        {
            "error": {
                "message": "request body too large",
                "type": "body_too_large",
                "request_id": request_id,
                "max_bytes": cap,
            }
        },
        status_code=413,
    )


def _filter_response_headers(headers: httpx.Headers) -> list[tuple[bytes, bytes]]:
    out: list[tuple[bytes, bytes]] = []
    for k, v in headers.raw:
        if k.decode("latin-1").lower() in HOP_BY_HOP:
            continue
        out.append((k, v))
    return out


def _scan_unknown_fields(body: Any, request_id: str, path: str) -> None:
    """Emit one kind:'unknown_field' gap per top-level key outside the per-endpoint allowlist.

    If path is not in OPENAI_ALLOWLIST (e.g. /v1/models has no body), skip scanning.
    """
    if not isinstance(body, dict):
        return
    allowed = OPENAI_ALLOWLIST.get(path)
    if allowed is None:
        return
    for key in body:
        if key not in allowed:
            write_gap(
                {
                    "request_id": request_id,
                    "kind": "unknown_field",
                    "field": key,
                    "path": path,
                }
            )


async def _proxy(request: Request, request_id: str) -> Response:
    """Proxy entry point. Routes stream:true to the SSE relay, else buffers."""
    method = request.method
    path = request.url.path
    too_large = _reject_if_too_large(request, request_id, path, method)
    if too_large is not None:
        return too_large
    raw_body = await request.body()
    in_headers = dict(request.headers)
    parsed_body, _ok = _try_parse_json(raw_body)

    # Inbound traffic entry.
    write_traffic(
        {
            "request_id": request_id,
            "dir": "in",
            "method": method,
            "path": path,
            "headers": redact_headers(in_headers),
            "body": parsed_body
            if parsed_body is not None
            else (raw_body.decode("utf-8", errors="replace") if raw_body else None),
            "body_kind": _body_kind(raw_body, parsed_body, _ok),
        }
    )

    # Allowlist scan on JSON bodies for known endpoints.
    if isinstance(parsed_body, dict):
        _scan_unknown_fields(parsed_body, request_id, path)

    # Pre-flight backend health.
    if not await backend_is_up():
        write_gap(
            {
                "request_id": request_id,
                "kind": "backend_down",
                "path": path,
                "method": method,
            }
        )
        return JSONResponse(
            {
                "error": {
                    "message": "backend unavailable",
                    "type": "backend_down",
                    "request_id": request_id,
                }
            },
            status_code=503,
        )

    # Strip hop-by-hop request headers before forwarding. httpx will set
    # host/content-length itself. Also strip accept-encoding: if the backend
    # ever compresses, aiter_raw() would return raw compressed bytes while
    # content-encoding is stripped (it's in HOP_BY_HOP), delivering garbage
    # to the client. Removing accept-encoding prevents compression at source.
    fwd_headers = {
        k: v
        for k, v in in_headers.items()
        if k.lower()
        not in {
            "host",
            "content-length",
            "connection",
            "keep-alive",
            "transfer-encoding",
            "accept-encoding",
        }
    }

    # Pre hooks: called after inbound log + allowlist scan, before backend call.
    endpoint_hooks = _HOOK_REGISTRY.get(path, {})
    pre_fn = endpoint_hooks.get("pre")
    if pre_fn is not None:
        await _call_hook(pre_fn, parsed_body, request_id=request_id, hook_name=f"pre_{path}")

    # Streaming branch: only chat/completions and completions ever set
    # stream:true; embeddings and models do not. We route by parsed body
    # rather than path so a hypothetical stream:true on an unsupported
    # endpoint still flows through the upstream (and likely produces a
    # backend_status gap), preserving the spec's "log everything" stance.
    if isinstance(parsed_body, dict) and parsed_body.get("stream") is True:
        return await _stream_proxy(
            request=request,
            request_id=request_id,
            method=method,
            path=path,
            raw_body=raw_body,
            fwd_headers=fwd_headers,
        )

    client: httpx.AsyncClient = request.app.state.http
    try:
        upstream = await client.request(
            method=method,
            url=path,
            params=dict(request.query_params),
            content=raw_body or None,
            headers=fwd_headers,
        )
    except httpx.HTTPError as e:
        write_gap(
            {
                "request_id": request_id,
                "kind": "backend_error",
                "path": path,
                "method": method,
                "error": f"{type(e).__name__}: {e}",
            }
        )
        return JSONResponse(
            {
                "error": {
                    "message": "backend error",
                    "type": "backend_error",
                    "request_id": request_id,
                }
            },
            status_code=502,
        )

    resp_bytes = upstream.content
    if upstream.status_code >= 400:
        write_gap(
            {
                "request_id": request_id,
                "kind": "backend_status",
                "status": upstream.status_code,
                "path": path,
                "method": method,
            }
        )

    parsed_resp, resp_ok = _try_parse_json(resp_bytes)

    # Post hooks: called after backend response is built, before outbound traffic log.
    post_fn = endpoint_hooks.get("post")
    if post_fn is not None:
        await _call_hook(post_fn, parsed_resp, request_id=request_id, hook_name=f"post_{path}")

    write_traffic(
        {
            "request_id": request_id,
            "dir": "out",
            "status": upstream.status_code,
            "headers": redact_headers(dict(upstream.headers)),
            "body": parsed_resp
            if parsed_resp is not None
            else (resp_bytes.decode("utf-8", errors="replace") if resp_bytes else None),
            "body_kind": _body_kind(resp_bytes, parsed_resp, resp_ok),
        }
    )

    # Build the outbound response with hop-by-hop headers stripped.
    raw_headers = _filter_response_headers(upstream.headers)
    out = Response(content=resp_bytes, status_code=upstream.status_code)
    # Replace Starlette's auto headers with the filtered upstream set, then
    # re-add the recomputed content-length (Response.__init__ already set it
    # based on resp_bytes; preserve that one).
    preserved_cl = out.headers.get("content-length")
    out.raw_headers = raw_headers
    if preserved_cl is not None:
        out.raw_headers.append((b"content-length", preserved_cl.encode("latin-1")))
    return out


async def _stream_proxy(
    *,
    request: Request,
    request_id: str,
    method: str,
    path: str,
    raw_body: bytes,
    fwd_headers: dict[str, str],
) -> Response:
    """SSE streaming relay.

    Opens the upstream response with stream=True, captures status+headers,
    and returns a StreamingResponse whose async generator:
      * yields each raw chunk to the client unmodified (bytes-faithful);
      * appends to an in-memory join buffer up to MLX_SHIM_STREAM_BUFFER_BYTES
        (default 16 MiB), past which it stops appending and emits a single
        kind:"stream_truncated" gap (relay continues unchanged);
      * on first chunk, writes a single dir:"out" traffic entry with
        kind:"stream_open" recording status + headers;
      * on close (normal or exception), writes one dir:"out" traffic entry
        with the joined body decoded utf-8 errors=replace, plus a
        truncation marker if applicable;
      * on mid-flight exception, writes a kind:"stream_error" gap with
        bytes_seen + error_type + error string, then re-raises so the
        client connection breaks naturally.

    Note on non-2xx upstream responses: when upstream returns >=400, a
    kind:"backend_status" gap is emitted BEFORE iteration starts. body_iter
    then runs (yielding the error body). If the error body is empty,
    opened_logged stays False and the stream_close entry appears without a
    preceding stream_open — this is expected and not a bug. A log reader
    should treat backend_status + stream_close (no stream_open) as a
    complete, failed streaming call.

    The upstream response handle (httpx.Response) is owned by this
    function; we close it in finally to release the underlying connection
    back to the pool whether the client cancelled, the upstream died, or
    we drained successfully.
    """
    client: httpx.AsyncClient = request.app.state.http
    cap = _stream_buffer_cap()

    # Open the upstream stream. This is awaited (not entered as a CM) so
    # we can hand the response object's lifecycle to the generator below.
    req = client.build_request(
        method=method,
        url=path,
        params=dict(request.query_params),
        content=raw_body or None,
        headers=fwd_headers,
    )
    try:
        upstream = await client.send(req, stream=True)
    except httpx.HTTPError as e:
        write_gap(
            {
                "request_id": request_id,
                "kind": "backend_error",
                "path": path,
                "method": method,
                "error": f"{type(e).__name__}: {e}",
            }
        )
        return JSONResponse(
            {
                "error": {
                    "message": "backend error",
                    "type": "backend_error",
                    "request_id": request_id,
                }
            },
            status_code=502,
        )

    # If the upstream returned a non-2xx, log a backend_status gap. We
    # still relay the (likely small) error body to the client via the
    # stream — observability is symmetric with the buffered path.
    if upstream.status_code >= 400:
        write_gap(
            {
                "request_id": request_id,
                "kind": "backend_status",
                "status": upstream.status_code,
                "path": path,
                "method": method,
            }
        )

    upstream_status = upstream.status_code
    # Snapshot headers before iteration begins; httpx exposes a stable
    # Headers object on the response.
    upstream_headers_redacted = redact_headers(dict(upstream.headers))
    raw_response_headers = _filter_response_headers(upstream.headers)

    async def body_iter() -> AsyncIterator[bytes]:
        buf = bytearray()
        bytes_seen = 0
        truncated_at: int | None = None
        opened_logged = False
        error_logged = False
        try:
            async for chunk in upstream.aiter_raw(chunk_size=_STREAM_CHUNK_SIZE):
                if not chunk:
                    continue
                if not opened_logged:
                    # First byte to the client — log the stream-open
                    # marker so a viewer of traffic.jsonl sees the open
                    # before the close.
                    write_traffic(
                        {
                            "request_id": request_id,
                            "dir": "out",
                            "kind": "stream_open",
                            "status": upstream_status,
                            "headers": upstream_headers_redacted,
                            "stream": True,
                            "body": None,
                        }
                    )
                    opened_logged = True

                bytes_seen += len(chunk)
                if truncated_at is None:
                    if len(buf) + len(chunk) <= cap:
                        buf.extend(chunk)
                    else:
                        # Append what fits, then mark truncated and emit
                        # the gap exactly once.
                        room = cap - len(buf)
                        if room > 0:
                            buf.extend(chunk[:room])
                        truncated_at = bytes_seen
                        write_gap(
                            {
                                "request_id": request_id,
                                "kind": "stream_truncated",
                                "bytes_seen": bytes_seen,
                                "cap": cap,
                                "path": path,
                            }
                        )

                # Relay the chunk to the client UNMODIFIED, regardless
                # of buffer state. This is the load-bearing semantic:
                # the proxy must not throttle or re-encode the stream.
                yield bytes(chunk)
        except BaseException as e:
            # Mid-flight failure (httpx.RemoteProtocolError, ReadError,
            # CancelledError on client disconnect, etc.). Capture context
            # then re-raise so Starlette tears the connection down.
            write_gap(
                {
                    "request_id": request_id,
                    "kind": "stream_error",
                    "path": path,
                    "error": str(e),
                    "error_type": type(e).__name__,
                    "bytes_seen": bytes_seen,
                }
            )
            error_logged = True
            raise
        finally:
            # Build the close-time traffic entry. We always emit one
            # dir:"out" close entry per stream that opened OR errored,
            # so a reader can reconstruct the call from request_id alone.
            try:
                body_text = buf.decode("utf-8", errors="replace") if buf else ""
                if truncated_at is not None:
                    body_text = body_text + f"\n[truncated_at_bytes={truncated_at}]"
                close_entry: dict[str, Any] = {
                    "request_id": request_id,
                    "dir": "out",
                    "kind": "stream_close",
                    "status": upstream_status,
                    "stream": True,
                    "bytes_seen": bytes_seen,
                    "truncated": truncated_at is not None,
                    "body": body_text if (opened_logged or bytes_seen > 0) else None,
                    # SSE chunks are concatenated text; never JSON-parsed.
                    "body_kind": "raw" if (opened_logged or bytes_seen > 0) else "empty",
                }
                if error_logged:
                    close_entry["errored"] = True
                write_traffic(close_entry)
            finally:
                # Always release the upstream connection. aclose is
                # idempotent on httpx.Response.
                with suppress(Exception):
                    await upstream.aclose()

    # Build the StreamingResponse with the filtered upstream headers
    # (hop-by-hop stripped). We do NOT set Content-Length — the relay is
    # chunked. Starlette handles chunked transfer-encoding via the ASGI
    # body messages; uvicorn sets transfer-encoding for HTTP/1.1.
    resp = StreamingResponse(
        body_iter(),
        status_code=upstream_status,
    )
    # Replace Starlette's headers with the filtered upstream set. We
    # deliberately drop content-length (already in HOP_BY_HOP) since the
    # body length is unknown at header time.
    resp.raw_headers = list(raw_response_headers)
    return resp


def _wrap(handler: Callable[[Request, str], Awaitable[Response]]):
    """Per-route try/except: any unhandled exception becomes kind:'exception'.

    Also sets X-Shim-Request-Id on every response (plan Tasks 3, 4, 8, 9 + spec).
    """

    async def inner(request: Request) -> Response:
        request_id = _new_request_id()
        try:
            resp = await handler(request, request_id)
        except Exception as e:
            write_gap(
                {
                    "request_id": request_id,
                    "kind": "exception",
                    "path": request.url.path,
                    "method": request.method,
                    "error": f"{type(e).__name__}: {e}",
                    "traceback": traceback.format_exc(),
                }
            )
            resp = JSONResponse(
                {
                    "error": {
                        "message": "shim exception",
                        "type": "exception",
                        "request_id": request_id,
                    }
                },
                status_code=500,
            )
        # Attach X-Shim-Request-Id by writing directly to raw_headers.
        # NB: cannot use `resp.headers[k] = v` here because Starlette caches
        # the MutableHeaders proxy on first access, bound to the raw_headers
        # list at THAT moment. _proxy() and _stream_proxy() both reassign
        # .raw_headers to a filtered copy of the upstream headers AFTER that
        # cache is populated (when checking content-length pre-rebuild), so
        # the proxy ends up writing to a list no longer attached to the
        # response. ASGI sends from self.raw_headers — that's the source of
        # truth, and that's where we append.
        resp.raw_headers.append((b"x-shim-request-id", request_id.encode("latin-1")))
        return resp

    return inner


# --- route handlers --------------------------------------------------------


async def healthz(request: Request) -> Response:
    return JSONResponse({"ok": True})


async def chat_completions(request: Request, request_id: str) -> Response:
    return await _proxy(request, request_id)


async def completions(request: Request, request_id: str) -> Response:
    return await _proxy(request, request_id)


async def embeddings(request: Request, request_id: str) -> Response:
    return await _proxy(request, request_id)


async def models(request: Request, request_id: str) -> Response:
    return await _proxy(request, request_id)


async def catch_all(request: Request, request_id: str) -> Response:
    # catch_all never forwards to the backend — it short-circuits to 404 +
    # unknown_path gap. Health-gating it would only add latency to pure 404s
    # and mask the gap as backend_status instead of unknown_path.
    #
    # Per spec "no path leaves no trace": still write a dir:"in" traffic
    # entry so the request envelope (headers, body) is recorded alongside
    # the unknown_path gap.
    method = request.method
    path = request.url.path
    too_large = _reject_if_too_large(request, request_id, path, method)
    if too_large is not None:
        return too_large
    raw_body = await request.body()
    parsed_body, _ok = _try_parse_json(raw_body)
    write_traffic(
        {
            "request_id": request_id,
            "dir": "in",
            "method": method,
            "path": path,
            "headers": redact_headers(dict(request.headers)),
            "body": parsed_body
            if parsed_body is not None
            else (raw_body.decode("utf-8", errors="replace") if raw_body else None),
            "body_kind": _body_kind(raw_body, parsed_body, _ok),
        }
    )
    write_gap(
        {
            "request_id": request_id,
            "kind": "unknown_path",
            "path": path,
            "method": method,
        }
    )
    return JSONResponse(
        {"error": {"message": "unknown path", "type": "unknown_path", "request_id": request_id}},
        status_code=404,
    )


# --- app -------------------------------------------------------------------

app = Starlette(
    lifespan=lifespan,
    routes=[
        Route("/healthz", healthz, methods=["GET"]),
        Route("/v1/chat/completions", _wrap(chat_completions), methods=["POST"]),
        Route("/v1/completions", _wrap(completions), methods=["POST"]),
        Route("/v1/embeddings", _wrap(embeddings), methods=["POST"]),
        Route("/v1/models", _wrap(models), methods=["GET"]),
        # Catch-all: any other path/method falls here so we log a gap rather than 404 silently.
        Route(
            "/{rest:path}",
            _wrap(catch_all),
            methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"],
        ),
    ],
)


def main() -> None:
    from aeo_mlx_lab import load_env

    load_env()
    port = int(os.environ.get("MLX_SHIM_PORT", "64080"))
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")


if __name__ == "__main__":
    main()
