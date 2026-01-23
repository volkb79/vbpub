#!/usr/bin/env python3
"""
CIU CLI entry point.

This wrapper locates the CIU engine inside the current repository and executes it.
"""

from __future__ import annotations

import runpy
import sys
from pathlib import Path


def _find_repo_root(start: Path) -> Path:
    current = start.resolve()
    while current != current.parent:
        if (current / "ciu-global.defaults.toml.j2").exists():
            return current
        current = current.parent
    raise FileNotFoundError("Repository root not found (ciu-global.defaults.toml.j2 missing).")


def main() -> None:
    repo_root = _find_repo_root(Path.cwd())
    engine_path = repo_root / "scripts" / "ciu" / "ciu.py"

    if not engine_path.exists():
        raise SystemExit(
            "CIU engine not found at scripts/ciu/ciu.py. "
            "Ensure the target repository includes the CIU engine."
        )

    sys.argv[0] = str(engine_path)
    runpy.run_path(str(engine_path), run_name="__main__")


if __name__ == "__main__":
    main()
