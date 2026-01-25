#!/usr/bin/env python3
"""
Pre-compose hook to resolve GEN_LOCAL and GEN_EPHEMERAL directives.

GEN_LOCAL values are persisted to [secrets.local] in the active stack TOML and
hashed in [secrets.state]. GEN_EPHEMERAL values are applied in-memory only.
"""

from __future__ import annotations

import hashlib
import secrets
from typing import Any, Dict, Iterable, Tuple


def _normalize_secret_key(raw_key: str) -> str:
    return raw_key.replace('/', '__')


def _walk_values(data: Any, base_path: str) -> Iterable[Tuple[str, Any]]:
    if isinstance(data, dict):
        for key, value in data.items():
            next_path = f"{base_path}.{key}" if base_path else key
            if next_path.startswith("secrets.") or next_path.startswith("state."):
                continue
            yield from _walk_values(value, next_path)
    else:
        yield base_path, data


def pre_compose_hook(config: dict, env: dict) -> dict:
    stack_keys = [
        key for key, value in config.items()
        if isinstance(value, dict) and 'hooks' in value
    ]

    if len(stack_keys) != 1:
        raise ValueError(
            f"Expected exactly one stack root section for local secrets resolution. Found: {stack_keys}"
        )

    stack_key = stack_keys[0]
    stack_config = config.get(stack_key, {})

    updates: Dict[str, Dict[str, Any]] = {}

    for path, value in _walk_values(stack_config, stack_key):
        if not isinstance(value, str):
            continue

        if value == 'GEN_EPHEMERAL':
            generated = secrets.token_urlsafe(32)
            updates[path] = {
                'value': generated,
                'persist': 'none',
                'sensitive': True,
                'apply_to_config': True,
                'comment': 'Ephemeral secret (not persisted)'
            }
            continue

        if value.startswith('GEN_LOCAL:'):
            secret_id = value.split(':', 1)[1]
            if not secret_id:
                raise ValueError(f"GEN_LOCAL directive missing key at {path}")

            normalized_key = _normalize_secret_key(secret_id)
            existing = (
                config.get('secrets', {})
                .get('local', {})
                .get(normalized_key)
            )
            if existing:
                generated = existing
            else:
                generated = secrets.token_urlsafe(32)

            updates[path] = {
                'value': generated,
                'persist': 'toml',
                'sensitive': True,
                'comment': f"GEN_LOCAL resolved for {secret_id}"
            }
            updates[f"secrets.local.{normalized_key}"] = {
                'value': generated,
                'persist': 'toml',
                'sensitive': True,
                'comment': f"Local secret storage for {secret_id}"
            }

            secret_hash = hashlib.sha256(generated.encode()).hexdigest()[:8]
            updates[f"secrets.state.{normalized_key}"] = {
                'value': secret_hash,
                'persist': 'toml',
                'sensitive': False,
                'comment': f"Hash for local secret {secret_id}"
            }

    if not updates:
        print("[INFO] No GEN_LOCAL or GEN_EPHEMERAL directives found", flush=True)
        return {}

    print(f"[INFO] Resolved {len(updates)} local secret updates", flush=True)
    return updates


if __name__ == '__main__':
    raise SystemExit("This hook is intended to be run by CIU.")
