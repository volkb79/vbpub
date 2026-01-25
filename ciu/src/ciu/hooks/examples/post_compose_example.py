#!/usr/bin/env python3
"""
Example post-compose hook for CIU.

This sample demonstrates returning env-only updates and does not persist state.
"""
from __future__ import annotations

from typing import Dict


def _build_updates() -> Dict[str, str]:
    return {
        "EXAMPLE_POST_FLAG": "true",
    }


class PostComposeHook:
    """Sample class-based post-compose hook."""

    def __init__(self, env: dict | None = None) -> None:
        self.env = env or {}

    def run(self, env: dict) -> dict:
        _ = env
        return _build_updates()


def post_compose_hook(config: dict, env: dict) -> dict:
    """Function-based variant (supported by CIU)."""
    _ = config
    _ = env
    return _build_updates()
