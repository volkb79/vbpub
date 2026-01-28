#!/usr/bin/env python3
"""
CIU auto_generate_values() tests.
"""

from pathlib import Path
from unittest.mock import patch

import pytest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
from ciu.engine import auto_generate_values  # noqa: E402


def _base_config() -> dict:
    return {
        "deploy": {
            "env": {
                "shared": {
                    "CONTAINER_UID": "1001",
                    "CONTAINER_GID": "118",
                    "DOCKER_GID": "118",
                }
            }
        }
    }


def test_populates_build_metadata_and_ids():
    config = _base_config()

    with patch("ciu.engine.get_git_hash", return_value="abcd1234"), patch(
        "ciu.engine.get_timestamp", return_value="2026-01-23T00:00:00+00:00"
    ):
        result = auto_generate_values(config)

    auto_generated = result["auto_generated"]
    assert auto_generated["build_version"] == "abcd1234"
    assert auto_generated["build_time"] == "2026-01-23T00:00:00+00:00"
    assert auto_generated["uid"] == "1001"
    assert auto_generated["gid"] == "118"
    assert auto_generated["docker_gid"] == "118"


def test_missing_deploy_shared_raises():
    with pytest.raises(ValueError, match="CONTAINER_UID and DOCKER_GID"):
        auto_generate_values({})
