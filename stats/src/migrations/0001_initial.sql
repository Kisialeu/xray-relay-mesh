-- Initial schema for the central stats service.
-- Authored with SQLite "?" placeholders; translated to the active dialect at runtime.

create table if not exists health (
    node text primary key,
    ok integer not null,
    latency_ms integer not null,
    error text,
    ts integer not null
);

create table if not exists prev (
    node text not null,
    "user" text not null,
    uplink bigint not null,
    downlink bigint not null,
    was_active integer not null,
    primary key (node, "user")
);

create table if not exists totals (
    node text not null,
    "user" text not null,
    uplink bigint not null default 0,
    downlink bigint not null default 0,
    online integer not null default 0,
    active integer not null default 0,
    last_seen integer,
    last_online integer,
    primary key (node, "user")
);

create table if not exists samples (
    node text not null,
    "user" text not null,
    ts integer not null,
    uplink bigint not null,
    downlink bigint not null
);

create index if not exists idx_samples_user_ts on samples(node, "user", ts);

create index if not exists idx_samples_ts on samples(ts);
