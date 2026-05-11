"""Postgres connection pool — one process-wide instance shared across scrapers / ETL.

Usage:

    from neptune.db import get_conn

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            print(cur.fetchone())

Run this module as a script to smoke-test the DB:

    uv run python -m neptune.db
"""

from __future__ import annotations

import atexit
from collections.abc import Iterator
from contextlib import contextmanager

import psycopg
from psycopg_pool import ConnectionPool

from neptune.config import settings

# Lazy: pool is built on first call to `get_pool()`, not at import time, so a
# bare `import neptune` doesn't try to hit the DB.
_pool: ConnectionPool | None = None


def get_pool() -> ConnectionPool:
    global _pool
    if _pool is None:
        _pool = ConnectionPool(
            conninfo="",                            # using kwargs instead of a URI string
            kwargs={**settings.psycopg_kwargs, "autocommit": False},
            min_size=1,
            max_size=10,
            timeout=30,                             # seconds to wait for a free connection
            open=True,
        )
        atexit.register(_close_pool)
    return _pool


def _close_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


@contextmanager
def get_conn() -> Iterator[psycopg.Connection]:
    """Borrow a connection from the pool; auto-return on exit."""
    pool = get_pool()
    with pool.connection() as conn:
        yield conn


def healthcheck() -> dict[str, str]:
    """Run a trivial query to confirm the pool can connect."""
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT current_database(), current_user, version(), "
            "(SELECT COUNT(*) FROM pg_tables "
            " WHERE schemaname IN ('dim','raw','staging','marts'))::int AS project_tables"
        )
        db, user, version, n_tables = cur.fetchone()
    return {
        "database": db,
        "user": user,
        "version": version.split(" on ")[0],
        "project_tables": str(n_tables),
    }


if __name__ == "__main__":
    from rich import print as rprint

    rprint("[bold]neptune.db healthcheck[/bold]")
    rprint(healthcheck())
