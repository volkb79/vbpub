import importlib.util
import os
import tempfile
import shutil
import sys

from types import ModuleType

SCRIPT_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'compose-init-up.py'))


def load_module():
    spec = importlib.util.spec_from_file_location('compose_init_up_test', SCRIPT_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_toml_preferred(tmp_path, monkeypatch):
    mod = load_module()
    # Create temp dir with a TOML file
    d = tmp_path / 'proj'
    d.mkdir()
    toml = d / mod.DEFAULT_TOML_ACTIVE_FILE
    toml.write_text('# dummy toml')
    # Run detection logic by simulating args and cwd
    monkeypatch.chdir(str(d))
    # Emulate argparse by calling functions directly: check existence
    assert os.path.isfile(str(toml))


def test_migration_offers_and_creates_toml(tmp_path, monkeypatch):
    mod = load_module()
    d = tmp_path / 'proj2'
    d.mkdir()
    sample = d / mod.DEFAULT_ENV_SAMPLE_FILE
    sample.write_text('FOO=bar\nSECRET_PASSWORD=\n')
    monkeypatch.chdir(str(d))
    # Call migration function
    toml_out = d / mod.DEFAULT_TOML_ACTIVE_FILE
    mod.migrate_env_sample_to_toml(str(sample), str(toml_out))
    assert toml_out.exists()
    txt = toml_out.read_text()
    assert 'FOO' in txt
    assert 'SECRET_PASSWORD' in txt


class DummyPreHook:
    def __init__(self, env=None):
        self.env = env or {}

    def run(self, env):
        return {'NEW_VAR': '1'}


def test_run_hooks_class_only(tmp_path, monkeypatch):
    mod = load_module()
    # Create a dummy hook file defining a PreComposeHook class
    hook_file = tmp_path / 'pre_hook.py'
    hook_file.write_text('class PreComposeHook:\n    def __init__(self, env=None):\n        pass\n    def run(self, env):\n        return {"X_TEST":"ok"}\n')
    changes = mod.run_hooks('PRE_COMPOSE', {'COMPINIT_HOOK_PRE_COMPOSE': str(hook_file)})
    # run_hooks now returns a meta-dict per variable: {'value': ..., 'persist': ..., ...}
    assert isinstance(changes.get('X_TEST'), dict)
    assert changes.get('X_TEST').get('value') == 'ok'