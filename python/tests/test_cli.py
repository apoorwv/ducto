"""Tests for ducto CLI argument parsing and error handling."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from ducto.interface.memory import MemoryStore


def _run(*args: str) -> None:
    """Invoke ducto CLI main() with given args, capturing sys.exit."""
    from ducto.__main__ import main

    old_argv = sys.argv
    try:
        sys.argv = ["ducto", *args]
        main()
    finally:
        sys.argv = old_argv


@pytest.fixture
def mem_store(monkeypatch: pytest.MonkeyPatch) -> MemoryStore:
    """Replace _store_from_env with an in-memory store."""
    store = MemoryStore()
    monkeypatch.setenv("SUPABASE_URL", "http://localhost")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "test-key")

    import ducto.__main__ as cli_mod

    cli_mod._store_from_env = lambda: store  # type: ignore[method-assign]
    return store


@pytest.fixture
def sample_config(tmp_path: Path) -> str:
    """Write a minimal pricing config and return its path."""
    p = tmp_path / "pricing.json"
    p.write_text(json.dumps({"models": {"_default": "input_tokens * 1"}}))
    return str(p)


class TestMigrate:
    def test_migrate_no_args_exits_with_error(self) -> None:
        with pytest.raises(SystemExit):
            _run("migrate")


class TestPricing:
    def test_pricing_no_subcommand_exits_with_error(self) -> None:
        with pytest.raises(SystemExit):
            _run("pricing")

    def test_pricing_unknown_subcommand_exits_with_error(self) -> None:
        with pytest.raises(SystemExit):
            _run("pricing", "fly")

    def test_pricing_set_no_file_exits_with_error(self) -> None:
        with pytest.raises(SystemExit):
            _run("pricing", "set")

    def test_pricing_set_file_not_found_exits_with_error(self) -> None:
        with pytest.raises(SystemExit):
            _run("pricing", "set", "/nonexistent/file.json")

    def test_pricing_get_no_env_exits_with_error(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("SUPABASE_URL", raising=False)
        monkeypatch.delenv("SUPABASE_SERVICE_ROLE_KEY", raising=False)
        with pytest.raises(SystemExit):
            _run("pricing", "get")

    def test_pricing_validate_valid(self, capsys: pytest.CaptureFixture, sample_config: str) -> None:
        _run("pricing", "validate", sample_config)
        captured = capsys.readouterr()
        assert "valid" in captured.out

    def test_pricing_validate_invalid(self, tmp_path: Path) -> None:
        p = tmp_path / "bad.json"
        p.write_text('{"models": []}')
        with pytest.raises(SystemExit):
            _run("pricing", "validate", str(p))

    # ── Integration tests (use MemoryStore backend) ──────────────────────

    def test_pricing_set_always_creates_new_version(self, mem_store: MemoryStore, sample_config: str) -> None:
        for _ in range(3):
            _run("pricing", "set", sample_config)
        assert len(mem_store.get_pricing_history()) == 3

    def test_pricing_set_with_label(self, mem_store: MemoryStore, sample_config: str) -> None:
        _run("pricing", "set", sample_config, "--label", "deploy-42")
        active = mem_store.get_active_pricing()
        assert active is not None
        assert active.label == "deploy-42"

    def test_pricing_get_shows_active(
        self, mem_store: MemoryStore, capsys: pytest.CaptureFixture, sample_config: str
    ) -> None:
        _run("pricing", "set", sample_config)
        _run("pricing", "get")
        captured = capsys.readouterr()
        assert "input_tokens * 1" in captured.out

    def test_pricing_get_returns_error_when_no_active(
        self, mem_store: MemoryStore, capsys: pytest.CaptureFixture
    ) -> None:
        with pytest.raises(SystemExit):
            _run("pricing", "get")
        captured = capsys.readouterr()
        assert "No active pricing config" in captured.err

    def test_pricing_list_shows_version(
        self, mem_store: MemoryStore, capsys: pytest.CaptureFixture, sample_config: str
    ) -> None:
        _run("pricing", "set", sample_config)
        _run("pricing", "list")
        captured = capsys.readouterr()
        assert "v1" in captured.out

    def test_pricing_list_shows_marker_for_active(
        self, mem_store: MemoryStore, capsys: pytest.CaptureFixture, tmp_path: Path
    ) -> None:
        def _make_conf(val: str) -> str:
            p = tmp_path / f"p{val}.json"
            p.write_text(json.dumps({"models": {"_default": f"input_tokens * {val}"}}))
            return str(p)

        _run("pricing", "set", _make_conf("1"), "--label", "v1")
        _run("pricing", "set", _make_conf("2"), "--label", "v2")
        _run("pricing", "list")
        captured = capsys.readouterr()
        assert "* v2" in captured.out  # latest is active
        assert "  v1" in captured.out  # old is inactive

    def test_pricing_list_shows_error_when_no_configs(
        self, mem_store: MemoryStore, capsys: pytest.CaptureFixture
    ) -> None:
        with pytest.raises(SystemExit):
            _run("pricing", "list")
        captured = capsys.readouterr()
        assert "No pricing configs found" in captured.err

    def test_pricing_activate_switches_active(
        self, mem_store: MemoryStore, capsys: pytest.CaptureFixture, tmp_path: Path
    ) -> None:
        def _make_conf(val: str) -> str:
            p = tmp_path / f"p{val}.json"
            p.write_text(json.dumps({"models": {"_default": f"input_tokens * {val}"}}))
            return str(p)

        _run("pricing", "set", _make_conf("1"), "--label", "v1")
        _run("pricing", "set", _make_conf("2"), "--label", "v2")

        # Activate v1
        _run("pricing", "activate", "1")
        active = mem_store.get_active_pricing()
        assert active is not None
        assert active.version == 1
        assert active.label == "v1"

        # Activate v2
        _run("pricing", "activate", "2")
        active = mem_store.get_active_pricing()
        assert active is not None
        assert active.version == 2

    def test_pricing_activate_missing_version(self, mem_store: MemoryStore, sample_config: str) -> None:
        _run("pricing", "set", sample_config)
        with pytest.raises(SystemExit):
            _run("pricing", "activate", "99")

    def test_pricing_export_returns_config(
        self, mem_store: MemoryStore, capsys: pytest.CaptureFixture, sample_config: str
    ) -> None:
        _run("pricing", "set", sample_config)
        _run("pricing", "export", "1")
        captured = capsys.readouterr()
        assert "input_tokens" in captured.out

    def test_pricing_export_missing_version(self, mem_store: MemoryStore, sample_config: str) -> None:
        _run("pricing", "set", sample_config)
        with pytest.raises(SystemExit):
            _run("pricing", "export", "99")

    def test_pricing_diff_shows_changes(
        self, mem_store: MemoryStore, capsys: pytest.CaptureFixture, tmp_path: Path
    ) -> None:
        p1 = tmp_path / "a.json"
        p1.write_text(json.dumps({"models": {"a": "1"}}))
        p2 = tmp_path / "b.json"
        p2.write_text(json.dumps({"models": {"b": "1"}}))
        _run("pricing", "set", str(p1))
        _run("pricing", "set", str(p2))
        _run("pricing", "diff", "1", "2")
        captured = capsys.readouterr()
        assert "v1" in captured.out
        assert "v2" in captured.out

    def test_pricing_diff_no_args_exits_with_error(self) -> None:
        with pytest.raises(SystemExit):
            _run("pricing", "diff")

    def test_pricing_diff_missing_version(self, mem_store: MemoryStore, sample_config: str) -> None:
        _run("pricing", "set", sample_config)
        with pytest.raises(SystemExit):
            _run("pricing", "diff", "1", "99")


class TestRoot:
    def test_no_args_exits_with_error(self) -> None:
        with pytest.raises(SystemExit):
            _run()

    def test_unknown_command_exits_with_error(self) -> None:
        with pytest.raises(SystemExit):
            _run("blarg")
