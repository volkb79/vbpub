#!/usr/bin/env python3
"""CIU CLI entry point."""

from __future__ import annotations

from .engine import main as engine_main


def main() -> None:
    raise SystemExit(engine_main())


if __name__ == "__main__":
    main()
