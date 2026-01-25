#!/usr/bin/env python3
"""
CIU create_hostdirs() tests.
"""

from pathlib import Path
from unittest.mock import patch

import pytest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ciu"))
from ciu import create_hostdirs  # noqa: E402


def _base_config() -> dict:
    return {
        "deploy": {
            "env": {
                "shared": {
                    "CONTAINER_UID": "1000",
                    "CONTAINER_GID": "1000",
                    "DOCKER_GID": "994",
                }
            }
        }
    }


def test_creates_explicit_hostdir_paths():
    config = _base_config()
    config["service"] = {
        "name": "demo-service",
        "hostdir": {
            "data": "./vol-demo-service-data",
            "logs": "./vol-demo-service-logs",
        },
    }

    with patch("pathlib.Path.mkdir") as mock_mkdir, patch("os.chown") as mock_chown:
        create_hostdirs(config)

        assert mock_mkdir.call_count == 2
        assert mock_chown.call_count == 2


def test_generates_missing_hostdir_paths():
    config = _base_config()
    config["service"] = {
        "name": "demo-service",
        "hostdir": {
            "data": "",
            "logs": "",
        },
    }

    with patch("pathlib.Path.mkdir"), patch("os.chown"):
        create_hostdirs(config)

    assert config["service"]["hostdir"]["data"] == "./vol-demo-service-data"
    assert config["service"]["hostdir"]["logs"] == "./vol-demo-service-logs"


def test_requires_service_name_for_hostdir():
    config = _base_config()
    config["service"] = {
        "hostdir": {
            "data": "",
        }
    }

    with pytest.raises(ValueError, match="hostdir section found without service name"):
        create_hostdirs(config)


def test_requires_deploy_shared_values():
    with pytest.raises(ValueError, match="CONTAINER_UID/DOCKER_GID"):
        create_hostdirs({})
