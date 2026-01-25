"""
CIU registry authentication tests.
"""

from pathlib import Path
from unittest.mock import Mock, patch

import pytest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ciu"))
from ciu import validate_registry_auth  # noqa: E402


class TestRegistryAuthValidation:
    def test_local_mode_skips_validation(self):
        config = {"deploy": {"registry": {"url": ""}}}

        with patch("subprocess.run") as mock_run:
            validate_registry_auth(config)
            mock_run.assert_not_called()

    def test_external_mode_checks_authentication(self):
        config = {"deploy": {"registry": {"url": "registry.example.com"}}}

        with patch("subprocess.run") as mock_run:
            mock_result = Mock()
            mock_result.returncode = 0
            mock_result.stdout = "username:password"
            mock_run.return_value = mock_result

            validate_registry_auth(config)

            mock_run.assert_called_once()
            call_args = mock_run.call_args[0][0]
            assert "docker" in call_args
            assert "login" in call_args
            assert "--get-credentials" in call_args

    def test_fails_on_unauthenticated_registry(self):
        config = {"deploy": {"registry": {"url": "registry.example.com"}}}

        with patch("subprocess.run") as mock_run:
            mock_result = Mock()
            mock_result.returncode = 1
            mock_result.stdout = ""
            mock_run.return_value = mock_result

            with pytest.raises(SystemExit):
                validate_registry_auth(config)

    def test_handles_timeout(self):
        config = {"deploy": {"registry": {"url": "registry.example.com"}}}

        with patch("subprocess.run") as mock_run:
            import subprocess
            mock_run.side_effect = subprocess.TimeoutExpired("docker", 10)

            with pytest.raises(SystemExit):
                validate_registry_auth(config)
