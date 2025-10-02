#!/usr/bin/env python3
"""
Test: generate live env from .env.toml and ensure correct file loading, skeleton creation, and active file creation.
Checks:
- .env.toml loads and parses without error
- .env is generated and contains expected keys
- All canonical variables are present
"""
import sys
import os
from pathlib import Path
import importlib.util
import tempfile

ROOT = Path(__file__).resolve().parents[3]
TOML = ROOT / '.env.toml'
SCRIPT = ROOT / 'vbpub' / 'scripts' / 'docker' / 'compose-init-up.py'

if not TOML.exists():
    print(f"TOML file not found at {TOML}")
    sys.exit(2)
if not SCRIPT.exists():
    print(f"compose-init-up.py not found at {SCRIPT}")
    sys.exit(2)

spec = importlib.util.spec_from_file_location('compose_init', str(SCRIPT))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

with tempfile.NamedTemporaryFile('w+', delete=False) as tmp:
    out_path = Path(tmp.name)

try:
    mod.parse_toml_sample(str(TOML), str(out_path))
except Exception as e:
    print(f"parse_toml_sample failed: {e}")
    sys.exit(3)

toml_text = TOML.read_text(encoding='utf-8')
out_text = out_path.read_text(encoding='utf-8')

# Check for expected keys
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
    found = False
    for line in out_text.splitlines():
        if line.strip().startswith(f"{key}="):
            found = True
            break
    if not found:
        missing.append(key)
if missing:
    print(f"FAIL: Missing expected keys in generated env: {missing}")
    sys.exit(4)
print("PASS: TOML env generation produced all expected keys.")
sys.exit(0)
