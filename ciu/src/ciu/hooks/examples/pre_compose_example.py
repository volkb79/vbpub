#!/usr/bin/env python3
"""
Example pre-compose hook for CIU.

This sample demonstrates the class-based interface and metadata return format.
It performs no external I/O and is safe to use as a template.
"""
from __future__ import annotations

from typing import Dict


def _build_updates() -> Dict[str, object]:
    return {
        "EXAMPLE_FLAG": "true",
        "state.example_pre_compose": {
            "value": "example-pre",
            "persist": "toml",
            "apply_to_config": True,
        },
    }


class PreComposeHook:
    """Sample class-based pre-compose hook."""

    def __init__(self, env: dict | None = None) -> None:
        self.env = env or {}

    def run(self, env: dict) -> dict:
        """Return example updates without touching external systems."""
        _ = env  # explicit to show the env parameter is available
        return _build_updates()


def pre_compose_hook(config: dict, env: dict) -> dict:
    """Function-based variant (supported by CIU)."""
    _ = config
    _ = env
    return _build_updates()
