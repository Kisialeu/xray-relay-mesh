import threading
from contextlib import contextmanager, nullcontext
from pathlib import Path
from typing import Iterator

from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from config import DATABASE_URL, DB_PATH
from models import Base


DB_LOCK = threading.Lock()
DB_IS_POSTGRES = DATABASE_URL.startswith(("postgres://", "postgresql://", "postgresql+psycopg://"))


def _database_url() -> str:
    if DB_IS_POSTGRES:
        if DATABASE_URL.startswith("postgres://"):
            return "postgresql+psycopg://" + DATABASE_URL[len("postgres://"):]
        if DATABASE_URL.startswith("postgresql://"):
            return "postgresql+psycopg://" + DATABASE_URL[len("postgresql://"):]
        return DATABASE_URL

    path = Path(DB_PATH).expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    return f"sqlite:///{path}"


def _create_engine() -> Engine:
    kwargs = {"pool_pre_ping": True}
    if DB_IS_POSTGRES:
        kwargs["connect_args"] = {"connect_timeout": 5}
    else:
        kwargs["connect_args"] = {"check_same_thread": False}
    return create_engine(_database_url(), **kwargs)


ENGINE = _create_engine()
SessionLocal = sessionmaker(bind=ENGINE, autoflush=True, expire_on_commit=False)


@contextmanager
def session_scope() -> Iterator[Session]:
    """Serialize SQLite access while allowing normal PostgreSQL concurrency."""
    lock = DB_LOCK if not DB_IS_POSTGRES else nullcontext()
    with lock:
        session = SessionLocal()
        try:
            yield session
            session.commit()
        except Exception:
            session.rollback()
            raise
        finally:
            session.close()


def init_db() -> None:
    """Create the schema and any missing additive indexes."""
    Base.metadata.create_all(ENGINE)
    for table in Base.metadata.tables.values():
        for index in table.indexes:
            index.create(ENGINE, checkfirst=True)
