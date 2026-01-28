#!/usr/bin/env python3
"""Shared rendering helpers for CIU and CIU Deploy."""

from __future__ import annotations

import tomllib
from pathlib import Path
from typing import Iterable

from .config_constants import GLOBAL_CONFIG_RENDERED, STACK_CONFIG_DEFAULTS
from .engine import render_global_config_chain, render_stack_config


def find_stack_anchor(repo_root: Path) -> Path:
    """Find a stack directory containing ciu.defaults.toml.j2 for global render."""
    candidates: list[Path] = []
    for toml_path in repo_root.rglob(STACK_CONFIG_DEFAULTS):
        relative = toml_path.relative_to(repo_root)
        if not relative.parts:
            continue
        top_level = relative.parts[0]
        if top_level not in {"applications", "infra", "infra-global", "tools"}:
            continue
        candidates.append(toml_path.parent)

    if not candidates:
        raise RuntimeError("No stack config found to render ciu-global.toml")

    return sorted(candidates, key=lambda path: str(path))[0]


def load_global_config(repo_root: Path) -> dict:
    """Load rendered ciu-global.toml."""
    global_config_path = repo_root / GLOBAL_CONFIG_RENDERED
    if not global_config_path.exists():
        raise FileNotFoundError(
            f"Rendered global config not found: {global_config_path}"
        )

    with open(global_config_path, "rb") as f:
        return tomllib.load(f)


def render_global_config(repo_root: Path) -> dict:
    """Render ciu-global.toml and return the config."""
    anchor_dir = find_stack_anchor(repo_root)
    return render_global_config_chain(anchor_dir, repo_root_override=repo_root)


def render_global_config_if_missing(repo_root: Path) -> dict:
    """Render ciu-global.toml if missing and return the config."""
    global_config_path = repo_root / GLOBAL_CONFIG_RENDERED
    if global_config_path.exists():
        return load_global_config(repo_root)

    return render_global_config(repo_root)


def render_stack_configs(stack_paths: Iterable[Path], global_config: dict, preserve_state: bool) -> None:
    """Render ciu.toml for each stack path."""
    for stack_path in sorted(stack_paths, key=lambda path: str(path)):
        render_stack_config(stack_path, global_config, preserve_state=preserve_state)


def build_global_config_debug_lines(config: dict) -> list[str]:
    """Return debug lines for global config summary."""
    deploy = config.get("deploy", {})
    registry = deploy.get("registry", {})

    return [
        "=== Global Config Values ===",
        f"  deploy.project_name: {deploy.get('project_name', 'NOT SET')}",
        f"  deploy.environment_tag: {deploy.get('environment_tag', 'NOT SET')}",
        f"  deploy.network_name: {deploy.get('network_name', 'NOT SET')}",
        f"  deploy.log_level: {deploy.get('log_level', 'NOT SET')}",
        f"  deploy.registry.namespace: {registry.get('namespace', 'NOT SET')}",
        f"  deploy.registry.url: {registry.get('url', '(empty - using local)')}",
        "=== End Global Config ===",
    ]
