# Xray Relay Mesh - VLESS/Reality over TCP and Hysteria2 over UDP/QUIC

`relay-mesh` is an inventory-driven deployment framework for a small
multi-node proxy mesh. Each node runs Xray VLESS/Reality, can optionally run
Hysteria2, and receives HAProxy listeners for reaching its peers. A separate
Caddy service publishes per-user subscriptions, optionally behind CloudFront.

## Traffic paths

| Subscription entry | Transport | Client destination | Server endpoint | Relayed |
|---|---|---|---|---|
| VLESS direct | TCP | `node.host:node.direct_port` | Xray VLESS/Reality | No |
| Hysteria2 direct | UDP/QUIC | `node.host:node.direct_port` | Hysteria2 | No |
| VLESS via entry node | TCP | `entry.host:(relay_port_base + target.id)` | HAProxy, then target Xray | Yes |

Xray and Hysteria2 use the same numeric `direct_port` on a host. They do not
conflict because Xray listens on TCP and Hysteria2 listens on UDP.

### Subscription delivery

The subscription service distributes connection definitions. It is not in the
proxy data path after the client selects an outbound.

```text
  +--------------------+
  | Client application |
  +----------+---------+
             |
             | HTTPS subscription request
             v
  +--------------------+
  | CloudFront         |
  +----------+---------+
             |
             | HTTPS origin request
             | with verification header
             v
  +--------------------+
  | Caddy origin       |
  +----------+---------+
             |
             v
  +--------------------+
  | User subscription  |
  +----------+---------+
             |
             +--> VLESS direct
             |
             +--> Hysteria2 direct
             |
             +--> VLESS via relay
```

Every visible node produces a direct VLESS entry. A node also produces a
Hysteria2 entry when its `protocols` contains `hysteria`. Relay entries are
generated only through nodes marked `is_relay_entry: true` and only for VLESS.

### Direct Xray request

```text
  +--------------------+
  | Client             |
  +----------+---------+
             |
             | VLESS + Reality over TCP
             | node.host:direct_port
             v
  +--------------------+
  | Host TCP port      |
  +----------+---------+
             |
             | Docker port mapping
             v
  +--------------------+
  | Xray               |
  | Authenticate user  |
  +----------+---------+
             |
             +---------------- DNS -------------------+
             |                                        |
             |                                        v
             |                             +--------------------+
             |                             | AdGuard Home       |
             |                             | 172.29.0.10:53     |
             |                             +----------+---------+
             |                                        |
             |                                        v
             |                             +--------------------+
             |                             | Public DNS         |
             |                             +--------------------+
             |
             | proxied traffic
             v
  +--------------------+
  | Xray routing rules |
  +----------+---------+
             |
             +--> Default route -------> Direct Internet
             |
             +--> Selected country route ---> WARP ---> Internet
             |
             +--> Prohibited traffic --> Block
```

Xray authenticates VLESS/Reality, resolves domains through the configured
`xray.dns` servers using IPv4, and applies its routing rules. Normal traffic is
sent directly, selected destinations use the WARP SOCKS outbound, and
private, IPv6, BitTorrent, or invalid Reality fallback traffic is blocked.

### Direct Hysteria2 request

```text
  +--------------------+
  | Client             |
  +----------+---------+
             |
             | Hysteria2 over UDP/QUIC
             | node.host:direct_port
             v
  +--------------------+
  | Host UDP port      |
  +----------+---------+
             |
             | Docker port mapping
             v
  +--------------------+
  | Hysteria2          |
  | TLS + userpass     |
  +----------+---------+
             |
             +---------------- DNS -------------------+
             |                                        |
             |                                        v
             |                             +--------------------+
             |                             | AdGuard Home       |
             |                             | 172.29.0.10:53     |
             |                             +----------+---------+
             |                                        |
             |                                        v
             |                             +--------------------+
             |                             | Public DNS         |
             |                             +--------------------+
             |
             | proxied traffic
             v
  +--------------------+
  | Direct outbound    |
  | IPv4 mode          |
  +----------+---------+
             |
             v
  +--------------------+
  | Internet service   |
  +--------------------+
```

Hysteria2 terminates TLS and authenticates the user's `email:uuid` password.
It resolves domain requests over UDP through `xray.dns.dns1`, normally the
local AdGuard Home service, and sends traffic through its direct IPv4 outbound.
It also publishes TCP port 80 for ACME HTTP-01 certificate challenges.

### Xray relay request

The relay port identifies the target node:

```text
relay port for target = relay_port_base + target.id
```

For example, when `relay_port_base` is `8442` and node B has ID `2`, node A's
HAProxy listener for node B is TCP port `8444`.

```text
  +--------------------+
  | Client             |
  | Selects node B     |
  | via relay node A   |
  +----------+---------+
             |
             | TCP entry.host:8444
             | Encrypted VLESS/Reality stream
             v
  +--------------------+
  | Node A             |
  | HAProxy :8444      |
  +----------+---------+
             |
             +---- DNS lookup ----> dns1 / dns2
             |                      resolve node-b.host
             |
             | TCP passthrough
             | node-b.host:direct_port
             v
  +--------------------+
  | Node B             |
  | Xray VLESS/Reality |
  | Authenticates user |
  +----------+---------+
             |
             | Direct or WARP route
             v
  +--------------------+
  | Internet service   |
  +--------------------+

  Response path:

  Internet service
        |
        v
  Node B Xray
        |
        v
  Node A HAProxy
        |
        v
  Client
```

HAProxy passes the encrypted TCP stream without terminating Reality, inspecting
SNI, or authenticating the user. The target Xray instance performs those
operations. Hysteria2 cannot use this path because the relay listeners are
TCP-only while Hysteria2 carries user traffic over UDP/QUIC.

## Documentation

- [Sanitized infrastructure state](docs/current_state.md) - representative
  topology using anonymous nodes and coarse geographic regions
- [Getting started](docs/getting-started.md) - dependencies, inventory setup,
  first deployment, and optional Hysteria2 configuration
- [Deployment operations](docs/operations.md) - CLI reference, deployment
  order, network reports, rollback, and node lifecycle
- [Repository boundaries](docs/repository-layout.md) - source tree ownership
  and component responsibilities
- [Managed deployment transaction](docs/deployment-transaction.md) - staging,
  validation, promotion, rollback, and persistent-state boundaries
- [Example inventory reference](configs/examples/README.md) - inventory fields
  and invariants
