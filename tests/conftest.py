"""Fixtures for integration tests — uses pg_tmp for disposable Postgres."""

from __future__ import annotations

import shutil
import subprocess
import time
from collections.abc import Iterator

import pytest

PG_TMP = shutil.which("pg_tmp") or "/opt/homebrew/bin/pg_tmp"


@pytest.fixture(scope="function")
def pg_database_url() -> Iterator[str]:
    """Spin up a disposable Postgres via pg_tmp, yield connection URL.

    The process exits after printing the DSN (postgres keeps running
    in the background).  The temp dir is cleaned up when the stop
    timeout expires or on SIGTERM/SIGKILL.
    """
    proc = subprocess.Popen(
        [PG_TMP, "-w", "60"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    dsn = proc.stdout.readline().strip() if proc.stdout else ""
    if not dsn:
        stderr = proc.stderr.read() if proc.stderr else ""
        proc.kill()
        raise RuntimeError(f"pg_tmp failed to start: {stderr}")

    # pg_tmp backgrounds itself and exits. Wait for Postgres to accept connections.
    import psycopg2

    deadline = time.monotonic() + 30
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            conn = psycopg2.connect(dsn)
            conn.close()
            break
        except Exception as e:
            last_err = e
            time.sleep(0.3)
    else:
        raise RuntimeError(f"pg_database_url not ready after 30s: {last_err}")

    # Create Supabase-like objects that ducto SQL migrations depend on.
    _preseed_supabase_objects(dsn)

    yield dsn

    # pg_tmp -w N schedules auto-stop; no explicit teardown needed.


def _preseed_supabase_objects(dsn: str) -> None:
    """Create minimal Supabase objects (auth schema, roles, functions) in a
    plain Postgres so ducto's bundled SQL migrations can run without error.

    This mirrors what Supabase provides automatically in its hosted Postgres.
    """
    import psycopg2

    conn = psycopg2.connect(dsn)
    try:
        conn.autocommit = True
        with conn.cursor() as cur:
            # 1. auth schema + core uid/role functions
            cur.execute("CREATE SCHEMA IF NOT EXISTS auth")
            for func in [
                (
                    "auth.uid()",
                    """
                    CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
                    LANGUAGE sql STABLE
                    AS $$ SELECT coalesce(
                        nullif(current_setting('request.jwt.claim.sub', true), ''),
                        current_setting('request.jwt.claims', true)::jsonb ->> 'sub'
                    )::uuid $$;
                    """,
                ),
                (
                    "auth.role()",
                    """
                    CREATE OR REPLACE FUNCTION auth.role() RETURNS text
                    LANGUAGE sql STABLE
                    AS $$ SELECT coalesce(
                        nullif(current_setting('request.jwt.claim.role', true), ''),
                        'service_role'
                    ) $$;
                    """,
                ),
            ]:
                try:
                    cur.execute(func[1])
                except Exception:
                    conn.rollback()
                else:
                    conn.commit()

            # 2. Minimal auth.users table for the signup-bonus trigger
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS auth.users (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    email TEXT,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                );
            """
            )

            # 3. Standard Supabase roles
            for role in ("anon", "authenticated", "service_role"):
                try:
                    cur.execute(f"CREATE ROLE {role}")
                except Exception:
                    conn.rollback()
                else:
                    conn.commit()
    finally:
        conn.close()
