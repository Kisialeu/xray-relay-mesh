-- Push/fallback ingest support: tracks which source last reported for each
-- node and records push event outcomes for observability.

create table if not exists ingest_health (
    node text primary key,
    ok integer not null,
    source text not null,
    latency_ms integer not null default 0,
    error text,
    ts integer not null
);

create table if not exists push_events (
    node text not null,
    ts integer not null,
    accepted integer not null,
    reason text not null
);

create index if not exists idx_push_events_node_ts on push_events(node, ts);
