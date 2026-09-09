(function () {
  "use strict";

  const STATS_BASE = "/stats";
  const ranges = {
    3600: { label: "1 hour", bucket: 60 },
    86400: { label: "24 hours", bucket: 900 },
    604800: { label: "7 days", bucket: 3600 },
    2592000: { label: "30 days", bucket: 14400 },
    7776000: { label: "90 days", bucket: 43200 }
  };
  const state = { users: [], refreshMs: 15000, rangeSeconds: 3600, sortKey: "period_total", sortDirection: -1 };

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
    if (!value) return "Never";
    const seconds = Math.max(0, Math.round(Date.now() / 1000 - Number(value)));
    if (seconds < 10) return "Just now";
    if (seconds < 60) return `${seconds}s ago`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
    if (seconds < 604800) return `${Math.floor(seconds / 86400)}d ago`;
    return date(value);
  }

  function timeHtml(value) {
    if (!value) return '<span class="muted">Never</span>';
    const timestamp = Number(value);
    return `<time datetime="${new Date(timestamp * 1000).toISOString()}" title="${escapeHtml(date(timestamp))}">${escapeHtml(relativeDate(timestamp))}</time>`;
  }

  function presenceLabel(presence) {
    return presence === "online" ? "Online" : presence === "active" ? "Active" : presence === "unknown" ? "Unknown" : "Offline";
  }

  function presenceBadge(presence) {
    return `<span class="presence-badge ${presence}">${presenceLabel(presence)}</span>`;
  }

  function setConnection(status, text) {
    const element = document.getElementById("connection-state");
    if (!element) return;
    element.className = `status-pill ${status}`;
    element.textContent = text;
  }

  function showError(message) {
    const box = document.getElementById("access-error");
    const text = document.getElementById("access-error-text");
    if (box) box.classList.remove("hidden");
    if (text) text.textContent = message;
    setConnection("bad", "OFFLINE");
  }

  function setText(id, value) {
    const element = document.getElementById(id);
    if (element) element.textContent = value;
  }

  async function api(path) {
    const headers = { Accept: "application/json" };
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 12000);
    try {
      const response = await fetch(`${STATS_BASE}${path}`, { headers, cache: "no-store", signal: controller.signal });
      if (!response.ok) throw new Error(response.status === 401 ? "Authentication failed" : `Request failed (${response.status})`);
      return response.json();
    } finally {
      window.clearTimeout(timeout);
    }
  }

  function groupByNode(rows) {
    const grouped = new Map();
    rows.forEach((row) => {
      if (!grouped.has(row.node)) grouped.set(row.node, []);
      grouped.get(row.node).push(row);
    });
    return grouped;
  }

  // One card per server, its protocols listed together inside it - a node
  // running xray+hysteria2 is one thing with two health streams, not two
  // unrelated rows.
  function renderNodes(nodes, users = []) {
    const target = document.getElementById("nodes");
    if (!target) return;
    const grouped = groupByNode(nodes);
    document.getElementById("node-count").textContent = `${grouped.size} node${grouped.size === 1 ? "" : "s"}`;
    const cards = [...grouped.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([nodeName, rows]) => {
      const allOk = rows.every((row) => row.ok);
      const anyOk = rows.some((row) => row.ok);
      const overallClass = allOk ? "ok" : (anyOk ? "pending" : "bad");
      const overallLabel = allOk ? "OK" : (anyOk ? "DEGRADED" : "DOWN");
      const onlineTotal = new Set(users.filter((user) => user.node === nodeName && user.online).map((user) => user.user)).size;
      const lastPoll = Math.max(0, ...rows.map((row) => Number(row.ts) || 0));
      const protocolRows = rows.slice().sort((a, b) => a.protocol.localeCompare(b.protocol)).map((row) => {
        const online = new Set(
          users.filter((user) => user.node === nodeName && user.protocol === row.protocol && user.online).map((user) => user.user)
        ).size;
        const errorLine = !row.ok && row.error ? `<div class="node-card-protocol-error">${escapeHtml(row.error)}</div>` : "";
        return `<div class="node-card-protocol">
          <span class="protocol-badge">${escapeHtml(row.protocol)}</span>
          <span class="node-card-protocol-meta"><span class="state ${row.ok ? "ok" : "bad"}">${row.ok ? "OK" : "DOWN"}</span><span>${Number(row.latency_ms) || 0} ms</span><span>${online} online</span></span>
        </div>${errorLine}`;
      }).join("");
      return `<article class="node-card">
        <div class="node-card-head">
          <a class="user-link" href="${STATS_BASE}/nodes/${encodeURIComponent(nodeName)}">${escapeHtml(nodeName)}</a>
          <span class="status-pill ${overallClass}">${overallLabel}</span>
        </div>
        <div class="node-card-protocols">${protocolRows}</div>
        <div class="node-card-foot"><span>${onlineTotal} online</span><span>Last poll ${date(lastPoll)}</span></div>
      </article>`;
    }).join("");
    target.innerHTML = cards || `<div class="empty">No node data yet.</div>`;
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

  function aggregateTraffic(rows, groupKey) {
    const grouped = new Map();
    rows.forEach((row) => {
      const name = String(row[groupKey] || "unknown");
      const current = grouped.get(name) || { name, uplink: 0, downlink: 0, total: 0, online: false };
      current.uplink += Number(row.period_uplink || 0);
      current.downlink += Number(row.period_downlink || 0);
      current.total += Number(row.period_total || 0);
      current.online = current.online || Boolean(row.online);
      grouped.set(name, current);
    });
    return [...grouped.values()].sort((left, right) => right.total - left.total || left.name.localeCompare(right.name));
  }

  function renderTrafficBreakdown(rows, groupKey, targetId, hrefPrefix, limit = 12) {
    const target = document.getElementById(targetId);
    if (!target) return;
    const allGroups = aggregateTraffic(rows, groupKey);
    const grouped = allGroups.slice(0, limit);
    const maximum = Math.max(1, ...grouped.map((item) => item.total));
    const grandTotal = allGroups.reduce((sum, item) => sum + item.total, 0);
    target.innerHTML = grouped.length ? grouped.map((item) => {
      const totalWidth = item.total ? Math.max(1.5, item.total / maximum * 100) : 0;
      const uploadWidth = item.total ? item.uplink / item.total * 100 : 0;
      const downloadWidth = item.total ? item.downlink / item.total * 100 : 0;
      const share = grandTotal ? item.total / grandTotal * 100 : 0;
      const href = `${STATS_BASE}${hrefPrefix}${encodeURIComponent(item.name)}`;
      return `<a class="breakdown-row" href="${href}" title="Upload ${escapeHtml(bytes(item.uplink))}, download ${escapeHtml(bytes(item.downlink))}">
        <span class="breakdown-label"><strong>${escapeHtml(item.name)}</strong><small>${share.toFixed(1)}%${item.online ? " · online" : ""}</small></span>
        <span class="breakdown-track"><span class="breakdown-fill" style="width:${totalWidth.toFixed(2)}%"><i class="breakdown-upload" style="width:${uploadWidth.toFixed(2)}%"></i><i class="breakdown-download" style="width:${downloadWidth.toFixed(2)}%"></i></span></span>
        <b>${escapeHtml(bytes(item.total))}</b>
      </a>`;
    }).join("") : `<div class="empty">No traffic in the selected period.</div>`;
  }

  function renderUsers(users) {
    const target = document.getElementById("users");
    if (!target) return;
    const mobileTarget = document.getElementById("users-mobile");
    const filter = (document.getElementById("user-filter")?.value || "").toLowerCase().trim();
    const status = document.getElementById("status-filter")?.value || "all";
    const periodTotal = users.reduce((sum, user) => sum + user.period_total, 0);
    const visible = users.filter((user) => {
      const textMatch = !filter || `${user.user} ${user.nodes.join(" ")}`.toLowerCase().includes(filter);
      const userStatus = user.presence;
      return textMatch && (status === "all" || status === userStatus);
    }).sort((left, right) => {
      const comparison = state.sortKey === "user"
        ? left.user.localeCompare(right.user)
        : Number(left[state.sortKey] || 0) - Number(right[state.sortKey] || 0);
      return comparison * state.sortDirection || left.user.localeCompare(right.user);
    });
    target.innerHTML = visible.length ? visible.map((user) => `<tr>
      <td><a class="user-link" href="${STATS_BASE}/users/${encodeURIComponent(user.user)}">${escapeHtml(user.user)}</a><span class="table-subtext">${user.nodes.length} node${user.nodes.length === 1 ? "" : "s"} · ${user.protocols.map(escapeHtml).join(", ")}</span></td>
      <td>${presenceBadge(user.presence)}${user.online_nodes.length ? `<span class="table-subtext">${user.online_nodes.map(escapeHtml).join(", ")}</span>` : ""}</td>
      <td>${user.last_node ? `<a class="user-link" href="${STATS_BASE}/nodes/${encodeURIComponent(user.last_node)}">${escapeHtml(user.last_node)}</a>` : '<span class="muted">-</span>'}</td>
      <td>${timeHtml(user.last_online)}</td>
      <td>${bytes(user.period_total)}<span class="table-subtext">${periodTotal ? `${(user.period_total / periodTotal * 100).toFixed(1)}% of traffic` : "no traffic"}</span></td>
      <td>${bytes(user.total)}</td>
    </tr>`).join("") : `<tr><td colspan="6" class="empty">No matching users.</td></tr>`;
    if (mobileTarget) {
      mobileTarget.innerHTML = visible.length ? visible.map((user) => {
        return `<a class="mobile-user-card" href="${STATS_BASE}/users/${encodeURIComponent(user.user)}">
          <div class="mobile-user-head"><strong>${escapeHtml(user.user)}</strong>${presenceBadge(user.presence)}</div>
          <div class="mobile-user-meta">${user.nodes.map(escapeHtml).join(", ")} <span class="mobile-divider">|</span> ${user.protocols.map(escapeHtml).join(", ")}</div>
          <div class="mobile-user-stats"><span><b>${bytes(user.period_total)}</b><small>selected</small></span><span><b>${escapeHtml(user.last_node || "-")}</b><small>last node</small></span><span><b>${escapeHtml(relativeDate(user.last_online))}</b><small>last online</small></span></div>
        </a>`;
      }).join("") : `<div class="empty">No matching users.</div>`;
    }
  }

  function renderTrafficChart(data, targetId, coverageId) {
    const target = document.getElementById(targetId);
    if (!target) return;
    const samples = data.series || [];
    const available = samples.filter((sample) => sample.total !== null);
    if (!available.length) {
      target.innerHTML = `<span class="empty">No traffic data is available for this range.</span>`;
      setText(coverageId, "No poll coverage");
      return;
    }
    const max = Math.max(1, ...available.flatMap((sample) => [sample.uplink, sample.downlink]));
    const left = 62, right = 986, top = 22, bottom = 244;
    const width = Math.max(1, samples.length - 1);
    const x = (index) => left + index * ((right - left) / width);
    const y = (value) => bottom - (Number(value) / max) * (bottom - top);
    const grid = [0, 0.5, 1].map((ratio) => {
      const lineY = y(max * ratio);
      return `<line class="chart-grid-line" x1="${left}" y1="${lineY}" x2="${right}" y2="${lineY}"></line><text class="chart-axis-label" x="4" y="${lineY + 4}">${escapeHtml(bytes(max * ratio))}</text>`;
    }).join("");
    const line = (key, color) => {
      const segments = [];
      let points = [];
      samples.forEach((sample, index) => {
        if (sample[key] === null) {
          if (points.length) segments.push(points);
          points = [];
        } else {
          points.push(`${x(index)},${y(sample[key])}`);
        }
      });
      if (points.length) segments.push(points);
      return segments.map((segment) => `<polyline class="chart-line" points="${segment.join(" ")}" stroke="${color}"></polyline>`).join("");
    };
    const dots = available.map((sample) => {
      const index = samples.indexOf(sample);
      const title = `${date(sample.ts)} - up ${bytes(sample.uplink)}, down ${bytes(sample.downlink)}`;
      return `<circle cx="${x(index)}" cy="${y(sample.uplink)}" r="2.5" fill="#5b9cff"><title>${escapeHtml(title)}</title></circle><circle cx="${x(index)}" cy="${y(sample.downlink)}" r="2.5" fill="#d5a35e"><title>${escapeHtml(title)}</title></circle>`;
    }).join("");
    const axis = `<text class="chart-axis-label" x="${left}" y="278">${escapeHtml(date(samples[0].ts))}</text><text class="chart-axis-label" text-anchor="end" x="${right}" y="278">${escapeHtml(date(samples[samples.length - 1].ts))}</text>`;
    target.innerHTML = `<svg viewBox="0 0 1000 300" preserveAspectRatio="none" aria-hidden="true">${grid}${axis}${line("uplink", "#5b9cff")}${line("downlink", "#d5a35e")}${dots}</svg>`;
    const measured = samples.slice(0, -1).filter((sample) => sample.coverage !== null);
    const coverage = measured.length ? measured.reduce((sum, sample) => sum + Number(sample.coverage || 0), 0) / measured.length : null;
    setText(coverageId, coverage === null ? "Historical coverage unknown" : `${(coverage * 100).toFixed(1)}% poll coverage`);
  }

  function renderSummary(data, traffic) {
    const rawUsers = data.users || [];
    const users = aggregateUsers(rawUsers);
    const nodes = data.nodes || [];
    const total = users.reduce((sum, user) => sum + Number(user.period_total || 0), 0);
    const online = users.filter((user) => user.online).length;
    const healthy = nodes.filter((node) => node.ok).length;
    document.getElementById("metric-total").textContent = bytes(total);
    const complete = (traffic.series || []).slice(0, -1).at(-1);
    document.getElementById("metric-rate").textContent = complete?.total !== null && complete?.total !== undefined ? rate(complete.total / traffic.bucket_seconds) : "-";
    document.getElementById("metric-range-note").textContent = `${ranges[state.rangeSeconds].label} across all nodes`;
    document.getElementById("metric-online").textContent = String(online);
    document.getElementById("metric-users-note").textContent = `${users.length} tracked user${users.length === 1 ? "" : "s"}`;
    document.getElementById("metric-nodes").textContent = `${healthy}/${nodes.length}`;
    renderNodes(nodes, rawUsers);
    renderTrafficBreakdown(rawUsers, "node", "node-traffic-breakdown", "/nodes/");
    renderTrafficBreakdown(rawUsers, "user", "user-traffic-breakdown", "/users/", 8);
    state.users = users;
    renderUsers(users);
  }

  async function loadDashboard() {
    const requestedRange = state.rangeSeconds;
    const bucket = ranges[requestedRange].bucket;
    try {
      const [summary, traffic] = await Promise.all([
        api(`/api/summary?seconds=${requestedRange}`),
        api(`/api/traffic?seconds=${requestedRange}&bucket=${bucket}`)
      ]);
      if (requestedRange !== state.rangeSeconds) return;
      renderSummary(summary, traffic);
      renderTrafficChart(traffic, "mesh-traffic-chart", "traffic-coverage");
      const stamp = document.getElementById("last-refresh");
      if (stamp) stamp.textContent = `Updated ${new Date().toLocaleTimeString()}`;
      setConnection("ok", "LIVE");
      document.getElementById("access-error")?.classList.add("hidden");
    } catch (error) { showError(error.message); }
  }

  function userIdentity() {
    const parts = window.location.pathname.split("/").filter(Boolean).map((part) => decodeURIComponent(part));
    const statsParts = parts.slice(STATS_BASE.split("/").filter(Boolean).length);
    return { node: statsParts.length === 3 ? statsParts[1] : "", user: statsParts[statsParts.length - 1] || "" };
  }

  function nodeIdentity() {
    const parts = window.location.pathname.split("/").filter(Boolean).map((part) => decodeURIComponent(part));
    const statsParts = parts.slice(STATS_BASE.split("/").filter(Boolean).length);
    return statsParts[0] === "nodes" ? statsParts[1] || "" : "";
  }

  function renderUserNodes(users) {
    const target = document.getElementById("user-nodes-table");
    if (!target) return;
    target.innerHTML = users.length ? users.map((user) => `<tr>
      <td data-label="Node"><a class="user-link" href="${STATS_BASE}/nodes/${encodeURIComponent(user.node)}">${escapeHtml(user.node)}</a></td>
      <td data-label="Protocol"><span class="protocol-badge">${escapeHtml(user.protocol)}</span></td>
      <td data-label="Status">${presenceBadge(user.presence || (!user.available ? "unknown" : user.online ? "online" : user.active ? "active" : "offline"))}</td>
      <td data-label="Last online">${timeHtml(user.last_online)}</td><td data-label="Last traffic">${timeHtml(user.last_seen)}</td><td data-label="Selected period">${bytes(user.period_total)}</td>
    </tr>`).join("") : `<tr><td colspan="6" class="empty">No node traffic recorded for this user.</td></tr>`;
    const count = document.getElementById("node-sample-count");
    if (count) count.textContent = `${users.length} stream${users.length === 1 ? "" : "s"}`;
  }

  async function loadUser() {
    const requestedRange = state.rangeSeconds;
    const bucket = ranges[requestedRange].bucket;
    try {
      const identity = userIdentity();
      setText("user-title", identity.user || "User");
      document.title = `${identity.user || "User"} - Xray Stats`;
      const [allUsers, analytics] = await Promise.all([
        api(`/api/users?seconds=${requestedRange}`),
        api(`/api/users/${encodeURIComponent(identity.user)}/analytics?seconds=${requestedRange}&bucket=${bucket}`)
      ]);
      if (requestedRange !== state.rangeSeconds) return;
      const nodeUsers = allUsers.filter((item) => item.user === identity.user && (!identity.node || item.node === identity.node));
      if (!nodeUsers.length) throw new Error("User not found");
      const total = nodeUsers.reduce((sum, item) => sum + Number(item.period_total || 0), 0);
      const upload = nodeUsers.reduce((sum, item) => sum + Number(item.period_uplink || 0), 0);
      const download = nodeUsers.reduce((sum, item) => sum + Number(item.period_downlink || 0), 0);
      const aggregate = aggregateUsers(nodeUsers)[0];
      setText("user-total", bytes(total));
      setText("user-traffic-split", `Up ${bytes(upload)} / down ${bytes(download)}`);
      setText("user-active-nodes", `${analytics.active_nodes} active node${analytics.active_nodes === 1 ? "" : "s"} in ${ranges[requestedRange].label}`);
      setText("user-active-node-count", String(analytics.active_nodes));
      setText("user-last-seen", relativeDate(aggregate.last_online));
      setText("user-last-node", `Last node ${aggregate.last_node || "-"}`);
      setText("user-presence", presenceLabel(aggregate.presence));
      setText("user-status", aggregate.presence === "online" ? `Confirmed on ${aggregate.online_nodes.join(", ")}` : aggregate.presence === "active" ? "Traffic detected in the latest poll" : aggregate.presence === "unknown" ? "Telemetry is currently unavailable" : "No confirmed session");
      renderUserNodes(nodeUsers);
      renderTrafficBreakdown(nodeUsers, "node", "user-node-breakdown", "/nodes/");
      renderTrafficChart(analytics.traffic, "user-traffic-chart", "user-traffic-coverage");
      setConnection("ok", "LIVE"); document.getElementById("access-error")?.classList.add("hidden");
    } catch (error) { showError(error.message); }
  }

  function renderNodeUsers(users) {
    const target = document.getElementById("node-users-table");
    if (!target) return;
    target.innerHTML = users.length ? users.map((user) => `<tr>
      <td data-label="User"><a class="user-link" href="${STATS_BASE}/users/${encodeURIComponent(user.user)}">${escapeHtml(user.user)}</a></td>
      <td data-label="Protocol"><span class="protocol-badge">${escapeHtml(user.protocol)}</span></td>
      <td data-label="Status">${presenceBadge(user.presence || (!user.available ? "unknown" : user.online ? "online" : user.active ? "active" : "offline"))}</td>
      <td data-label="Last online">${timeHtml(user.last_online)}</td><td data-label="Last traffic">${timeHtml(user.last_seen)}</td><td data-label="Selected period">${bytes(user.period_total)}</td>
    </tr>`).join("") : `<tr><td colspan="6" class="empty">No users recorded on this node.</td></tr>`;
    setText("node-user-count", `${users.length} user${users.length === 1 ? "" : "s"}`);
  }

  function renderNodeProtocols(healthRows) {
    const target = document.getElementById("node-protocol-strip");
    if (!target) return;
    target.innerHTML = healthRows.slice().sort((a, b) => a.protocol.localeCompare(b.protocol)).map((row) => `
      <span class="protocol-status-chip">
        <span class="protocol-badge">${escapeHtml(row.protocol)}</span>
        <span class="state ${row.ok ? "ok" : "bad"}">${row.ok ? "OK" : "DOWN"}</span>
        <span class="muted">${Number(row.latency_ms) || 0} ms</span>
        ${!row.ok && row.error ? `<span class="muted">- ${escapeHtml(row.error)}</span>` : ""}
      </span>`).join("");
  }

  function renderNodeSamples(samples) {
    const target = document.getElementById("node-samples-table");
    if (!target) return;
    const recent = samples.slice(-48).reverse();
    target.innerHTML = recent.length ? recent.map((sample) => `<tr>
      <td data-label="Time">${date(sample.ts)}</td><td data-label="Upload">${bytes(sample.uplink)}</td><td data-label="Download">${bytes(sample.downlink)}</td><td data-label="Total">${bytes(sample.total)}</td>
    </tr>`).join("") : `<tr><td colspan="4" class="empty">No traffic samples recorded on this node.</td></tr>`;
  }

  async function loadNode() {
    const requestedRange = state.rangeSeconds;
    const bucket = ranges[requestedRange].bucket;
    try {
      const nodeName = nodeIdentity();
      setText("node-title", nodeName || "Node");
      document.title = `${nodeName || "Node"} - Xray Stats`;
      const [nodes, users, analytics, samples] = await Promise.all([
        api("/api/nodes"),
        api(`/api/nodes/${encodeURIComponent(nodeName)}/users?seconds=${requestedRange}`),
        api(`/api/nodes/${encodeURIComponent(nodeName)}/analytics?seconds=${requestedRange}&bucket=${bucket}`),
        api(`/api/nodes/${encodeURIComponent(nodeName)}/history`)
      ]);
      if (requestedRange !== state.rangeSeconds) return;
      const healthRows = nodes.filter((item) => item.node === nodeName);
      if (!healthRows.length) throw new Error("Node not found");
      const allOk = healthRows.every((item) => item.ok);
      const anyOk = healthRows.some((item) => item.ok);
      const healthyCount = healthRows.filter((item) => item.ok).length;
      renderNodeProtocols(healthRows);
      const total = users.reduce((sum, item) => sum + Number(item.period_total || 0), 0);
      const upload = users.reduce((sum, item) => sum + Number(item.period_uplink || 0), 0);
      const download = users.reduce((sum, item) => sum + Number(item.period_downlink || 0), 0);
      const online = new Set(users.filter((item) => item.online).map((item) => item.user)).size;
      setText("node-status", allOk ? "OK" : (anyOk ? "DEGRADED" : "DOWN"));
      setText("node-status-note", `${healthyCount}/${healthRows.length} protocol${healthRows.length === 1 ? "" : "s"} healthy`);
      setText("node-availability", analytics.availability === null ? "-" : `${(analytics.availability * 100).toFixed(2)}%`);
      setText("node-poll-summary", `${analytics.successful_polls}/${analytics.polls} polls, avg ${analytics.average_latency_ms ?? "-"} ms`);
      setText("node-total", bytes(total));
      const complete = (analytics.traffic.series || []).slice(0, -1).at(-1);
      setText("node-rate", complete?.total !== null && complete?.total !== undefined ? `${rate(complete.total / analytics.traffic.bucket_seconds)} recent average` : "recent throughput unavailable");
      setText("node-up", bytes(upload));
      setText("node-down", bytes(download));
      setText("node-online", String(online));
      renderNodeUsers(users);
      renderTrafficBreakdown(users, "user", "node-user-breakdown", "/users/", 10);
      setText("node-user-count", `${analytics.active_users} active / ${users.length} tracked`);
      renderTrafficChart(analytics.traffic, "node-traffic-chart", "node-traffic-coverage");
      renderNodeSamples(samples);
      setConnection(allOk ? "ok" : (anyOk ? "pending" : "bad"), allOk ? "LIVE" : (anyOk ? "DEGRADED" : "DOWN"));
      document.getElementById("access-error")?.classList.add("hidden");
    } catch (error) { showError(error.message); }
  }

  function startPolling(load) {
    async function tick() {
      await load();
      window.setTimeout(tick, state.refreshMs);
    }
    void tick();
  }

  function bindRange(id, load) {
    document.getElementById(id)?.addEventListener("change", (event) => {
      state.rangeSeconds = Number(event.target.value);
      void load();
    });
  }

  window.initUserPage = function () { bindRange("user-time-range", loadUser); startPolling(loadUser); };
  window.initNodePage = function () { bindRange("node-time-range", loadNode); startPolling(loadNode); };
  if (document.getElementById("nodes")) {
    document.getElementById("user-filter")?.addEventListener("input", () => renderUsers(state.users));
    document.getElementById("status-filter")?.addEventListener("change", () => renderUsers(state.users));
    document.getElementById("time-range")?.addEventListener("change", (event) => {
      state.rangeSeconds = Number(event.target.value);
      void loadDashboard();
    });
    document.querySelectorAll(".sort-button").forEach((button) => button.addEventListener("click", () => {
      const key = button.dataset.sort;
      if (state.sortKey === key) state.sortDirection *= -1;
      else {
        state.sortKey = key;
        state.sortDirection = key === "user" ? 1 : -1;
      }
      document.querySelectorAll(".sort-button").forEach((item) => {
        item.classList.toggle("active", item.dataset.sort === state.sortKey);
        item.classList.toggle("descending", item.dataset.sort === state.sortKey && state.sortDirection < 0);
      });
      renderUsers(state.users);
    }));
    startPolling(loadDashboard);
  }
}());
