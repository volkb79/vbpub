#!/usr/bin/env python3
"""Shared CLI helpers."""

from __future__ import annotations


def get_cli_version() -> str:
    try:
        from importlib.metadata import version as package_version

        return package_version("ciu")
    except Exception:
        try:
            from . import __version__  # type: ignore

            return __version__
        except Exception:
            return "unknown"
