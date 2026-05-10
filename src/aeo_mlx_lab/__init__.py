"""aeo-mlx-lab — local LLM serving lab for Apple Silicon."""

from __future__ import annotations

import os
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path

try:
    __version__ = version("aeo-mlx-lab")
except PackageNotFoundError:  # not installed (e.g., running from a fresh checkout)
    __version__ = "0+unknown"


def load_env() -> Path | None:
    """Load `.env` for the lab without overriding the existing process env.

    Resolution order:
      1. ``$MLX_PROJECT_DIR/.env`` — the launcher exports MLX_PROJECT_DIR, so
         this finds the repo's `.env` regardless of the caller's cwd.
      2. python-dotenv's upward search from cwd.

    Returns the path that was loaded, or None if no `.env` was found. Existing
    environment variables always win, so callers that explicitly export a
    variable (e.g. mlx-serve passing MLX_BACKEND_URL) are never clobbered.
    """
    from dotenv import find_dotenv, load_dotenv

    project_dir = os.environ.get("MLX_PROJECT_DIR")
    if project_dir:
        candidate = Path(project_dir) / ".env"
        if candidate.is_file():
            load_dotenv(candidate, override=False)
            return candidate

    found = find_dotenv(usecwd=True)
    if found:
        load_dotenv(found, override=False)
        return Path(found)
    return None
