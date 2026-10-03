(function () {
  "use strict";

  const STATS_BASE = "/stats";
  const MAX_RANGE = 7776000;
  const SLOW_MS = 150;
  const LOW_AVAILABILITY = 0.99;
  const ranges = {
    3600: { label: "1h", bucket: 60 },
    86400: { label: "24h", bucket: 900 },
    604800: { label: "7d", bucket: 3600 },
    2592000: { label: "30d", bucket: 14400 },
    7776000: { label: "90d", bucket: 43200 }
  };
  const state = {
    users: [], rawUsers: [], health: [], nodeStats: {}, traffic: null,
    refreshMs: 15000, rangeSeconds: 3600, sortKey: "period_total", sortDirection: -1,
    polls: null, events: [], open: null, drawerToken: 0, drawerCache: {}
  };
  const $ = (id) => document.getElementById(id);

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[char]));
  }

  function bytes(value) {
    let number = Number(value) || 0;
    const units = ["B", "KB", "MB", "GB", "TB"];
    let unit = 0;
    while (number >= 1024 && unit < units.length - 1) { number /= 1024; unit += 1; }
    return `${number.toFixed(unit ? 2 : 0)} ${units[unit]}`;
  }

  function rate(value) { return `${bytes(value)}/s`; }

  function date(value) {
    if (!value) return "-";
    return new Date(Number(value) * 1000).toLocaleString([], { dateStyle: "short", timeStyle: "short" });
  }

  function relativeDate(value) {
    if (!value) return "never";
    const seconds = Math.max(0, Math.round(Date.now() / 1000 - Number(value)));
    if (seconds < 10) return "just now";
    if (seconds < 60) return `${seconds}s ago`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
    if (seconds < 604800) return `${Math.floor(seconds / 86400)}d ago`;
    return date(value);
  }

  const presenceClass = { online: "ok", active: "warn", offline: "dim", unknown: "dim" };
  const presenceText = { online: "● ONLINE", active: "◐ TRAFFIC", offline: "○ OFFLINE", unknown: "? NO DATA" };

  function presenceBadge(presence) {
    return `<span class="${presenceClass[presence] || "dim"}">${presenceText[presence] || presenceText.unknown}</span>`;
  }

  function duration(seconds) {
    const value = Math.max(0, Math.round(Number(seconds) || 0));
    if (value < 60) return `${value}s`;
    if (value < 3600) return `${Math.floor(value / 60)}m`;
    if (value < 86400) return `${Math.floor(value / 3600)}h ${Math.floor(value % 3600 / 60)}m`;
    return `${Math.floor(value / 86400)}d ${Math.floor(value % 86400 / 3600)}h`;
  }

  function ticksHtml(series) {
    if (!series || !series.length) return "";
    return `<div class="ticks">${series.map((bucket) => {
      const cls = !bucket.polls ? "n" : (bucket.failed === 0 ? "" : (bucket.failed === bucket.polls ? "b" : "w"));
      const title = `${date(bucket.ts)} - ${bucket.polls ? `${bucket.polls - bucket.failed}/${bucket.polls} polls ok` : "no polls"}`;
      return `<i class="${cls}" title="${escapeHtml(title)}"></i>`;
    }).join("")}</div>`;
  }

  function latencyHtml(series, height) {
    const points = (series || []).filter((bucket) => bucket.average_latency_ms !== null);
    if (!points.length) return `<div class="empty">No successful polls in this range.</div>`;
    const max = Math.max(1, ...points.map((bucket) => bucket.max_latency_ms || 0)) * 1.1;
    const span = Math.max(1, series.length - 1);
    const x = (index) => index * 1000 / span;
    const y = (value) => height - 4 - (Number(value) / max) * (height - 10);
    const line = (key, color, dash) => {
      const segments = [];
      let current = [];
      series.forEach((bucket, index) => {
        if (bucket[key] === null) {
          if (current.length) segments.push(current);
          current = [];
        } else current.push(`${x(index)},${y(bucket[key])}`);
      });
      if (current.length) segments.push(current);
      return segments.map((segment) => `<polyline points="${segment.join(" ")}" fill="none" stroke="${color}" stroke-width="1.5"${dash ? ' stroke-dasharray="4 4"' : ""} vector-effect="non-scaling-stroke"/>`).join("");
    };
    const avg = points.reduce((sum, bucket) => sum + bucket.average_latency_ms, 0) / points.length;
    return `<svg class="chart" viewBox="0 0 1000 ${height}" preserveAspectRatio="none" style="height:${height}px" role="img" aria-label="Latency over time">${line("max_latency_ms", "var(--dim)", true)}${line("average_latency_ms", "var(--ok)", false)}</svg>
      <div class="chart-axis"><span>${escapeHtml(date(series[0].ts))}</span><span>avg ${avg.toFixed(0)} ms · <span class="dim">- - max ${Math.round(max / 1.1)} ms</span></span><span>${escapeHtml(date(series[series.length - 1].ts))}</span></div>`;
  }

  // Pair node_down / node_up events (newest first in) into incidents, newest first out.
  function incidents(events) {
    const open = new Map();
    const result = [];
    events.slice().reverse().forEach((event) => {
      if (event.kind === "node_down") {
        if (!open.has(event.protocol)) {
          const incident = { protocol: event.protocol, start: event.ts, end: null, text: event.text };
          open.set(event.protocol, incident);
          result.push(incident);
        }
      } else if (event.kind === "node_up" && open.has(event.protocol)) {
        open.get(event.protocol).end = event.ts;
        open.delete(event.protocol);
      }
    });
    return result.reverse();
  }

  function showError(message) {
    $("access-error").classList.remove("hidden");
    $("access-error-text").textContent = message;
    $("banner").className = "banner bad";
    $("banner-text").textContent = "STATS UNAVAILABLE";
  }

  async function api(path) {
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 12000);
    try {
      const response = await fetch(`${STATS_BASE}${path}`, { headers: { Accept: "application/json" }, cache: "no-store", signal: controller.signal });
      if (!response.ok) throw new Error(response.status === 401 ? "Authentication failed" : `Request failed (${response.status})`);
      return response.json();
    } finally {
      window.clearTimeout(timeout);
    }
  }

  function aggregateUsers(users) {
    const grouped = new Map();
    users.forEach((item) => {
      const current = grouped.get(item.user) || {
        user: item.user, nodes: [], protocols: [], total: 0, uplink: 0, downlink: 0,
        period_total: 0, period_uplink: 0, period_downlink: 0,
        online: false, online_nodes: [], active: false, available: false,
        last_seen: 0, last_seen_node: "", last_online: 0, last_online_node: "", last_node: ""
      };
      current.nodes.push(item.node);
      current.protocols.push(item.protocol);
      current.total += Number(item.total || 0);
      current.uplink += Number(item.uplink || 0);
      current.downlink += Number(item.downlink || 0);
      current.period_total += Number(item.period_total || 0);
      current.period_uplink += Number(item.period_uplink || 0);
      current.period_downlink += Number(item.period_downlink || 0);
      current.online = current.online || Boolean(item.online);
      if (item.online) current.online_nodes.push(item.node);
      current.active = current.active || Boolean(item.active);
      current.available = current.available || Boolean(item.available);
      const itemLastSeen = Number(item.last_seen || 0);
      if (itemLastSeen > current.last_seen || (itemLastSeen === current.last_seen && (!current.last_seen_node || item.node < current.last_seen_node))) {
        current.last_seen_node = item.node;
      }
      current.last_seen = Math.max(current.last_seen, itemLastSeen);
      const itemLastOnline = Number(item.last_online || 0);
      if (itemLastOnline > current.last_online || (itemLastOnline === current.last_online && itemLastOnline && (!current.last_online_node || item.node < current.last_online_node))) {
        current.last_online_node = item.node;
      }
      current.last_online = Math.max(current.last_online, itemLastOnline);
      grouped.set(item.user, current);
    });
    return [...grouped.values()].map((item) => {
      item.nodes = [...new Set(item.nodes)].sort();
      item.protocols = [...new Set(item.protocols)].sort();
      item.online_nodes = [...new Set(item.online_nodes)].sort();
      item.last_node = item.last_online_node || item.last_seen_node;
      item.presence = item.online ? "online" : (item.active ? "active" : (item.available ? "offline" : "unknown"));
      return item;
    });
  }

  function sumSeries(series, key) {
    return (series || []).reduce((sum, sample) => sum + Number(sample[key] || 0), 0);
  }

  // Unicode sparkline from a bucketed series, downsampled to `width` cells.
  function sparkline(series, width = 14) {
    const samples = (series || []).slice(0, -1);
    if (!samples.length) return "";
    const size = Math.max(1, Math.ceil(samples.length / width));
    const cells = [];
    for (let index = 0; index < samples.length; index += size) {
      const chunk = samples.slice(index, index + size);
      cells.push(chunk.every((sample) => sample.total === null) ? null : sumSeries(chunk, "total"));
    }
    const max = Math.max(1, ...cells.map((value) => value || 0));
    return cells.map((value) => value === null ? "·" : "▁▂▃▄▅▆▇█"[Math.min(7, Math.floor(value / max * 7.99))]).join("");
  }

  function chartHtml(series, height) {
    const points = (series || []).filter((sample) => sample.total !== null);
    if (!points.length) return `<div class="empty">No traffic data for this range.</div>`;
    const max = Math.max(1, ...points.flatMap((sample) => [sample.uplink, sample.downlink])) * 1.1;
    const span = Math.max(1, series.length - 1);
    const x = (index) => index * 1000 / span;
    const y = (value) => height - 4 - (Number(value) / max) * (height - 10);
    const segments = (key) => {
      const result = [];
      let current = [];
      series.forEach((sample, index) => {
        if (sample[key] === null) {
          if (current.length) result.push(current);
          current = [];
        } else current.push([x(index), y(sample[key])]);
      });
      if (current.length) result.push(current);
      return result;
    };
    const grid = [0, 1, 2].map((step) => {
      const lineY = 5 + step * (height - 10) / 2;
      return `<line x1="0" x2="1000" y1="${lineY}" y2="${lineY}" stroke="var(--line)" vector-effect="non-scaling-stroke"/>`;
    }).join("");
    const area = segments("downlink").map((segment) =>
      `<polygon points="${segment[0][0]},${height - 4} ${segment.map((p) => p.join(",")).join(" ")} ${segment[segment.length - 1][0]},${height - 4}" fill="var(--dn)" opacity=".13"/>`).join("");
    const line = (key, color) => segments(key).map((segment) =>
      `<polyline points="${segment.map((p) => p.join(",")).join(" ")}" fill="none" stroke="${color}" stroke-width="1.5" vector-effect="non-scaling-stroke"/>`).join("");
    return `<svg class="chart" viewBox="0 0 1000 ${height}" preserveAspectRatio="none" style="height:${height}px" role="img" aria-label="Upload and download over time">${grid}${area}${line("downlink", "var(--dn)")}${line("uplink", "var(--up)")}</svg>
      <div class="chart-axis"><span>${escapeHtml(date(series[0].ts))}</span><span><i class="up">━</i> up &nbsp;<i class="dn">━</i> down &nbsp;max ${escapeHtml(bytes(max / 1.1))} per bucket</span><span>${escapeHtml(date(series[series.length - 1].ts))}</span></div>`;
  }

  function nodeAnomaly(series) {
    const complete = (series || []).slice(0, -1);
    const current = complete.at(-1);
    const prior = complete.slice(0, -1).filter((sample) => sample.total !== null);
    if (!current || current.total === null || prior.length < 6) return "";
    const mean = sumSeries(prior, "total") / prior.length;
    if (mean <= 0) return "";
    if (current.total > mean * 3) return `${(current.total / mean).toFixed(1)}x typical`;
    if (current.total < mean / 5) return `${Math.round(current.total / mean * 100)}% of typical`;
    return "";
  }

  function buildAlerts() {
    const alerts = [];
    state.health.filter((row) => !row.ok).forEach((row) => alerts.push(["bad", `${row.node}/${row.protocol} DOWN - ${row.error || "no detail"}`]));
    state.health.filter((row) => row.ok && Number(row.latency_ms) > SLOW_MS).forEach((row) => alerts.push(["warn", `${row.node}/${row.protocol} latency ${row.latency_ms} ms`]));
    Object.entries(state.nodeStats).forEach(([node, stats]) => {
      if (!stats) return;
      if (stats.availability !== null && stats.availability < LOW_AVAILABILITY) alerts.push(["warn", `${node} availability ${(stats.availability * 100).toFixed(1)}%`]);
      const anomaly = nodeAnomaly(stats.traffic.series);
      if (anomaly) alerts.push(["warn", `${node} traffic ${anomaly}`]);
    });
    state.users.filter((user) => user.presence === "active").forEach((user) => alerts.push(["warn", `${user.user} moving traffic but not counted online`]));
    state.users.filter((user) => user.presence === "unknown").forEach((user) => alerts.push(["dim", `${user.user} no data - node unavailable`]));
    return alerts;
  }

  function nodeTraffic(node) {
    return state.rawUsers.filter((row) => row.node === node).reduce((sum, row) => sum + Number(row.period_total || 0), 0);
  }

  function renderBanner() {
    const down = state.health.filter((row) => !row.ok).length;
    const slow = state.health.filter((row) => row.ok && Number(row.latency_ms) > SLOW_MS).length;
    const oldest = state.health.length ? Math.min(...state.health.map((row) => Number(row.ts) || 0)) : 0;
    $("banner").className = `banner${down || slow ? "" : " good"}${down ? " bad" : ""}`;
    $("banner-text").innerHTML = `<span class="${down ? "blink" : ""}">●</span> ${down ? `${down} DOWN` : "ALL NODES UP"}${slow ? ` · ${slow} SLOW` : ""}`;
    $("banner-meta").textContent = `oldest poll ${relativeDate(oldest)} · updated ${new Date().toLocaleTimeString()}`;
  }

  function renderKpis() {
    const series = state.traffic.current;
    const total = state.users.reduce((sum, user) => sum + user.period_total, 0);
    const upload = state.users.reduce((sum, user) => sum + user.period_uplink, 0);
    const download = state.users.reduce((sum, user) => sum + user.period_downlink, 0);
    const bucket = state.traffic.bucket;
    const complete = series.slice(0, -1);
    const last = complete.at(-1);
    const peak = Math.max(0, ...complete.map((sample) => Number(sample.total || 0)));
    const online = state.users.filter((user) => user.online).length;
    const stats = Object.values(state.nodeStats).filter(Boolean);
    const polls = stats.reduce((sum, item) => sum + item.polls, 0);
    const successful = stats.reduce((sum, item) => sum + item.successful_polls, 0);
    const okRows = state.health.filter((row) => row.ok);
    const latencies = okRows.map((row) => Number(row.latency_ms) || 0);
    const previous = state.traffic.previous;
    const change = previous ? (previous > 0 ? ((series.reduce((sum, sample) => sum + Number(sample.total || 0), 0) - previous) / previous * 100) : null) : null;
    const cards = [
      ["TRANSFERRED", bytes(total), `<span class="up">↑ ${bytes(upload)}</span> <span class="dn">↓ ${bytes(download)}</span>`],
      [`VS PREVIOUS ${ranges[state.rangeSeconds].label.toUpperCase()}`, change === null ? "-" : `<span class="${change >= 0 ? "ok" : "warn"}">${change >= 0 ? "▲" : "▼"} ${Math.abs(change).toFixed(1)}%</span>`, previous ? `previous ${bytes(previous)}` : "not available for this range"],
      ["THROUGHPUT", last && last.total !== null ? rate(last.total / bucket) : "-", `peak ${rate(peak / bucket)}`],
      ["ONLINE", `${online}<span class="dim"> / ${state.users.length}</span>`, `${state.users.filter((user) => user.presence === "active").length} traffic only · ${state.users.filter((user) => user.presence === "unknown").length} no data`],
      ["AVAILABILITY", polls ? `${(successful / polls * 100).toFixed(2)}%` : "-", `${polls} polls`],
      ["AVG LATENCY", latencies.length ? `${Math.round(latencies.reduce((a, b) => a + b, 0) / latencies.length)} ms` : "-", `worst ${Math.max(0, ...latencies)} ms`]
    ];
    $("kpis").innerHTML = cards.map(([label, value, note]) => `<section><h2>${label}</h2><div class="big">${value}</div><div class="note">${note}</div></section>`).join("");
  }

  function renderNodes() {
    const maxBytes = Math.max(1, ...state.health.map((row) => nodeTraffic(row.node)));
    const rows = state.health.slice().sort((a, b) => a.node.localeCompare(b.node) || a.protocol.localeCompare(b.protocol));
    $("nodes").innerHTML = rows.map((row) => {
      const stats = state.nodeStats[row.node];
      const online = new Set(state.rawUsers.filter((item) => item.node === row.node && item.protocol === row.protocol && item.online).map((item) => item.user)).size;
      const slow = row.ok && Number(row.latency_ms) > SLOW_MS;
      const stateCell = !row.ok ? `<span class="bad blink">● DOWN</span>` : (slow ? `<span class="warn">● SLOW</span>` : `<span class="ok">● OK</span>`);
      const availability = stats && stats.availability !== null ? stats.availability * 100 : null;
      const availabilityClass = availability === null ? "dim" : (availability < 95 ? "bad" : (availability < LOW_AVAILABILITY * 100 ? "warn" : "ok"));
      const stale = Date.now() / 1000 - Number(row.ts) > 120;
      const traffic = nodeTraffic(row.node);
      const cells = Math.round(traffic / maxBytes * 10);
      return `<tr data-node="${escapeHtml(row.node)}"><td class="m-title" data-label="Node">${escapeHtml(row.node)}</td><td class="dim" data-label="Protocol">${escapeHtml(row.protocol)}</td><td data-label="State">${stateCell}</td>
        <td class="r ${slow ? "warn" : ""}" data-label="Latency">${row.ok ? `${Number(row.latency_ms) || 0} ms` : "--"}</td>
        <td class="r dim m-hide" data-label="Avg latency">${stats && stats.average_latency_ms !== null ? `${stats.average_latency_ms} ms` : "-"}</td>
        <td class="r ${availabilityClass}" data-label="Availability">${availability === null ? "-" : `${availability.toFixed(2)}%`}</td>
        <td class="r dim m-hide" data-label="Polls">${stats ? `${stats.successful_polls}/${stats.polls}` : "-"}</td>
        <td class="${stale ? "bad" : "dim"}" data-label="Last poll">${relativeDate(row.ts)}</td><td class="r" data-label="Online">${online}</td><td class="r" data-label="Traffic">${bytes(traffic)}</td>
        <td class="m-hide" data-label="Load"><span class="spark up">${escapeHtml(stats ? sparkline(stats.traffic.series) : "")}</span> <span class="up">${"█".repeat(cells)}</span><span class="dim">${"░".repeat(10 - cells)}</span></td></tr>
        ${row.ok ? "" : `<tr><td colspan="11" class="err">↳ ${escapeHtml(row.error || "no detail")}</td></tr>`}`;
    }).join("") || `<tr><td colspan="11" class="dim">No node data yet.</td></tr>`;
  }

  function describeEvent(event) {
    if (event.kind === "node_down") return ["bad", `${event.node}/${event.protocol}`, `went down${event.text ? ` - ${event.text}` : ""}`];
    if (event.kind === "node_up") return ["ok", `${event.node}/${event.protocol}`, "recovered"];
    if (event.kind === "user_online") return ["ok", event.user, `online on ${event.node}`];
    return ["dim", event.user, `went offline (${event.node})`];
  }

  function renderSide() {
    const alerts = buildAlerts();
    $("alert-count").innerHTML = `<span class="${alerts.some((item) => item[0] === "bad") ? "bad" : (alerts.length ? "warn" : "ok")}">${alerts.length}</span>`;
    $("alerts").innerHTML = alerts.map(([cls, text]) => `<div class="alert ${cls}">${escapeHtml(text)}</div>`).join("") || `<div class="ok">nothing to report</div>`;
    $("events").innerHTML = state.events.map((event) => {
      const [cls, who, text] = describeEvent(event);
      return `<div><span class="dim" title="${escapeHtml(date(event.ts))}">${escapeHtml(relativeDate(event.ts))}</span> <span class="${cls}">${escapeHtml(who)}</span> ${escapeHtml(text)}</div>`;
    }).join("") || `<div class="dim">no changes recorded yet</div>`;
    const polls = state.polls ? state.polls.nodes : {};
    $("uptime").innerHTML = Object.keys(polls).sort().map((node) => {
      const stats = state.nodeStats[node];
      return `<div class="row"><span class="link" data-node="${escapeHtml(node)}">${escapeHtml(node)}</span><span class="dim">${stats && stats.availability !== null ? `${(stats.availability * 100).toFixed(2)}%` : "-"}</span></div>${ticksHtml(polls[node])}`;
    }).join("") || `<div class="empty">No poll data.</div>`;
    const totals = new Map();
    state.rawUsers.forEach((row) => totals.set(row.node, (totals.get(row.node) || 0) + Number(row.period_total || 0)));
    const sorted = [...totals.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
    const grand = sorted.reduce((sum, item) => sum + item[1], 0);
    $("by-node").innerHTML = sorted.map(([node, value]) => `<div class="row"><span class="link" data-node="${escapeHtml(node)}">${escapeHtml(node)} <span class="up">${"█".repeat(grand ? Math.round(value / grand * 24) : 0)}</span></span><span>${bytes(value)} <span class="dim">${grand ? (value / grand * 100).toFixed(0) : 0}%</span></span></div>`).join("") || `<div class="empty">No traffic.</div>`;
  }

  function renderTraffic() {
    const series = state.traffic.current;
    $("mesh-chart").innerHTML = chartHtml(series, 150);
    const measured = series.slice(0, -1).filter((sample) => sample.coverage !== null);
    const coverage = measured.length ? measured.reduce((sum, sample) => sum + Number(sample.coverage || 0), 0) / measured.length : null;
    const ratio = state.users.reduce((sum, user) => sum + user.period_uplink, 0);
    const down = state.users.reduce((sum, user) => sum + user.period_downlink, 0);
    $("traffic-meta").textContent = `${coverage === null ? "no coverage data" : `${(coverage * 100).toFixed(1)}% coverage`}${ratio ? ` · up:down 1:${(down / ratio).toFixed(1)}` : ""}`;
  }

  function renderUsers() {
    const filter = ($("user-filter").value || "").toLowerCase().trim();
    const status = $("status-filter").value;
    const periodTotal = state.users.reduce((sum, user) => sum + user.period_total, 0);
    const visible = state.users.filter((user) =>
      (!filter || `${user.user} ${user.nodes.join(" ")}`.toLowerCase().includes(filter)) && (status === "all" || status === user.presence)
    ).sort((left, right) => {
      const comparison = state.sortKey === "user"
        ? left.user.localeCompare(right.user)
        : Number(left[state.sortKey] || 0) - Number(right[state.sortKey] || 0);
      return comparison * state.sortDirection || left.user.localeCompare(right.user);
    });
    $("users").innerHTML = visible.map((user) => {
      const share = periodTotal ? user.period_total / periodTotal * 100 : 0;
      return `<tr data-user="${escapeHtml(user.user)}"><td class="m-title" data-label="User">${escapeHtml(user.user)}</td><td data-label="Status">${presenceBadge(user.presence)}</td>
        <td class="dim wrap m-hide" data-label="Nodes">${user.nodes.map(escapeHtml).join(", ")}</td>
        <td data-label="Last node">${user.last_node ? escapeHtml(user.last_node) : '<span class="dim">-</span>'}</td>
        <td class="${user.presence === "online" ? "ok" : "dim"}" data-label="Last online">${user.presence === "online" ? "now" : relativeDate(user.last_online)}</td>
        <td class="r up m-hide" data-label="Up">${bytes(user.period_uplink)}</td><td class="r dn m-hide" data-label="Down">${bytes(user.period_downlink)}</td><td class="r" data-label="Range">${bytes(user.period_total)}</td>
        <td class="m-hide" data-label="Share"><span class="up">${"█".repeat(Math.round(share / 10))}</span> <span class="dim">${share.toFixed(1)}%</span></td><td class="r dim m-hide" data-label="Total">${bytes(user.total)}</td></tr>`;
    }).join("") || `<tr><td colspan="10" class="dim">No matching users.</td></tr>`;
  }

  function kv(pairs) {
    return `<div class="kv">${pairs.map(([key, value]) => `<div><span class="dim">${key}</span><span>${value}</span></div>`).join("")}</div>`;
  }

  function setDrawer(html) {
    const drawer = $("drawer");
    const scroll = drawer.scrollTop;
    drawer.innerHTML = html;
    drawer.scrollTop = scroll;
    drawer.classList.add("open");
    $("shade").classList.add("open");
  }

  function closeDrawer() {
    state.open = null;
    $("drawer").classList.remove("open");
    $("shade").classList.remove("open");
    if (window.location.pathname !== `${STATS_BASE}/xray`) window.history.replaceState(null, "", `${STATS_BASE}/xray`);
  }

  function drawerHeader(title) {
    return `<h1><span>${escapeHtml(title)}</span><button id="drawer-close" type="button">esc ✕</button></h1>`;
  }

  async function renderUserDrawer(name, refreshOnly) {
    const user = state.users.find((item) => item.user === name);
    if (!user) { closeDrawer(); return; }
    const rows = state.rawUsers.filter((row) => row.user === name).sort((a, b) => a.node.localeCompare(b.node) || a.protocol.localeCompare(b.protocol));
    const periodTotal = state.users.reduce((sum, item) => sum + item.period_total, 0);
    const token = ++state.drawerToken;
    const render = (chart, sessions) => setDrawer(`${drawerHeader(`USER ${user.user}`)}
      <div>${presenceBadge(user.presence)}${user.online_nodes.length ? ` <span class="dim">on ${user.online_nodes.map(escapeHtml).join(", ")}</span>` : ""}</div>
      ${kv([
        ["Last node", user.last_node ? `<span class="link" data-node="${escapeHtml(user.last_node)}">${escapeHtml(user.last_node)}</span>` : "-"],
        ["Last online", user.presence === "online" ? "now" : escapeHtml(relativeDate(user.last_online))],
        [`Range (${ranges[state.rangeSeconds].label})`, bytes(user.period_total)], ["Total (all time)", bytes(user.total)],
        ["↑ Upload", `<span class="up">${bytes(user.period_uplink)}</span>`], ["↓ Download", `<span class="dn">${bytes(user.period_downlink)}</span>`],
        ["Share of mesh", periodTotal ? `${(user.period_total / periodTotal * 100).toFixed(1)}%` : "-"], ["Protocols", user.protocols.map(escapeHtml).join(", ")]
      ])}
      <section><h2>TRAFFIC</h2>${chart}</section>
      <section><h2>SESSIONS</h2>${sessions}</section>
      <section><h2>PER NODE</h2><div class="scroll"><table><thead><tr><th>NODE</th><th>PROTO</th><th>PRESENCE</th><th class="r">RANGE</th><th class="r">TOTAL</th><th>LAST SEEN</th></tr></thead><tbody>
      ${rows.map((row) => `<tr><td><span class="link" data-node="${escapeHtml(row.node)}">${escapeHtml(row.node)}</span></td><td class="dim">${escapeHtml(row.protocol)}</td><td>${presenceBadge(row.presence)}</td><td class="r">${bytes(row.period_total)}</td><td class="r dim">${bytes(row.total)}</td><td class="dim">${escapeHtml(relativeDate(row.last_seen))}</td></tr>`).join("")}
      </tbody></table></div></section>`);
    const loading = `<div class="empty">Loading...</div>`;
    const cached = state.drawerCache[`user:${name}`] || [loading, loading];
    render(...cached);
    if (refreshOnly && state.drawerCache[`user:${name}`]) return;
    try {
      const query = `seconds=${state.rangeSeconds}`;
      const [analytics, sessions] = await Promise.all([
        api(`/api/users/${encodeURIComponent(name)}/analytics?${query}&bucket=${ranges[state.rangeSeconds].bucket}`),
        api(`/api/users/${encodeURIComponent(name)}/sessions?${query}`)
      ]);
      state.drawerCache[`user:${name}`] = [chartHtml(analytics.traffic.series, 120), sessionsHtml(sessions)];
      if (token === state.drawerToken && state.open?.user === name) render(...state.drawerCache[`user:${name}`]);
    } catch (error) {
      if (token === state.drawerToken && state.open?.user === name) render(`<div class="bad">${escapeHtml(error.message)}</div>`, "");
    }
  }

  function sessionsHtml(data) {
    if (!data.count) return `<div class="empty">No sessions in this range.</div>`;
    return `${kv([
      ["First seen", escapeHtml(date(data.first_seen))], ["Sessions", data.count],
      ["Median", duration(data.median_seconds)], ["Longest", duration(data.longest_seconds)],
      ["Active time", duration(data.total_seconds)]
    ])}<div class="scroll"><table><thead><tr><th>START</th><th class="r">LENGTH</th><th class="r">TRAFFIC</th></tr></thead><tbody>
      ${data.sessions.slice(0, 10).map((item) => `<tr><td>${escapeHtml(date(item.start))}</td><td class="r">${duration(item.duration_seconds)}</td><td class="r">${bytes(item.bytes)}</td></tr>`).join("")}</tbody></table></div>`;
  }

  async function renderNodeDrawer(name, refreshOnly) {
    const health = state.health.filter((row) => row.node === name);
    if (!health.length) { closeDrawer(); return; }
    const token = ++state.drawerToken;
    const key = `node:${name}`;
    const render = (events) => renderNodeDrawerBody(name, health, events);
    render(state.drawerCache[key]);
    if (refreshOnly && state.drawerCache[key]) return;
    try {
      state.drawerCache[key] = await api(`/api/events?node=${encodeURIComponent(name)}&limit=200`);
      if (token === state.drawerToken && state.open?.node === name) render(state.drawerCache[key]);
    } catch (error) { /* the drawer keeps the data it already has */ }
  }

  function renderNodeDrawerBody(name, health, events) {
    const stats = state.nodeStats[name];
    const rows = state.rawUsers.filter((row) => row.node === name).sort((a, b) => Number(b.period_total || 0) - Number(a.period_total || 0) || a.user.localeCompare(b.user));
    const total = Object.keys(state.nodeStats).reduce((sum, node) => sum + nodeTraffic(node), 0);
    const anomaly = stats ? nodeAnomaly(stats.traffic.series) : "";
    const nodePolls = state.polls ? state.polls.nodes[name] : [];
    setDrawer(`${drawerHeader(`NODE ${name}`)}
      ${health.map((row) => `<div>${row.ok ? (Number(row.latency_ms) > SLOW_MS ? '<span class="warn">● SLOW</span>' : '<span class="ok">● OK</span>') : '<span class="bad blink">● DOWN</span>'} <span class="dim">${escapeHtml(row.protocol)}</span> ${row.ok ? `${Number(row.latency_ms) || 0} ms` : ""}${row.ok ? "" : `<div class="err">${escapeHtml(row.error || "no detail")}</div>`}</div>`).join("")}
      ${kv([
        ["Last poll", escapeHtml(relativeDate(Math.max(...health.map((row) => Number(row.ts) || 0))))],
        [`Availability ${ranges[state.rangeSeconds].label}`, stats && stats.availability !== null ? `${(stats.availability * 100).toFixed(2)}%` : "-"],
        ["Avg latency", stats && stats.average_latency_ms !== null ? `${stats.average_latency_ms} ms` : "-"], ["Polls ok/total", stats ? `${stats.successful_polls}/${stats.polls}` : "-"],
        ["Active users", stats ? stats.active_users : "-"], ["Online now", new Set(rows.filter((row) => row.online).map((row) => row.user)).size],
        [`Traffic ${ranges[state.rangeSeconds].label}`, bytes(nodeTraffic(name))], ["Share of mesh", total ? `${(nodeTraffic(name) / total * 100).toFixed(0)}%` : "-"],
        ["Traffic vs typical", anomaly ? `<span class="warn">${anomaly}</span>` : "normal"]
      ])}
      <section><h2>TRAFFIC</h2>${stats ? chartHtml(stats.traffic.series, 120) : '<div class="empty">No analytics.</div>'}</section>
      <section><h2>LATENCY</h2>${latencyHtml(nodePolls, 100)}</section>
      <section><h2>UPTIME</h2>${ticksHtml(nodePolls)}</section>
      <section><h2>INCIDENTS</h2>${incidentsHtml(events)}</section>
      <section><h2>USERS ON NODE</h2><div class="scroll"><table><thead><tr><th>USER</th><th>PROTO</th><th>PRESENCE</th><th class="r">RANGE</th><th>LAST ONLINE</th></tr></thead><tbody>
      ${rows.map((row) => `<tr><td><span class="link" data-user="${escapeHtml(row.user)}">${escapeHtml(row.user)}</span></td><td class="dim">${escapeHtml(row.protocol)}</td><td>${presenceBadge(row.presence)}</td><td class="r">${bytes(row.period_total)}</td><td class="dim">${escapeHtml(relativeDate(row.last_online))}</td></tr>`).join("") || '<tr><td colspan="5" class="dim">No users on this node.</td></tr>'}
      </tbody></table></div></section>`);
  }

  function incidentsHtml(events) {
    if (!events) return `<div class="empty">Loading...</div>`;
    const list = incidents(events.filter((event) => event.kind === "node_down" || event.kind === "node_up"));
    if (!list.length) return `<div class="ok">no incidents recorded</div>`;
    const closed = list.filter((item) => item.end !== null);
    const mttr = closed.length ? closed.reduce((sum, item) => sum + item.end - item.start, 0) / closed.length : null;
    return `<div class="note">${list.length} incident${list.length === 1 ? "" : "s"}${mttr === null ? "" : ` · mean time to recover ${duration(mttr)}`}</div><div class="scroll"><table><thead><tr><th>START</th><th>PROTO</th><th class="r">LENGTH</th><th>CAUSE</th></tr></thead><tbody>
      ${list.slice(0, 10).map((item) => `<tr><td>${escapeHtml(date(item.start))}</td><td class="dim">${escapeHtml(item.protocol)}</td><td class="r ${item.end === null ? "bad blink" : ""}">${item.end === null ? "ongoing" : duration(item.end - item.start)}</td><td class="dim">${escapeHtml(item.text || "-")}</td></tr>`).join("")}</tbody></table></div>`;
  }

  function openDrawer(kind, name, refreshOnly = false) {
    state.open = { [kind]: name };
    if (!refreshOnly) window.history.replaceState(null, "", `${STATS_BASE}/${kind === "user" ? "users" : "nodes"}/${encodeURIComponent(name)}`);
    if (kind === "user") void renderUserDrawer(name, refreshOnly);
    else void renderNodeDrawer(name, refreshOnly);
  }

  async function load() {
    const requestedRange = state.rangeSeconds;
    const bucket = ranges[requestedRange].bucket;
    const doubled = requestedRange * 2 <= MAX_RANGE;
    try {
      const pollBucket = Math.max(60, Math.ceil(requestedRange / 48 / 60) * 60);
      const data = await api(`/api/dashboard?seconds=${requestedRange}&bucket=${bucket}&traffic_seconds=${doubled ? requestedRange * 2 : requestedRange}&poll_bucket=${pollBucket}`);
      const traffic = data.traffic;
      const summary = data;
      if (requestedRange !== state.rangeSeconds) return;
      const series = traffic.series || [];
      const cutoff = series.length ? series[series.length - 1].ts - requestedRange : 0;
      state.traffic = {
        bucket: traffic.bucket_seconds,
        current: doubled ? series.filter((sample) => sample.ts >= cutoff) : series,
        previous: doubled ? sumSeries(series.filter((sample) => sample.ts < cutoff), "total") : null
      };
      state.health = summary.nodes || [];
      state.rawUsers = summary.users || [];
      state.users = aggregateUsers(state.rawUsers);
      state.nodeStats = data.analytics || {};
      state.polls = data.polls;
      state.events = data.events || [];
      $("access-error").classList.add("hidden");
      renderBanner();
      renderKpis();
      renderNodes();
      renderSide();
      renderTraffic();
      renderUsers();
      if (state.open?.user) openDrawer("user", state.open.user, true);
      else if (state.open?.node) openDrawer("node", state.open.node, true);
    } catch (error) { showError(error.message); }
  }

  let timer = 0;
  function reload() {
    window.clearTimeout(timer);
    void load().finally(() => { timer = window.setTimeout(reload, state.refreshMs); });
  }

  function setRange(seconds) {
    state.rangeSeconds = Number(seconds);
    state.drawerCache = {};
    document.querySelectorAll("#ranges button").forEach((button) => button.classList.toggle("on", Number(button.dataset.range) === state.rangeSeconds));
    reload();
  }

  function setTheme(amber) {
    document.body.classList.toggle("amber", amber);
    $("theme-green").classList.toggle("on", !amber);
    $("theme-amber").classList.toggle("on", amber);
    try { window.localStorage.setItem("stats-theme", amber ? "amber" : "green"); } catch (error) { /* storage unavailable */ }
  }

  function setCrt(enabled) {
    document.body.classList.toggle("crt", enabled);
    $("theme-crt").classList.toggle("on", enabled);
    try { window.localStorage.setItem("stats-crt", enabled ? "on" : "off"); } catch (error) { /* storage unavailable */ }
  }

  function init() {
    $("ranges").innerHTML = Object.entries(ranges).map(([seconds, item]) => `<button type="button" data-range="${seconds}">${item.label}</button>`).join("");
    $("ranges").addEventListener("click", (event) => { if (event.target.dataset.range) setRange(event.target.dataset.range); });
    let amber = false;
    let crt = true;
    try {
      amber = window.localStorage.getItem("stats-theme") === "amber";
      crt = window.localStorage.getItem("stats-crt") !== "off";
    } catch (error) { /* storage unavailable */ }
    setTheme(amber);
    setCrt(crt);
    $("theme-green").addEventListener("click", () => setTheme(false));
    $("theme-amber").addEventListener("click", () => setTheme(true));
    $("theme-crt").addEventListener("click", () => setCrt(!document.body.classList.contains("crt")));
    $("user-filter").addEventListener("input", renderUsers);
    $("status-filter").addEventListener("change", renderUsers);
    document.querySelectorAll("th.sortable").forEach((head) => head.addEventListener("click", () => {
      const key = head.dataset.sort;
      if (state.sortKey === key) state.sortDirection *= -1;
      else { state.sortKey = key; state.sortDirection = key === "user" ? 1 : -1; }
      document.querySelectorAll("th.sortable").forEach((item) => {
        item.classList.toggle("active", item.dataset.sort === state.sortKey);
        item.classList.toggle("asc", item.dataset.sort === state.sortKey && state.sortDirection > 0);
      });
      renderUsers();
    }));
    document.addEventListener("click", (event) => {
      if (event.target.id === "drawer-close" || event.target.id === "shade") { closeDrawer(); return; }
      const target = event.target.closest("[data-user], [data-node]");
      if (!target) return;
      if (target.dataset.user) openDrawer("user", target.dataset.user);
      else openDrawer("node", target.dataset.node);
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape") { closeDrawer(); return; }
      if (event.target.tagName === "INPUT" || event.target.tagName === "SELECT" || event.ctrlKey || event.metaKey) return;
      if (event.key === "/") { event.preventDefault(); $("user-filter").focus(); }
      else if (event.key === "t") setTheme(!document.body.classList.contains("amber"));
      else if (/^[1-5]$/.test(event.key)) setRange(Object.keys(ranges)[Number(event.key) - 1]);
    });
    // /stats/users/<user> and /stats/nodes/<node> open the matching drawer.
    const parts = window.location.pathname.split("/").filter(Boolean).map((part) => decodeURIComponent(part));
    const route = parts.slice(STATS_BASE.split("/").filter(Boolean).length);
    if (route[0] === "users" && route.length > 1) state.open = { user: route[route.length - 1] };
    else if (route[0] === "nodes" && route.length > 1) state.open = { node: route[1] };
    setRange(state.rangeSeconds);
  }

  init();
}());
