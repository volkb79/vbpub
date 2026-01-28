#!/usr/bin/env python3
"""Demo post-compose hook: simulate Vault initialization."""

from __future__ import annotations


def post_compose_hook(config: dict, env: dict) -> dict:
    _ = config
    _ = env
    return {
        "vault_core.env.VAULT_INITIALIZED": {
            "value": "true",
            "persist": "toml",
            "apply_to_config": True,
        }
    }
