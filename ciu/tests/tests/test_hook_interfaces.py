"""
Contract tests for CIU hook interfaces.

These tests validate that required hook modules expose the expected class
interface without executing Docker/Vault/Consul operations.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[3]


def _load_module(module_path: Path):
    spec = importlib.util.spec_from_file_location(module_path.stem, module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module: {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _assert_hook_class(module, class_name: str) -> None:
    hook_cls = getattr(module, class_name, None)
    assert hook_cls is not None, f"{class_name} missing"
    assert hasattr(hook_cls, "run"), f"{class_name}.run missing"


def test_vault_post_compose_hook_interface() -> None:
    hook_path = REPO_ROOT / "infra" / "vault" / "post_compose_vault.py"
    assert hook_path.exists(), "Vault hook file missing"
    module = _load_module(hook_path)
    _assert_hook_class(module, "PostComposeHook")


def test_consul_hook_interface_or_skip() -> None:
    hook_path = REPO_ROOT / "infra" / "consul-server" / "post_compose_consul.py"
    if not hook_path.exists():
        pytest.skip("Consul post-compose hook not implemented yet")
    module = _load_module(hook_path)
    _assert_hook_class(module, "PostComposeHook")
