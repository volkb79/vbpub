#!/usr/bin/env python3
"""Smoke test: generate live env from .env.sample and ensure no command substitutions

This script imports parse_env_sample from compose-init-up.py and writes a temp
env file, then checks that:
- No command substitution patterns like '$(...)' or backticks are present in output
- All $VAR tokens present in the sample remain present in the generated file

Run from the repository root or this directory; it uses the default .env.sample
next to the workspace root.
"""
import re
import sys
import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
# Allow overriding sample path via env for flexibility
SAMPLE = Path(os.environ.get('TEST_SAMPLE', '')) if os.environ.get('TEST_SAMPLE') else ROOT / '.env.sample'
# Fallback to a known existing sample in the workspace
if not SAMPLE.exists():
    SAMPLE = Path('/home/vb/repos/DST-DNS/infra/.env.sample')
SCRIPT = ROOT / 'vbpub' / 'scripts' / 'docker' / 'compose-init-up.py'

if not SAMPLE.exists():
    print(f"Sample file not found at {SAMPLE}")
    sys.exit(2)

if not SCRIPT.exists():
    print(f"compose-init-up.py not found at {SCRIPT}")
    sys.exit(2)

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
    print(f"parse_env_sample failed: {e}")
    sys.exit(3)

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
    print('FAIL: Found command substitution patterns in generated env file (non-comment lines):')
    for ln, content in bad_lines:
        print(ln, content)
    sys.exit(4)

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
    print('FAIL: Some $VAR tokens from sample values were expanded/removed:', missing)
    sys.exit(5)

print('PASS: Generated env file contains literal tokens in values and no command substitutions in non-comment lines')
sys.exit(0)
