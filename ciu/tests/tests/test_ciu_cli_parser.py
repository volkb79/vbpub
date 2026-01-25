"""
CIU CLI argument parser tests.
"""

from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ciu"))
from ciu import parse_arguments  # noqa: E402


class TestParseArgumentsDefaults:
    def test_default_values(self):
        args = parse_arguments([])

        assert args.dir == Path.cwd()
        assert args.file == "docker-compose.yml.j2"
        assert args.dry_run is False
        assert args.render_toml is False
        assert args.print_context is False
        assert args.skip_hostdir_check is False
        assert args.skip_hooks is False
        assert args.skip_secrets is False
        assert args.yes is False
        assert args.reset is False
        assert args.define_root is None


class TestParseArgumentsFlags:
    def test_dir_and_file_flags(self):
        args = parse_arguments(["-d", "/tmp/service", "-f", "custom.yml.j2"])

        assert args.dir == Path("/tmp/service")
        assert args.file == "custom.yml.j2"

    def test_define_root_flag(self):
        args = parse_arguments(["--define-root", "/tmp/repo"])

        assert args.define_root == Path("/tmp/repo")

    def test_root_folder_alias(self):
        args = parse_arguments(["--root-folder", "/tmp/repo"])

        assert args.define_root == Path("/tmp/repo")

    def test_boolean_flags(self):
        args = parse_arguments([
            "--dry-run",
            "--print-context",
            "--render-toml",
            "--skip-hostdir-check",
            "--skip-hooks",
            "--skip-secrets",
            "--reset",
            "-y",
        ])

        assert args.dry_run is True
        assert args.print_context is True
        assert args.render_toml is True
        assert args.skip_hostdir_check is True
        assert args.skip_hooks is True
        assert args.skip_secrets is True
        assert args.reset is True
        assert args.yes is True


class TestParseArgumentsEdgeCases:
    def test_relative_directory(self):
        args = parse_arguments(["-d", "./services/postgres"])

        assert args.dir == Path("./services/postgres")

    def test_duplicate_flag_last_wins(self):
        args = parse_arguments(["-d", "/tmp", "-d", "/opt"])

        assert args.dir == Path("/opt")


class TestParseArgumentsHelp:
    def test_has_docstring(self):
        assert parse_arguments.__doc__ is not None
        assert "arguments" in parse_arguments.__doc__.lower()
