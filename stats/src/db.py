import re
import sqlite3
import threading
import time
from pathlib import Path

from config import DATABASE_URL, DB_PATH

try:
    import psycopg
    from psycopg.rows import dict_row
except ImportError:
    psycopg = None
    dict_row = None

DB_LOCK = threading.Lock()
DB_IS_POSTGRES = DATABASE_URL.startswith(("postgres://", "postgresql://"))

# Directory holding versioned SQL migration scripts, resolved relative to this module.
MIGRATIONS_DIR = Path(__file__).resolve().parent / "migrations"
_MIGRATION_RE = re.compile(r"^(\d+)_(.+)\.sql$")


def connect_db():
    if DB_IS_POSTGRES:
        if psycopg is None:
            raise RuntimeError("psycopg is required when STATS_DATABASE_URL is PostgreSQL")
        deadline = time.monotonic() + 60
        while True:
            try:
                return psycopg.connect(DATABASE_URL, row_factory=dict_row, connect_timeout=5)
            except psycopg.OperationalError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(2)

    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("pragma journal_mode=wal")
    conn.execute("pragma busy_timeout=5000")
    return conn


DB = connect_db()


def _sql(sql):
    return sql.replace("?", "%s") if DB_IS_POSTGRES else sql


def db_execute(sql, args=()):
    return DB.execute(_sql(sql), args)


def db_fetchone(sql, args=()):
    return db_execute(sql, args).fetchone()


def db_fetchall(sql, args=()):
    return db_execute(sql, args).fetchall()


def _load_migrations():
    """Return migrations as a list of (version, name, sql) sorted by version.

    Migration SQL is authored with SQLite ``?`` placeholders; the active dialect
    is applied via ``_sql`` at execution time, mirroring the rest of the code.
    """
    migrations = []
    if not MIGRATIONS_DIR.is_dir():
        return migrations
    for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
        match = _MIGRATION_RE.match(path.name)
        if not match:
            continue
        version = int(match.group(1))
        name = match.group(2)
        sql = _strip_comments(path.read_text(encoding="utf-8"))
        migrations.append((version, name, sql))
    migrations.sort(key=lambda item: item[0])
    return migrations


def _strip_comments(sql):
    """Remove single-line ``--`` SQL comments so the ``;`` splitter never sees them."""
    out = []
    for line in sql.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("--"):
            continue
        out.append(line)
    return "\n".join(out)


def _applied_versions():
    """Set of already-applied migration versions, creating the tracking table if absent."""
    db_execute(
        "create table if not exists schema_migrations ("
        "version integer primary key, "
        "name text not null, "
        "applied_at integer not null)"
    )
    DB.commit()
    rows = db_fetchall("select version from schema_migrations")
    return {int(row[0]) for row in rows}


def init_db():
    """Apply pending migrations in version order, idempotently.

    Each migration runs in its own transaction (commit after the script) so a
    partial failure leaves the database at the last fully-applied version.
    """
    with DB_LOCK:
        applied = _applied_versions()
        for version, name, sql in _load_migrations():
            if version in applied:
                continue
            for statement in sql.split(";"):
                statement = statement.strip()
                if statement:
                    db_execute(statement)
            db_execute(
                "insert into schema_migrations(version, name, applied_at) values(?, ?, ?)",
                (version, name, int(time.time())),
            )
            DB.commit()
