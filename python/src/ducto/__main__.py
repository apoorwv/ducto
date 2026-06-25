"""ducto CLI — migrate, pricing management."""

from __future__ import annotations

import difflib
import json
import os
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from ducto.interface.models import PricingConfigResult
    from ducto.interface.supabase import HttpxSupabaseStore

try:
    from dotenv import load_dotenv
except ImportError:
    load_dotenv = None  # type: ignore[assignment]


def _load_env() -> None:
    """Load .env from CWD. Won't override env vars already set."""
    env_path = Path.cwd() / ".env"
    if env_path.is_file() and load_dotenv:
        load_dotenv(env_path, override=False)


_RETRY_DELAY = 2
_RETRIES = 15

# Extra name → top-level import names needed
_EXTRAS: dict[str, list[str]] = {
    "postgres": ["psycopg2"],
    "supabase": ["httpx"],
}


def _require_extra(extra: str) -> None:
    """Exit with install hint if any import for *extra* is missing."""
    for mod in _EXTRAS.get(extra, []):
        try:
            __import__(mod)
        except ImportError:
            print(
                f"ducto[{extra}] extra required (missing: {mod}). pip install ducto[{extra}]",
                file=sys.stderr,
            )
            sys.exit(1)


def _store_from_env() -> HttpxSupabaseStore:
    """Create HttpxSupabaseStore from SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY."""
    _require_extra("supabase")

    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url:
        print("SUPABASE_URL required", file=sys.stderr)
        sys.exit(1)
    if not key:
        print("SUPABASE_SERVICE_ROLE_KEY required", file=sys.stderr)
        sys.exit(1)

    from ducto.interface.supabase import HttpxSupabaseStore

    return HttpxSupabaseStore(url=url, key=key)


def _migrate(args: list[str]) -> None:
    _require_extra("postgres")

    if not args:
        print("Usage: ducto migrate <database_url>", file=sys.stderr)
        sys.exit(1)

    from ducto.interface.supabase import run_migrations

    result = run_migrations(args[0])
    for t in result.tables_created:
        print(f"  ✓ {t}")
    for e in result.errors:
        print(f"  ✗ {e}", file=sys.stderr)

    if result.success:
        print("Migration complete.")
    else:
        print("Migration completed with errors.", file=sys.stderr)
        sys.exit(1)


def _load_pricing_file(filepath: str) -> dict[str, Any]:
    """Read a JSON or YAML pricing config file."""
    if filepath == "-":
        return json.load(sys.stdin)
    if filepath.endswith((".yaml", ".yml")):
        try:
            import yaml
        except ImportError:
            print("PyYAML required for .yaml files: pip install ducto[supabase]", file=sys.stderr)
            sys.exit(1)
        try:
            with open(filepath) as f:
                return yaml.safe_load(f)
        except FileNotFoundError:
            print(f"File not found: {filepath}", file=sys.stderr)
            sys.exit(1)
    else:
        try:
            with open(filepath) as f:
                return json.load(f)
        except FileNotFoundError:
            print(f"File not found: {filepath}", file=sys.stderr)
            sys.exit(1)


def _pricing_validate(args: list[str]) -> None:
    """Validate a pricing file without applying it."""
    if not args:
        print("Usage: ducto pricing validate <file.json|file.yaml>", file=sys.stderr)
        sys.exit(1)

    from ducto.config import PricingConfig
    from ducto.interface.models import PricingConfigData

    data = _load_pricing_file(args[0])
    PricingConfigData.model_validate(data)
    PricingConfig.model_validate(data)
    print("Pricing config is valid.")


def _pricing_set(args: list[str]) -> None:
    """Apply new pricing — always creates a new version."""
    if not args:
        print("Usage: ducto pricing set <file.json|file.yaml> [--label <message>]", file=sys.stderr)
        sys.exit(1)

    from ducto.interface.models import PricingConfigData

    filepath = args[0]
    label = None
    if len(args) > 2 and args[1] == "--label":
        label = args[2]

    data = _load_pricing_file(filepath)
    config = PricingConfigData.model_validate(data)

    store = _store_from_env()

    # Retry: PostgREST schema cache may not be refreshed yet
    for attempt in range(_RETRIES):
        try:
            store.set_active_pricing(config, label=label)
            print("Pricing config set successfully.")
            return
        except Exception as exc:
            if attempt == _RETRIES - 1:
                print(f"Failed to set pricing: {exc}", file=sys.stderr)
                print("Tip: Ensure 'ducto migrate' has been run and the schema cache has refreshed.", file=sys.stderr)
                sys.exit(1)
            time.sleep(_RETRY_DELAY)


def _pricing_get(args: list[str]) -> None:
    """Show active pricing config."""
    store = _store_from_env()
    for attempt in range(_RETRIES):
        try:
            result = store.get_active_pricing()
            if result is None:
                print("No active pricing config.", file=sys.stderr)
                sys.exit(1)
            print(json.dumps(result.model_dump(mode="json"), indent=2))
            return
        except Exception as exc:
            if attempt == _RETRIES - 1:
                print(f"Failed to get pricing: {exc}", file=sys.stderr)
                print("Tip: Ensure 'ducto migrate' has been run and the schema cache has refreshed.", file=sys.stderr)
                sys.exit(1)
            time.sleep(_RETRY_DELAY)


def _pricing_list(_args: list[str] | None = None) -> None:
    """List all pricing config versions."""
    store = _store_from_env()
    for attempt in range(_RETRIES):
        try:
            rows = store.get_pricing_history()
            if not rows:
                print("No pricing configs found.", file=sys.stderr)
                sys.exit(1)
            for r in rows:
                marker = "*" if r.active else " "
                label = f"  {r.label}" if r.label else ""
                print(f"  {marker} v{r.version}  (id={r.id[:8]}...){label}  {r.created_at[:19]}")
            return
        except Exception as exc:
            if attempt == _RETRIES - 1:
                print(f"Failed to list pricing: {exc}", file=sys.stderr)
                sys.exit(1)
            time.sleep(_RETRY_DELAY)


def _pricing_activate(args: list[str]) -> None:
    """Activate a specific pricing version."""
    if not args:
        print("Usage: ducto pricing activate <version>", file=sys.stderr)
        sys.exit(1)

    store = _store_from_env()
    version = int(args[0])
    for attempt in range(_RETRIES):
        try:
            store.activate_pricing(version)
            print(f"Pricing v{version} activated.")
            return
        except Exception as exc:
            if attempt == _RETRIES - 1:
                print(f"Failed to activate pricing: {exc}", file=sys.stderr)
                sys.exit(1)
            time.sleep(_RETRY_DELAY)


def _pricing_diff(args: list[str]) -> None:
    """Show diff between two pricing versions."""
    if len(args) < 2:
        print("Usage: ducto pricing diff <version_a> <version_b>", file=sys.stderr)
        sys.exit(1)

    store = _store_from_env()
    v1 = int(args[0])
    v2 = int(args[1])

    a: PricingConfigResult | None = None
    b: PricingConfigResult | None = None
    for attempt in range(_RETRIES):
        try:
            a = store.get_pricing_config(v1)
            b = store.get_pricing_config(v2)
            break
        except Exception as exc:
            if attempt == _RETRIES - 1:
                print(f"Failed to fetch pricing configs: {exc}", file=sys.stderr)
                sys.exit(1)
            time.sleep(_RETRY_DELAY)

    if a is None:
        print(f"Version {v1} not found.", file=sys.stderr)
        sys.exit(1)
    if b is None:
        print(f"Version {v2} not found.", file=sys.stderr)
        sys.exit(1)

    a_json = json.dumps(a.config.model_dump(mode="json"), indent=2)
    b_json = json.dumps(b.config.model_dump(mode="json"), indent=2)

    diff = difflib.unified_diff(
        a_json.splitlines(keepends=True),
        b_json.splitlines(keepends=True),
        fromfile=f"v{v1}",
        tofile=f"v{v2}",
    )
    sys.stdout.writelines(diff)


def _pricing_export(args: list[str]) -> None:
    """Export a specific pricing version as JSON."""
    if not args:
        print("Usage: ducto pricing export <version>", file=sys.stderr)
        sys.exit(1)

    store = _store_from_env()
    version = int(args[0])

    result: PricingConfigResult | None = None
    for attempt in range(_RETRIES):
        try:
            result = store.get_pricing_config(version)
            break
        except Exception as exc:
            if attempt == _RETRIES - 1:
                print(f"Failed to fetch pricing: {exc}", file=sys.stderr)
                sys.exit(1)
            time.sleep(_RETRY_DELAY)

    if result is None:
        print(f"Version {version} not found.", file=sys.stderr)
        sys.exit(1)

    print(json.dumps(result.config.model_dump(mode="json", exclude_none=True), indent=2))


def _pricing(args: list[str]) -> None:
    if not args:
        print("Usage: ducto pricing <set|get|list|activate|validate|diff|export> [...]", file=sys.stderr)
        sys.exit(1)

    sub = args[0]
    subcommands: dict[str, Callable[[list[str]], None]] = {
        "set": _pricing_set,
        "get": _pricing_get,
        "list": _pricing_list,
        "activate": _pricing_activate,
        "validate": _pricing_validate,
        "diff": _pricing_diff,
        "export": _pricing_export,
    }
    handler = subcommands.get(sub)
    if handler is None:
        print(f"Unknown pricing subcommand: {sub}", file=sys.stderr)
        sys.exit(1)
    handler(args[1:])


def _usage() -> None:
    lines = [
        "Usage: ducto <command> [options]",
        "",
        "Commands:",
    ]
    for name, (help_text, _) in sorted(_COMMANDS.items()):
        lines.append(f"  {name:<12} {help_text}")
    lines += [
        "",
        "Options:",
        "  -h, --help    Show this help message",
        "",
        "Extras:",
        "  pip install ducto[postgres]   Postgres migration support",
        "  pip install ducto[supabase]   Supabase REST API support",
        "  pip install ducto[test]       Development & test tooling",
    ]
    print("\n".join(lines))


# Command registry: name → (help text, handler)
_COMMANDS: dict[str, tuple[str, Callable[[list[str]], None]]] = {
    "migrate": (
        "<database_url> — Run database migrations (ducto[postgres])",
        _migrate,
    ),
    "pricing": (
        "set|get|list|activate|validate|diff|export — Manage pricing config (ducto[supabase])",
        _pricing,
    ),
}


def main() -> None:
    _load_env()

    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        _usage()
        sys.exit(0)

    cmd = sys.argv[1]
    entry = _COMMANDS.get(cmd)
    if entry is None:
        print(f"Unknown command: {cmd}\n", file=sys.stderr)
        _usage()
        sys.exit(1)
    entry[1](sys.argv[2:])


if __name__ == "__main__":
    main()
