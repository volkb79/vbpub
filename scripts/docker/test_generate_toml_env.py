#!/usr/bin/env python3
"""
Pytest-friendly test: generate live env from .env.toml and ensure correct file loading,
skeleton creation, and active file creation.
"""

import sys
from pathlib import Path
import importlib.util
import tempfile


def run_generate_toml_env_test(toml_path: str = None) -> bool:
    ROOT = Path(__file__).resolve().parents[3]
    TOML = Path(toml_path) if toml_path else ROOT / '.env.toml'
    SCRIPT = ROOT / 'vbpub' / 'scripts' / 'docker' / 'compose-init-up.py'

    if not TOML.exists():
        raise AssertionError(f"TOML file not found at {TOML}")
    if not SCRIPT.exists():
        raise AssertionError(f"compose-init-up.py not found at {SCRIPT}")

    spec = importlib.util.spec_from_file_location('compose_init', str(SCRIPT))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    with tempfile.NamedTemporaryFile('w+', delete=False) as tmp:
        out_path = Path(tmp.name)

    try:
        mod.parse_toml_sample(str(TOML), str(out_path))
    except Exception as e:
        raise AssertionError(f"parse_toml_sample failed: {e}")

    out_text = out_path.read_text(encoding='utf-8')

    expected = [
        "COMPINIT_COMPOSE_START_MODE",
        "COMPINIT_RESET_BEFORE_START",
        "COMPINIT_CHECK_IMAGE_ENABLED",
        "COMPINIT_IMAGE_CHECK_CONTINUE_ON_ERROR",
        "PUBLIC_FQDN",
        "PUBLIC_TLS_KEY_PEM",
        "PUBLIC_TLS_CRT_PEM",
        "HEALTHCHECK_INTERVAL",
        "HEALTHCHECK_TIMEOUT",
        "HEALTHCHECK_RETRIES",
        "HEALTHCHECK_START_PERIOD",
        "LABEL_PROJECT_NAME",
        "LABEL_ENV_TAG",
        "LABEL_PREFIX",
        "UID",
        "GID"
    ]

    missing = []
    for key in expected:
        if not any(line.strip().startswith(f"{key}=") for line in out_text.splitlines()):
            missing.append(key)

    if missing:
        raise AssertionError(f"Missing expected keys in generated env: {missing}")

    return True


def test_generate_toml_env_default():
    assert run_generate_toml_env_test()


if __name__ == '__main__':
    try:
        ok = run_generate_toml_env_test()
        if ok:
            print('PASS: TOML env generation produced all expected keys.')
            sys.exit(0)
    except AssertionError as e:
        print('FAIL:', e)
        sys.exit(1)
