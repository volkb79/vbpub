#!/usr/bin/env python3
"""Pytest-friendly smoke test: generate live env from .env.sample and ensure no command substitutions

This module wraps the original standalone test logic into a function so it can
be imported by pytest without exiting during import. It preserves CLI usage
so it can still be executed directly.
"""

import re
import os
import tempfile
import sys
from pathlib import Path


def run_generate_env_test(sample_path: str = None) -> bool:
    """Run the legacy generate-env smoke test logic and return True on success.

    Raises AssertionError on failure with a descriptive message.
    """
    ROOT = Path(__file__).resolve().parents[3]
    SAMPLE = None
    if sample_path:
        SAMPLE = Path(sample_path)
    else:
        SAMPLE = Path(os.environ.get('TEST_SAMPLE', '')) if os.environ.get('TEST_SAMPLE') else ROOT / '.env.sample'
    if not SAMPLE.exists():
        SAMPLE = Path('/home/vb/repos/DST-DNS/infra/.env.sample')

    SCRIPT = ROOT / 'vbpub' / 'scripts' / 'docker' / 'compose-init-up.py'

    if not SAMPLE.exists():
        raise AssertionError(f"Sample file not found at {SAMPLE}")

    if not SCRIPT.exists():
        raise AssertionError(f"compose-init-up.py not found at {SCRIPT}")

    # Import parse_env_sample from the canonical script
    import importlib.util
    spec = importlib.util.spec_from_file_location('compose_init', str(SCRIPT))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    with tempfile.NamedTemporaryFile('w+', delete=False) as tmp:
        out_path = Path(tmp.name)

    try:
        mod.parse_env_sample(str(SAMPLE), str(out_path))
    except Exception as e:
        raise AssertionError(f"parse_env_sample failed: {e}")

    sample_text = SAMPLE.read_text(encoding='utf-8')
    out_text = out_path.read_text(encoding='utf-8')

    # Check for command substitution patterns only in non-comment lines
    bad_lines = []
    for i, line in enumerate(out_text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        if '$(' in line or '`' in line:
            bad_lines.append((i, line))

    if bad_lines:
        details = '\n'.join(f"{ln} {content}" for ln, content in bad_lines)
        raise AssertionError(f'Found command substitution patterns in generated env file (non-comment lines):\n{details}')

    # Find $VAR tokens in sample values (ignore comments) and ensure they still exist in output values
    tokens = set()
    for line in sample_text.splitlines():
        s = line.strip()
        if not s or s.startswith('#') or '=' not in s:
            continue
        _, val = s.split('=', 1)
        for t in re.findall(r'\$[A-Za-z_][A-Za-z0-9_]*', val):
            tokens.add(t)

    missing = []
    for t in tokens:
        # Ensure token appears in some non-comment line of output
        found = False
        for line in out_text.splitlines():
            s = line.strip()
            if not s or s.startswith('#'):
                continue
            if t in line:
                found = True
                break
        if not found:
            missing.append(t)

    if missing:
        raise AssertionError(f'Some $VAR tokens from sample values were expanded/removed: {missing}')

    return True


def test_generate_env_default_sample():
    """Pytest test wrapper that uses the repository default sample file."""
    assert run_generate_env_test()


if __name__ == '__main__':
    try:
        ok = run_generate_env_test()
        if ok:
            print('PASS: Generated env file contains literal tokens in values and no command substitutions in non-comment lines')
            sys.exit(0)
    except AssertionError as e:
        print('FAIL:', e)
        sys.exit(1)
