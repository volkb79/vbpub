"""
Contract tests for CIU hook interfaces.

These tests validate that required hook modules expose the expected class
interface without executing Docker/Vault/Consul operations.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
TEST_REPO = REPO_ROOT / "test-repo"


def _load_module(module_path: Path):
    spec = importlib.util.spec_from_file_location(module_path.stem, module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module: {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _assert_post_compose_interface(module) -> None:
    hook_cls = getattr(module, "PostComposeHook", None)
    if hook_cls is not None:
        assert hasattr(hook_cls, "run"), "PostComposeHook.run missing"
        return

    hook_func = getattr(module, "post_compose_hook", None) or getattr(module, "run", None)
    assert hook_func is not None, "post_compose_hook or run function missing"
    assert callable(hook_func), "post_compose_hook must be callable"


def test_vault_post_compose_hook_interface() -> None:
    hook_path = TEST_REPO / "infra" / "vault-core" / "post_compose_hook.py"
    assert hook_path.exists(), "Vault hook file missing"
    module = _load_module(hook_path)
    _assert_post_compose_interface(module)


def test_consul_hook_interface_or_skip() -> None:
    hook_path = TEST_REPO / "infra" / "consul-core" / "post_compose_hook.py"
    if not hook_path.exists():
        pytest.skip("Consul post-compose hook not implemented yet")
    module = _load_module(hook_path)
    _assert_post_compose_interface(module)
