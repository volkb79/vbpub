import importlib.util
import os
import tempfile
import shutil
import sys

SCRIPT_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'compose-init-up.py'))
spec = importlib.util.spec_from_file_location('compose_init_up', SCRIPT_PATH)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

print('Module loaded')

# Test migrate_env_sample_to_toml
with tempfile.TemporaryDirectory() as td:
    sample = os.path.join(td, mod.DEFAULT_ENV_SAMPLE_FILE)
    toml_out = os.path.join(td, mod.DEFAULT_TOML_ACTIVE_FILE)
    with open(sample, 'w') as f:
        f.write('FOO=bar\nSECRET_PASSWORD=\n')
    mod.migrate_env_sample_to_toml(sample, toml_out)
    assert os.path.isfile(toml_out), 'toml not created'
    txt = open(toml_out).read()
    assert 'FOO' in txt and 'SECRET_PASSWORD' in txt
    print('migrate_env_sample_to_toml: OK')

# Test run_hooks class-only
with tempfile.TemporaryDirectory() as td:
    hook = os.path.join(td, 'pre_hook.py')
    with open(hook, 'w') as f:
        f.write('class PreComposeHook:\n    def __init__(self, env=None):\n        pass\n    def run(self, env):\n        return {"X_TEST":"ok"}\n')
    changes = mod.run_hooks('PRE_COMPOSE', {'COMPINIT_HOOK_PRE_COMPOSE': hook})
    assert changes.get('X_TEST') == 'ok'
    print('run_hooks class-only: OK')

print('All simple tests passed')
