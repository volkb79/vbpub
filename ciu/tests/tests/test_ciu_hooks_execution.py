"""
CIU hook execution tests.
"""

from pathlib import Path

import sys
import tomllib

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ciu"))
from ciu import execute_hooks  # noqa: E402


def test_hook_env_updates_are_applied():
    def hook_one(config, env):
        return {"VAR1": "one"}

    def hook_two(config, env):
        return {"VAR2": "two"}

    config = {}
    env = {"EXISTING": "value"}

    result = execute_hooks([hook_one, hook_two], config, env)

    assert result["EXISTING"] == "value"
    assert result["VAR1"] == "one"
    assert result["VAR2"] == "two"


def test_hook_metadata_persists_to_toml(tmp_path):
    def hook_with_toml(config, env):
        return {
            "env.SECRET_TOKEN": {
                "value": "token",
                "persist": "toml",
                "apply_to_config": True,
            }
        }

    config = {"env": {}}
    env = {}

    stack_config_path = tmp_path / "ciu.toml"
    execute_hooks([hook_with_toml], config, env, stack_config_path=stack_config_path)

    with open(stack_config_path, "rb") as f:
        stored = tomllib.load(f)

    assert stored["env"]["SECRET_TOKEN"] == "token"
    assert config["env"]["SECRET_TOKEN"] == "token"
