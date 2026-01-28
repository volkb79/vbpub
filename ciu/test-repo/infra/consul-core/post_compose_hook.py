#!/usr/bin/env python3
"""Demo post-compose hook: simulate Consul KV seeding."""

from __future__ import annotations


def post_compose_hook(config: dict, env: dict) -> dict:
    _ = config
    _ = env
    return {
        "consul_core.env.CONSUL_SEEDED": {
            "value": "true",
            "persist": "toml",
            "apply_to_config": True,
        }
    }
