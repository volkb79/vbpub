"""
Sanity checks for CIU template presence and expected sections.
"""
from __future__ import annotations

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
TEST_REPO = REPO_ROOT / "test-repo"


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_ciu_global_templates_exist() -> None:
    defaults_path = TEST_REPO / "ciu-global.defaults.toml.j2"
    overrides_path = TEST_REPO / "ciu-global.toml.j2"
    assert defaults_path.exists(), "ciu-global.defaults.toml.j2 missing"
    assert overrides_path.exists(), "ciu-global.toml.j2 missing"


def test_ciu_global_templates_have_core_sections() -> None:
    content = _read_text(TEST_REPO / "ciu-global.defaults.toml.j2")
    for section in ("[ciu]", "[deploy]", "[deploy.env.defaults]", "[deploy.env.shared]"):
        assert section in content, f"Missing section {section} in defaults template"

    overrides = _read_text(TEST_REPO / "ciu-global.toml.j2")
    for section in ("[ciu]", "[deploy]", "[deploy.env.defaults]", "[deploy.env.shared]"):
        assert section in overrides, f"Missing section {section} in overrides template"
