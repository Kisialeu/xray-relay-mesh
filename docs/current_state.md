# Example infrastructure state

This is a sanitized topology illustration. It preserves service relationships
but replaces node identities and precise locations with generic labels. It is
not an inventory or a source of deployment values.

Hostnames, IP addresses, domains, ports, credentials, user identities, UUIDs,
tokens, secret values, and provider identifiers are intentionally omitted.

## Topology summary

| Node | Approximate region | Protocols | Additional role | Public relay entry |
|---|---|---|---|---|
| Node A | Northern region | Xray VLESS/Reality | Statistics aggregation | No |
| Node B | Central region | Xray VLESS/Reality | Subscription origin | No |
| Node C | Eastern region | Xray VLESS/Reality and Hysteria2 | Hysteria2 endpoint | No |

All three nodes are configured as Xray destinations. Hysteria2 is enabled only
on Node C.

```text
                         +----------------------+
                         | Client applications  |
                         +----------+-----------+
                                    |
                  +-----------------+-----------------+
                  |                 |                 |
                  v                 v                 v
        +------------------+ +------------------+ +------------------+
        | Node A           | | Node B           | | Node C           |
        | Northern region  | | Central region   | | Eastern region   |
        | Xray TCP         | | Xray TCP         | | Xray TCP         |
        | Statistics       | | Subscriptions    | | Hysteria2 UDP    |
        +------------------+ +------------------+ +------------------+
```

## Subscription flow

```text
  +--------------------+
  | Client             |
  +----------+---------+
             |
             | HTTPS
             v
  +--------------------+
  | CloudFront         |
  | Deployment unknown |
  +----------+---------+
             |
             | Verified origin request
             v
  +--------------------+
  | Node B             |
  | Subscription origin |
  +----------+---------+
             |
             v
  +--------------------+
  | Private per-user   |
  | subscriptions      |
  +----------+---------+
             |
             +--> Xray direct entries for all regions
             |
             +--> Hysteria2 direct entry for Node C
             |
             +--> No relay entries in this sanitized topology
```

## Direct protocol paths

### Xray

Every node accepts direct VLESS/Reality traffic over TCP. Reality key material
is configured and shared by the rendered node configurations.

```text
  Client
    |
    | VLESS/Reality over TCP
    v
  Selected regional Xray node
    |
    +--> DNS through configured server-side resolvers
    |
    +--> Default traffic ------------> Direct Internet
    |
    +--> Policy-routed traffic ------> Alternate egress ---> Internet
    |
    +--> Prohibited traffic ---------> Block
```

### Hysteria2

Node C has the required TLS name, ACME account configuration, and packet
obfuscation enabled.
Hysteria2 uses the same numeric direct port as Xray but listens over UDP/QUIC
instead of TCP.

```text
  Client
    |
    | Hysteria2 over UDP/QUIC
    v
  Node C Hysteria2
    |
    +--> DNS through local AdGuard Home
    |
    +--> Direct IPv4 outbound ---> Internet
```

Hysteria2 is direct-connect only. It has no HAProxy relay path.

## Relay state

HAProxy configuration can be rendered on every node with a target-specific TCP
listener for every peer. No node is selected as a public relay entry in this
sanitized state.

Consequences of this sanitized topology:

- generated subscriptions contain no `via entry` links
- direct Xray and direct Hysteria2 connections remain available

The latent peer mapping is a complete Xray relay mesh:

```text
  Node A  <==== TCP peer path ====>  Node B

  Node A  <==== TCP peer path ====>  Node C

  Node B  <==== TCP peer path ====>  Node C

  Public entry nodes selected: none
```

These listeners are configuration intent only.

## DNS

- HAProxy resolvers are configured for peer hostname resolution.
- Xray DNS servers are configured with IPv4 query strategy.
- Hysteria2 uses the primary Xray DNS server as its UDP resolver.
- The primary server-side path uses the node-local AdGuard Home service.
- Resolver addresses and upstream DNS identities are intentionally omitted.

## Statistics flow

```text
  Node A Xray stats --------+
  Node B Xray stats --------+----> Node A statistics service
  Node C Xray stats --------+               |
  Node C Hysteria2 stats ---+               v
                                   Statistics service
```

