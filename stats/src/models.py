from sqlalchemy import BigInteger, Boolean, Index, Integer, String, Text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class Health(Base):
    __tablename__ = "health"

    node: Mapped[str] = mapped_column(String(255), primary_key=True)
    ok: Mapped[bool] = mapped_column(Boolean, nullable=False)
    latency_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    error: Mapped[str] = mapped_column(Text, nullable=False, default="")
    ts: Mapped[int] = mapped_column(Integer, nullable=False)


class Previous(Base):
    __tablename__ = "prev"

    node: Mapped[str] = mapped_column(String(255), primary_key=True)
    user_name: Mapped[str] = mapped_column("user", String(255), primary_key=True)
    uplink: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    downlink: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    was_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)


class Total(Base):
    __tablename__ = "totals"

    node: Mapped[str] = mapped_column(String(255), primary_key=True)
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
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    node: Mapped[str] = mapped_column(String(255), nullable=False)
    user_name: Mapped[str] = mapped_column("user", String(255), nullable=False)
    ts: Mapped[int] = mapped_column(Integer, nullable=False)
    uplink: Mapped[int] = mapped_column(BigInteger, nullable=False)
    downlink: Mapped[int] = mapped_column(BigInteger, nullable=False)


Index("ix_samples_node_user_ts", Sample.node, Sample.user_name, Sample.ts)
