#!/usr/bin/env python3
"""
CIU reset_service() tests.
"""

import os
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
from ciu.engine import reset_service  # noqa: E402


def _base_config() -> dict:
    return {
        "deploy": {
            "project_name": "test-project",
            "labels": {"prefix": "dstdns"},
        }
    }


class TestResetServiceDockerComposeDown:
    def test_runs_docker_compose_down(self, tmp_path, monkeypatch):
        config = _base_config()
        monkeypatch.chdir(tmp_path)

        with patch("subprocess.run") as mock_run:
            reset_service(config, working_dir=tmp_path, compose_file="docker-compose.yml.j2", yes=True)

            calls = [str(call) for call in mock_run.call_args_list]
            assert any("compose" in str(call) and "down" in str(call) for call in calls)


class TestResetServiceVolumeDirectories:
    def test_removes_vol_directories(self, tmp_path, monkeypatch):
        config = _base_config()
        monkeypatch.chdir(tmp_path)

        (tmp_path / "vol-postgres-data").mkdir()
        (tmp_path / "vol-redis-data").mkdir()
        (tmp_path / "not-a-volume").mkdir()

        with patch("subprocess.run"):
            reset_service(config, working_dir=tmp_path, compose_file="docker-compose.yml.j2", yes=True)

        assert not (tmp_path / "vol-postgres-data").exists()
        assert not (tmp_path / "vol-redis-data").exists()
        assert (tmp_path / "not-a-volume").exists()


class TestResetServiceConfigFiles:
    def test_removes_rendered_files(self, tmp_path, monkeypatch):
        config = _base_config()
        monkeypatch.chdir(tmp_path)

        (tmp_path / "docker-compose.yml").touch()
        (tmp_path / "ciu.toml").touch()

        with patch("subprocess.run"):
            reset_service(config, working_dir=tmp_path, compose_file="docker-compose.yml.j2", yes=True)

        assert not (tmp_path / "docker-compose.yml").exists()
        assert not (tmp_path / "ciu.toml").exists()


class TestResetServiceOrphanedContainers:
    def test_removes_orphaned_containers(self, tmp_path, monkeypatch):
        config = _base_config()
        monkeypatch.chdir(tmp_path)

        mock_ps = MagicMock()
        mock_ps.returncode = 0
        mock_ps.stdout = "orphan-1\norphan-2\n"

        def mock_run(cmd, **kwargs):
            if "ps" in cmd:
                return mock_ps
            return MagicMock(returncode=0)

        with patch("subprocess.run", side_effect=mock_run):
            reset_service(config, working_dir=tmp_path, compose_file="docker-compose.yml.j2", yes=True)


class TestResetServiceValidation:
    def test_requires_project_name(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        with pytest.raises(ValueError, match="deploy.project_name"):
            reset_service({}, working_dir=tmp_path, compose_file="docker-compose.yml.j2", yes=True)

    def test_requires_label_prefix(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        config = {"deploy": {"project_name": "test"}}

        with pytest.raises(ValueError, match="deploy.labels.prefix"):
            reset_service(config, working_dir=tmp_path, compose_file="docker-compose.yml.j2", yes=True)
