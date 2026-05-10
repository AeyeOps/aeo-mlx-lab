"""Rolling JSONL log writers for the shim.

Two files in MLX_SHIM_LOG_DIR (default ./tmp/):
  - traffic.jsonl: every request and response, paired by request_id
  - gaps.jsonl:    only entries that need attention (kind: ...)

Rotation: 50 MB per file, 5 backups. Header redaction for authorization,
cookie, x-api-key. Writer errors go to stderr, never swallowed silently.
"""

from __future__ import annotations

import json
import os
import sys
import threading
from datetime import UTC, datetime
from logging.handlers import RotatingFileHandler
from typing import Any

REDACT_HEADERS = {"authorization", "cookie", "x-api-key"}
ROTATE_BYTES = 50 * 1024 * 1024  # 50 MB
BACKUP_COUNT = 5

_lock = threading.Lock()
_writers: dict[str, RotatingFileHandler] = {}


def _writer_for(path: str) -> RotatingFileHandler:
    if path not in _writers:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        h = RotatingFileHandler(
            path, maxBytes=ROTATE_BYTES, backupCount=BACKUP_COUNT, encoding="utf-8"
        )
        _writers[path] = h
    return _writers[path]


def _now_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def redact_headers(headers: dict[str, str]) -> dict[str, str]:
    return {k: ("***" if k.lower() in REDACT_HEADERS else v) for k, v in headers.items()}


def _write(path: str, entry: dict[str, Any]) -> None:
    line = json.dumps(entry, ensure_ascii=False, default=str)
    payload = line + "\n"
    try:
        with _lock:
            h = _writer_for(path)
            if h.stream is None:
                h.stream = h._open()
            # Direct size-based rollover check. We bypass RotatingFileHandler.shouldRollover
            # because it calls Formatter.format(record), which on Python 3.14+ touches
            # LogRecord-only attributes (exc_info, stack_info) that a stub record can't satisfy.
            try:
                pos = h.stream.tell()
            except Exception:
                pos = 0
            if (
                h.maxBytes > 0
                and pos > 0
                and pos + len(payload) >= h.maxBytes
                and os.path.exists(h.baseFilename)
                and os.path.isfile(h.baseFilename)
            ):
                h.doRollover()
            h.stream.write(payload)
            h.stream.flush()
    except Exception as e:
        sys.stderr.write(f"[shim.logs] writer error path={path} err={e!r}\n")
        sys.stderr.flush()


def log_dir() -> str:
    return os.environ.get(
        "MLX_SHIM_LOG_DIR", os.path.join(os.environ.get("MLX_PROJECT_DIR", os.getcwd()), "tmp")
    )


def write_traffic(entry: dict[str, Any]) -> None:
    entry.setdefault("ts", _now_iso())
    _write(os.path.join(log_dir(), "traffic.jsonl"), entry)


def write_gap(entry: dict[str, Any]) -> None:
    entry.setdefault("ts", _now_iso())
    _write(os.path.join(log_dir(), "gaps.jsonl"), entry)
