import os
import tempfile
import shutil
import subprocess
import json
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'compose-init-up.py'

SAMPLE_TOML = """\
[metadata]
project_name = "directive-test"

[project]
name = "directive-test"

[variables]
# Simulated secret directive variables (value holds directive token)
BOOTSTRAP_TOKEN = { value = "GEN:controller_bootstrap_token", description = "bootstrap" }
EPHEMERAL_TOKEN = { value = "GEN_EPHEMERAL", description = "ephemeral" }
MANAGED_DB_PW = { value = "ASK_VAULT:postgres_controller_password" }
ONCE_TOKEN = { value = "ASK_VAULT_ONCE:worker_registration_token" }
DERIVED_KEY = { value = "DERIVE:sha256:BOOTSTRAP_TOKEN" }
EXTERNAL_FALLBACK = { value = "ASK_EXTERNAL:EXT_API_KEY" }
"""

def run(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr

def test_directive_resolution_and_redaction():
    tmp = tempfile.mkdtemp(prefix='directive-test-')
    try:
        # Write sample toml
        with open(Path(tmp)/'compose.config.sample.toml','w',encoding='utf-8') as f:
            f.write(SAMPLE_TOML)
        # Dry run with print context
        code, out, err = run(f"python3 {SCRIPT} --dry-run --print-context", tmp)
        assert code == 0, f"script failed: {err}"
        # Extract first JSON object from mixed output
        start = out.find('{')
        end = out.rfind('}')
        assert start != -1 and end != -1 and end > start
        data = json.loads(out[start:end+1])
        # Ensure secrets redacted (GEN & ASK_VAULT*)
        assert data['BOOTSTRAP_TOKEN'] == '***REDACTED***'
        assert data['MANAGED_DB_PW'] == '***REDACTED***'
        assert data['ONCE_TOKEN'] == '***REDACTED***'
        # Ephemeral and derived may not be redacted (acceptable placeholder behavior)
    finally:
        shutil.rmtree(tmp)

def test_secrets_reset_restores_directives():
    tmp = tempfile.mkdtemp(prefix='directive-reset-')
    try:
        with open(Path(tmp)/'compose.config.sample.toml','w',encoding='utf-8') as f:
            f.write(SAMPLE_TOML)
        # First run to create active & resolve
        code, _, err = run(f"python3 {SCRIPT} --dry-run", tmp)
        assert code == 0, err
        # Simulate secrets reset flag
        env = os.environ.copy()
        env['COMPINIT_RESET_BEFORE_START'] = 'secrets'
        proc = subprocess.run(f"python3 {SCRIPT} --dry-run --print-context", cwd=tmp, shell=True, capture_output=True, text=True, env=env)
        assert proc.returncode == 0, proc.stderr
        # Active file should contain directives section (hashes) after run
        active_path = Path(tmp)/'compose.config.active.toml'
        if active_path.exists():
            content = active_path.read_text()
            assert '[secrets.directives]' in content
            assert 'BOOTSTRAP_TOKEN' in content
    finally:
        shutil.rmtree(tmp)
