#!/usr/bin/env python3
"""Ensure an mlx-community model is fully downloaded before mlx_lm.server tries to load it.

Usage: mlx-prepare <hf_repo>      # e.g. mlx-community/gemma-4-26B-A4B-it-OptiQ-4bit

Exit codes:
  0  cache is complete (either was already, or finished successfully)
  1  download failed after resume + clean retries
  2  no network / HF API unreachable
  3  bad arguments
"""

import contextlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# --- Tunables (chosen to NOT false-trigger on normal HF/xet pauses) ---
STALL_MINUTES = 10  # 10 min of zero byte growth → "stalled"
GRACE_MINUTES = 2  # ignore stall detection during initial 2 min (warmup, metadata fetch)
TOTAL_MINUTES = 180  # absolute cap per attempt (3h — covers ~80GB at slow speeds)
SAMPLE_INTERVAL = 30  # seconds between byte-count samples
HF_API_TIMEOUT = 15  # seconds for metadata HEAD/GET

def log(msg):
    print(f"[mlx-prepare {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def cache_root(repo):
    return Path.home() / ".cache/huggingface/hub" / f"models--{repo.replace('/', '--')}"


def blob_dir(repo):
    return cache_root(repo) / "blobs"


def snapshot_dir(repo):
    """The single snapshot dir, or None if not present."""
    snaps = cache_root(repo) / "snapshots"
    if not snaps.is_dir():
        return None
    children = [p for p in snaps.iterdir() if p.is_dir()]
    return children[0] if children else None  # pick the first; HF only keeps one normally


def total_bytes(p: Path):
    if not p.exists():
        return 0
    total = 0
    for f in p.rglob("*"):
        if f.is_file():
            with contextlib.suppress(OSError):
                total += f.stat().st_size
    return total


def has_incomplete(p: Path):
    if not p.exists():
        return False
    return any(True for _ in p.rglob("*.incomplete"))


# ---- Completeness check (the "do nothing" fast path) ----


def fetch_repo_files(repo):
    """Hit HF API to get the authoritative file list + sizes for the latest revision.
    Returns dict {filename: size_bytes} for all model-relevant files, or raises.
    """
    url = f"https://huggingface.co/api/models/{repo}/tree/main?recursive=true"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=HF_API_TIMEOUT) as r:
        data = json.loads(r.read())
    # data is a list of {type, path, size, ...}; we want regular files only
    return {item["path"]: item.get("size", 0) for item in data if item.get("type") == "file"}


def check_complete(repo):
    """Return (complete: bool, reason: str). Tries to be exhaustive without false-positiving 'partial'."""
    snap = snapshot_dir(repo)
    if snap is None:
        return False, "no snapshot dir (not downloaded)"
    if has_incomplete(blob_dir(repo)):
        return False, "incomplete blobs present"

    # Get authoritative file list from HF
    try:
        expected = fetch_repo_files(repo)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        # Offline or HF down. Can't verify completeness — but if no .incomplete files,
        # treat as complete to avoid forcing redownloads when we can't even reach HF.
        return (
            True,
            f"HF API unreachable ({type(e).__name__}); trusting local cache (no .incomplete files)",
        )

    # Required files: every shard, plus index files. Optional: README, .gitattributes.
    REQUIRED_SUFFIXES = (".safetensors", ".json", ".jinja", ".model", ".tiktoken")
    # Files we knowingly rewrite post-cache (e.g., config.json for the Llama-4
    # attn_temperature_tuning patch). Their byte size legitimately differs from
    # HF's after patching, so a size mismatch isn't a corruption signal.
    SIZE_EXEMPT = {"config.json"}
    missing = []
    size_mismatch = []
    for path, exp_size in expected.items():
        if not path.endswith(REQUIRED_SUFFIXES):
            continue
        local = snap / path
        if not local.exists():
            missing.append(path)
            continue
        # Resolve symlink and check actual blob
        real = local.resolve()
        if not real.exists():
            missing.append(f"{path} (dangling symlink)")
            continue
        if path in SIZE_EXEMPT:
            continue
        actual_size = real.stat().st_size
        if exp_size and actual_size != exp_size:
            size_mismatch.append(f"{path} (got {actual_size}, expected {exp_size})")

    if missing or size_mismatch:
        why = []
        if missing:
            why.append(f"missing: {missing[:3]}{'...' if len(missing) > 3 else ''}")
        if size_mismatch:
            why.append(
                f"size mismatch: {size_mismatch[:3]}{'...' if len(size_mismatch) > 3 else ''}"
            )
        return False, "; ".join(why)
    return True, f"all {len(expected)} files present, sizes match HF"


# ---- Download with stall detection ----


def run_snapshot_download(repo):
    """Spawn snapshot_download in a subprocess so we can monitor + kill it."""
    code = (
        "from huggingface_hub import snapshot_download; "
        f"snapshot_download(repo_id={repo!r}, max_workers=4)"
    )
    return subprocess.Popen(
        [sys.executable, "-c", code], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )


def download_attempt(repo, attempt_label):
    """Run snapshot_download with stall detection. Return True on success, False on stall/fail."""
    log(f"download attempt: {attempt_label}")
    bdir = blob_dir(repo)
    bdir.mkdir(parents=True, exist_ok=True)

    proc = run_snapshot_download(repo)
    start = time.time()
    last_size = total_bytes(bdir)
    last_change = time.time()
    grace_until = start + GRACE_MINUTES * 60
    deadline = start + TOTAL_MINUTES * 60

    while True:
        time.sleep(SAMPLE_INTERVAL)
        rc = proc.poll()
        if rc is not None:
            # Drain output so the user sees errors
            try:
                out = proc.stdout.read() if proc.stdout else ""
            except Exception:
                out = ""
            if rc == 0:
                log(f"snapshot_download exited cleanly ({int(time.time() - start)}s elapsed)")
                return True
            else:
                log(f"snapshot_download exited rc={rc}; tail of output:")
                for line in (out or "").splitlines()[-15:]:
                    log(f"  | {line}")
                return False

        size = total_bytes(bdir)
        elapsed = time.time() - start
        if size > last_size:
            delta = size - last_size
            log(
                f"  +{delta / 1024 / 1024:.0f} MB ({size / 1024**3:.1f} GB total, {elapsed:.0f}s in)"
            )
            last_size = size
            last_change = time.time()
            continue

        # No growth this interval — check stall threshold (after grace period)
        if time.time() < grace_until:
            continue
        idle = time.time() - last_change
        if idle >= STALL_MINUTES * 60:
            log(
                f"STALL: no byte growth for {idle / 60:.1f} min (size={size / 1024**3:.1f} GB). Killing."
            )
            try:
                proc.terminate()
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
            return False
        if time.time() > deadline:
            log(f"TIMEOUT: total cap of {TOTAL_MINUTES} min reached. Killing.")
            try:
                proc.terminate()
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
            return False


# ---- Cleanup ----


def wipe_cache(repo):
    cr = cache_root(repo)
    if cr.exists():
        log(f"wiping {cr}")
        shutil.rmtree(cr, ignore_errors=True)


# ---- Post-cache config patches ----


def _coerce_attn_temp_tuning(obj, path="$"):
    """Walk a JSON object and coerce any 'attn_temperature_tuning' that isn't already
    a bool. Returns a list of (json_path, old_value, new_value) for every change.

    Llama-4 Scout puts this field in the 'text_config' subdict as int 4, but a future
    variant could put it at the top level — walking recursively covers both without
    a special case.
    """
    changes = []
    if isinstance(obj, dict):
        for k, v in list(obj.items()):
            if k == "attn_temperature_tuning" and not isinstance(v, bool):
                new = bool(v)
                obj[k] = new
                changes.append((f"{path}.{k}", v, new))
            else:
                changes.extend(_coerce_attn_temp_tuning(v, f"{path}.{k}"))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            changes.extend(_coerce_attn_temp_tuning(v, f"{path}[{i}]"))
    return changes


def _patch_scout_config(repo):
    """Idempotent post-cache fix for the Llama-4 'attn_temperature_tuning' int→bool
    bug (see kb/known-model-failures.md). Walks the snapshot's config.json; when
    the field exists with a non-bool value, coerces it via bool() and atomic-writes
    the file back. Re-running is a no-op once coerced.

    Defensively scoped to repos whose name contains 'Llama-4' so we don't scan
    every other model's config; the field's presence/type still guards the actual
    write.
    """
    if "Llama-4" not in repo:
        return
    snap = snapshot_dir(repo)
    if snap is None:
        return
    cfg_path = snap / "config.json"
    if not cfg_path.exists():
        return  # some MLX repos lack a top-level config.json; nothing to do
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        log(f"config patch: could not read {cfg_path} ({type(e).__name__}: {e}); skipping")
        return

    changes = _coerce_attn_temp_tuning(cfg)
    if not changes:
        log("config patch: attn_temperature_tuning already bool (or absent), no patch needed")
        return

    # Atomic write: temp file in the same directory, then os.replace onto the
    # original. config.json in HF snapshots is normally a symlink to a blob; the
    # replace turns it into a regular file, which is exactly what we want — the
    # blob is preserved and re-downloads will recreate the symlink.
    tmp_path = cfg_path.with_name(cfg_path.name + ".tmp-mlxprepare")
    try:
        # indent=4 matches HF's own pretty-printing for these configs; not
        # required for correctness, just keeps diffs human-readable if a user
        # inspects the patched file.
        with open(tmp_path, "w") as f:
            json.dump(cfg, f, indent=4)
            f.write("\n")
        os.replace(tmp_path, cfg_path)
    except OSError as e:
        log(f"config patch: write failed ({type(e).__name__}: {e}); leaving original untouched")
        with contextlib.suppress(OSError):
            tmp_path.unlink()
        return

    for jp, old, new in changes:
        log(f"config patch: {jp} {old!r} -> {new!r}")


# ---- Main ----


def ensure(repo):
    # 1. Fast path: already complete?
    ok, why = check_complete(repo)
    if ok:
        log(f"cache complete — skipping download ({why})")
        _patch_scout_config(repo)
        return True
    log(f"cache not complete: {why}")

    # 2. Resume attempt — snapshot_download natively resumes via .incomplete files.
    if download_attempt(repo, "resume (preserves partial blobs)"):
        ok, why = check_complete(repo)
        if ok:
            _patch_scout_config(repo)
            return True
        log(f"download exited but verify says not complete: {why}")

    # 3. Clean + fresh download.
    log("resume failed; wiping cache and redownloading from scratch")
    wipe_cache(repo)
    if download_attempt(repo, "fresh (after clean)"):
        ok, why = check_complete(repo)
        if ok:
            _patch_scout_config(repo)
            return True
        log(f"fresh download exited but verify says not complete: {why}")
        return False
    return False


def main():
    from aeo_mlx_lab import load_env

    load_env()
    if len(sys.argv) != 2:
        print("usage: mlx-prepare <hf_repo>", file=sys.stderr)
        sys.exit(3)
    repo = sys.argv[1]
    if "/" not in repo:
        print(f"error: '{repo}' doesn't look like a HF repo (expected org/name)", file=sys.stderr)
        sys.exit(3)

    log(f"preparing {repo}")
    try:
        ok = ensure(repo)
    except KeyboardInterrupt:
        log("interrupted")
        sys.exit(1)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
