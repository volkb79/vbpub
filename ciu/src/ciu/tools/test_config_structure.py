#!/usr/bin/env python3
"""
Test: TOML Configuration Structure Completeness

Verifies that *.defaults.toml files contain all sections present in *.active.toml files.
This ensures that deleting active files and regenerating from defaults is safe.

Usage:
    python3 -m ciu.tools.test_config_structure
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path
from typing import Dict, List, Set, Tuple


def _find_repo_root(start: Path) -> Path:
    current = start.resolve()
    while current != current.parent:
        if (current / "ciu-global.defaults.toml.j2").exists():
            return current
        current = current.parent
    raise FileNotFoundError("Repository root not found (ciu-global.defaults.toml.j2 missing).")


def normalize_key(key: str) -> str:
    """Normalize TOML keys by replacing hyphens with underscores."""
    return key.replace('-', '_')


def get_toml_structure(data: dict, prefix: str = "") -> Set[str]:
    """
    Extract all keys/sections from TOML structure.

    Handles metadata format pattern: env.VAR.{value, persist, sensitive, comment}
    Reports these as single 'env.VAR' entry instead of 4 separate keys.
    """
    paths = set()

    for key, value in data.items():
        normalized_key = normalize_key(key)
        full_key = f"{prefix}.{normalized_key}" if prefix else normalized_key

        if normalized_key.startswith('__metadata_'):
            continue

        if normalized_key in ('status', 'reason'):
            continue

        if isinstance(value, dict):
            metadata_keys = {'value', 'persist', 'sensitive', 'comment'}
            if all(k in metadata_keys for k in value.keys()):
                paths.add(full_key)
                continue

        paths.add(full_key)

        if isinstance(value, dict):
            paths.update(get_toml_structure(value, full_key))

    return paths


def load_toml_file(filepath: Path) -> Dict:
    """Load TOML file safely."""
    try:
        with open(filepath, 'rb') as f:
            return tomllib.load(f)
    except FileNotFoundError:
        print(f"[ERROR] File not found: {filepath}")
        return {}
    except Exception as e:
        print(f"[ERROR] Failed to parse {filepath}: {e}")
        return {}


def compare_configs(defaults: Dict, active: Dict) -> Tuple[Set[str], Set[str]]:
    """Compare structures of defaults vs active."""
    defaults_keys = get_toml_structure(defaults)
    active_keys = get_toml_structure(active)

    missing_in_defaults = active_keys - defaults_keys
    extra_in_defaults = defaults_keys - active_keys

    auto_sections = {
        'auto_generated',
        'auto_generated.uid',
        'auto_generated.gid',
        'auto_generated.docker_gid',
        'auto_generated.build_version',
        'auto_generated.build_time',
        'auto_generated.network_name',
        'auto_generated.registry_mode',
    }
    missing_in_defaults = {k for k in missing_in_defaults if not any(k.startswith(s) for s in auto_sections)}

    return missing_in_defaults, extra_in_defaults


def find_toml_pairs(repo_root: Path) -> List[Tuple[Path, Path]]:
    """Find all pairs of defaults/active TOML files in repository."""
    pairs: List[Tuple[Path, Path]] = []

    for defaults_file in repo_root.rglob("*.defaults.toml"):
        active_file = defaults_file.with_name(defaults_file.name.replace(".defaults.toml", ".active.toml"))
        pairs.append((defaults_file, active_file))

    return pairs


def main() -> int:
    """Main entry point."""
    repo_root = _find_repo_root(Path.cwd())
    print(f"[INFO] Repository root: {repo_root}")

    toml_pairs = find_toml_pairs(repo_root)
    if not toml_pairs:
        print("[ERROR] No *.defaults.toml files found")
        return 1

    total_checks = 0
    total_failures = 0

    for defaults_file, active_file in toml_pairs:
        total_checks += 1

        if not active_file.exists():
            print(f"[SKIP] {defaults_file.relative_to(repo_root)} (no active file)")
            continue

        defaults = load_toml_file(defaults_file)
        active = load_toml_file(active_file)

        missing_in_defaults, _extra_in_defaults = compare_configs(defaults, active)

        if missing_in_defaults:
            total_failures += 1
            print(f"[FAIL] {defaults_file.relative_to(repo_root)}")
            print("  Missing in defaults:")
            for key in sorted(missing_in_defaults):
                print(f"    - {key}")
        else:
            print(f"[PASS] {defaults_file.relative_to(repo_root)}")

    print("")
    print(f"[SUMMARY] Checks: {total_checks}, Failures: {total_failures}")

    return 0 if total_failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
