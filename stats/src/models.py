from sqlalchemy import BigInteger, Boolean, Index, Integer, String, Text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


# "protocol" (e.g. "xray", "hysteria" - see stats/src/protocols.py) joins
# every table below because a single node can run more than one protocol,
# each with its own independent, unrelated traffic counter for the same
# user - conflating them under a bare (node, user) key would corrupt the
# delta tracking in poller.accumulate() the moment a node runs a second
# protocol. Schema changes here require the documented reset-and-redeploy
# procedure (see stats/README.md) - there is no live migration.

class Health(Base):
    __tablename__ = "health"

    node: Mapped[str] = mapped_column(String(255), primary_key=True)
    protocol: Mapped[str] = mapped_column(String(32), primary_key=True)
    ok: Mapped[bool] = mapped_column(Boolean, nullable=False)
    latency_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    error: Mapped[str] = mapped_column(Text, nullable=False, default="")
    ts: Mapped[int] = mapped_column(Integer, nullable=False)


class PollRun(Base):
    __tablename__ = "poll_runs"
    __table_args__ = (
        Index("ix_poll_runs_ts", "ts"),
        Index("ix_poll_runs_node_ts", "node", "protocol", "ts"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    node: Mapped[str] = mapped_column(String(255), nullable=False)
    protocol: Mapped[str] = mapped_column(String(32), nullable=False)
    ok: Mapped[bool] = mapped_column(Boolean, nullable=False)
    latency_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    error: Mapped[str] = mapped_column(Text, nullable=False, default="")
    ts: Mapped[int] = mapped_column(Integer, nullable=False)


class Previous(Base):
    __tablename__ = "prev"

    node: Mapped[str] = mapped_column(String(255), primary_key=True)
    protocol: Mapped[str] = mapped_column(String(32), primary_key=True)
    user_name: Mapped[str] = mapped_column("user", String(255), primary_key=True)
    uplink: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    downlink: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    was_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)


class Total(Base):
    __tablename__ = "totals"

    node: Mapped[str] = mapped_column(String(255), primary_key=True)
    protocol: Mapped[str] = mapped_column(String(32), primary_key=True)
    user_name: Mapped[str] = mapped_column("user", String(255), primary_key=True)
    uplink: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    downlink: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    online: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    active_since: Mapped[int | None] = mapped_column(Integer)
    active_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    last_seen: Mapped[int | None] = mapped_column(Integer)
    last_online: Mapped[int | None] = mapped_column(Integer)


class Sample(Base):
    __tablename__ = "samples"
    __table_args__ = (
        Index("ix_samples_ts", "ts"),
        Index("ix_samples_node_ts", "node", "ts"),
        Index("ix_samples_user_ts", "user", "ts"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    node: Mapped[str] = mapped_column(String(255), nullable=False)
    protocol: Mapped[str] = mapped_column(String(32), nullable=False)
    user_name: Mapped[str] = mapped_column("user", String(255), nullable=False)
    ts: Mapped[int] = mapped_column(Integer, nullable=False)
    uplink: Mapped[int] = mapped_column(BigInteger, nullable=False)
    downlink: Mapped[int] = mapped_column(BigInteger, nullable=False)


Index("ix_samples_node_user_ts", Sample.node, Sample.protocol, Sample.user_name, Sample.ts)
