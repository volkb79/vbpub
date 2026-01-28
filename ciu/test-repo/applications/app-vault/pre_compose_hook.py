#!/usr/bin/env python3
"""Demo pre-compose hook: injects a Vault bootstrap token."""

from __future__ import annotations


def pre_compose_hook(config: dict, env: dict) -> dict:
    _ = config
    _ = env
    return {
        "app_vault.env.VAULT_BOOTSTRAP_TOKEN": {
            "value": "demo-token",
            "persist": "toml",
            "apply_to_config": True,
        }
    }
