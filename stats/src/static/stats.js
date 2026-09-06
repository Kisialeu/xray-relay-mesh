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
  const state = { users: [], refreshMs: 15000, rangeSeconds: 86400, sortKey: "period_total", sortDirection: -1 };

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

  function renderNodes(nodes, users = []) {
    const target = document.getElementById("nodes");
    if (!target) return;
    document.getElementById("node-count").textContent = `${nodes.length} node${nodes.length === 1 ? "" : "s"}`;
    target.innerHTML = nodes.length ? nodes.map((node) => `<tr>
      <td><a class="user-link" href="${STATS_BASE}/nodes/${encodeURIComponent(node.node)}">${escapeHtml(node.node)}</a></td><td><span class="state ${node.ok ? "ok" : "bad"}">${node.ok ? "OK" : "DOWN"}</span></td>
      <td>${Number(node.latency_ms) || 0} ms</td><td>${users.filter((user) => user.node === node.node && user.online).length}</td><td class="muted">${escapeHtml(node.error || "-")}</td><td>${date(node.ts)}</td>
    </tr>`).join("") : `<tr><td colspan="6" class="empty">No node data yet.</td></tr>`;
  }

  function aggregateUsers(users) {
    const grouped = new Map();
    users.forEach((item) => {
      const current = grouped.get(item.user) || {
        user: item.user, nodes: [], total: 0, uplink: 0, downlink: 0,
        period_total: 0, period_uplink: 0, period_downlink: 0,
        online: false, online_nodes: [], active: false, available: false, last_seen: 0
      };
      current.nodes.push(item.node);
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
      current.last_seen = Math.max(current.last_seen, Number(item.last_seen || 0));
      grouped.set(item.user, current);
    });
    return [...grouped.values()].map((item) => {
      item.nodes = [...new Set(item.nodes)].sort();
      item.online_nodes = [...new Set(item.online_nodes)].sort();
      return item;
    });
  }

  function renderUsers(users) {
    const target = document.getElementById("users");
    if (!target) return;
    const filter = (document.getElementById("user-filter")?.value || "").toLowerCase().trim();
    const status = document.getElementById("status-filter")?.value || "all";
    const periodTotal = users.reduce((sum, user) => sum + user.period_total, 0);
    const visible = users.filter((user) => {
      const textMatch = !filter || `${user.user} ${user.nodes.join(" ")}`.toLowerCase().includes(filter);
      const userStatus = !user.available ? "unknown" : (user.online ? "online" : "offline");
      return textMatch && (status === "all" || status === userStatus);
    }).sort((left, right) => {
      const comparison = state.sortKey === "user"
        ? left.user.localeCompare(right.user)
        : Number(left[state.sortKey] || 0) - Number(right[state.sortKey] || 0);
      return comparison * state.sortDirection || left.user.localeCompare(right.user);
    });
    target.innerHTML = visible.length ? visible.map((user) => `<tr>
      <td><a class="user-link" href="${STATS_BASE}/users/${encodeURIComponent(user.user)}">${escapeHtml(user.user)}</a></td>
      <td>${user.nodes.map(escapeHtml).join(", ")}</td><td>${bytes(user.period_total)}</td><td>${periodTotal ? `${(user.period_total / periodTotal * 100).toFixed(1)}%` : "-"}</td><td>${bytes(user.total)}</td>
      <td class="${!user.available ? "unknown" : (user.online ? "yes" : "no")}">${!user.available ? "unknown" : (user.online ? "yes" : "no")}</td><td class="${user.online ? "yes" : "muted"}">${user.online_nodes.length ? user.online_nodes.map(escapeHtml).join(", ") : "-"}</td><td class="${!user.available ? "unknown" : (user.active ? "active" : "muted")}">${!user.available ? "unknown" : (user.active ? "active" : "idle")}</td><td>${date(user.last_seen)}</td>
    </tr>`).join("") : `<tr><td colspan="9" class="empty">No matching users.</td></tr>`;
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
      return `<circle cx="${x(index)}" cy="${y(sample.uplink)}" r="2.5" fill="#65a9ff"><title>${escapeHtml(title)}</title></circle><circle cx="${x(index)}" cy="${y(sample.downlink)}" r="2.5" fill="#b18cff"><title>${escapeHtml(title)}</title></circle>`;
    }).join("");
    const axis = `<text class="chart-axis-label" x="${left}" y="278">${escapeHtml(date(samples[0].ts))}</text><text class="chart-axis-label" text-anchor="end" x="${right}" y="278">${escapeHtml(date(samples[samples.length - 1].ts))}</text>`;
    target.innerHTML = `<svg viewBox="0 0 1000 300" preserveAspectRatio="none" aria-hidden="true">${grid}${axis}${line("uplink", "#65a9ff")}${line("downlink", "#b18cff")}${dots}</svg>`;
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
    renderNodes(nodes, rawUsers); state.users = users; renderUsers(users);
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
      <td><a class="user-link" href="${STATS_BASE}/nodes/${encodeURIComponent(user.node)}">${escapeHtml(user.node)}</a></td><td>${bytes(user.period_total)}</td><td>${bytes(user.period_uplink)}</td><td>${bytes(user.period_downlink)}</td>
      <td class="${!user.available ? "unknown" : (user.online ? "yes" : "no")}">${!user.available ? "unknown" : (user.online ? "yes" : "no")}</td>
      <td class="${!user.available ? "unknown" : (user.active ? "active" : "muted")}">${!user.available ? "unknown" : (user.active ? "active" : "idle")}</td><td>${date(user.last_seen)}</td>
    </tr>`).join("") : `<tr><td colspan="7" class="empty">No node traffic recorded for this user.</td></tr>`;
    const count = document.getElementById("node-sample-count");
    if (count) count.textContent = `${users.length} node${users.length === 1 ? "" : "s"}`;
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
      const lastSeen = Math.max(...nodeUsers.map((item) => Number(item.last_seen || 0)));
      const online = nodeUsers.some((item) => item.online);
      const active = nodeUsers.some((item) => item.active);
      setText("user-total", bytes(total));
      setText("user-up", bytes(upload));
      setText("user-down", bytes(download));
      setText("user-active-nodes", `${analytics.active_nodes} active node${analytics.active_nodes === 1 ? "" : "s"} in ${ranges[requestedRange].label}`);
      setText("user-last-seen", date(lastSeen));
      setText("user-nodes", String(nodeUsers.length));
      setText("user-status", online ? "online on one or more nodes" : (active ? "active recently" : "offline"));
      renderUserNodes(nodeUsers);
      renderTrafficChart(analytics.traffic, "user-traffic-chart", "user-traffic-coverage");
      setConnection("ok", "LIVE"); document.getElementById("access-error")?.classList.add("hidden");
    } catch (error) { showError(error.message); }
  }

  function renderNodeUsers(users) {
    const target = document.getElementById("node-users-table");
    if (!target) return;
    target.innerHTML = users.length ? users.map((user) => `<tr>
      <td><a class="user-link" href="${STATS_BASE}/users/${encodeURIComponent(user.user)}">${escapeHtml(user.user)}</a></td>
      <td>${bytes(user.period_total)}</td><td>${bytes(user.period_uplink)}</td><td>${bytes(user.period_downlink)}</td>
      <td class="${!user.available ? "unknown" : (user.online ? "yes" : "no")}">${!user.available ? "unknown" : (user.online ? "yes" : "no")}</td>
      <td class="${!user.available ? "unknown" : (user.active ? "active" : "muted")}">${!user.available ? "unknown" : (user.active ? "active" : "idle")}</td><td>${date(user.last_seen)}</td>
    </tr>`).join("") : `<tr><td colspan="7" class="empty">No users recorded on this node.</td></tr>`;
    setText("node-user-count", `${users.length} user${users.length === 1 ? "" : "s"}`);
  }

  function renderNodeSamples(samples) {
    const target = document.getElementById("node-samples-table");
    if (!target) return;
    const recent = samples.slice(-48).reverse();
    target.innerHTML = recent.length ? recent.map((sample) => `<tr>
      <td>${date(sample.ts)}</td><td>${bytes(sample.uplink)}</td><td>${bytes(sample.downlink)}</td><td>${bytes(sample.total)}</td>
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
      const health = nodes.find((item) => item.node === nodeName);
      if (!health) throw new Error("Node not found");
      const total = users.reduce((sum, item) => sum + Number(item.period_total || 0), 0);
      const upload = users.reduce((sum, item) => sum + Number(item.period_uplink || 0), 0);
      const download = users.reduce((sum, item) => sum + Number(item.period_downlink || 0), 0);
      const online = users.filter((item) => item.online).length;
      setText("node-status", health.ok ? "OK" : "DOWN");
      setText("node-status-note", health.ok ? "poll successful" : (health.error || "poll failed"));
      setText("node-availability", analytics.availability === null ? "-" : `${(analytics.availability * 100).toFixed(2)}%`);
      setText("node-poll-summary", `${analytics.successful_polls}/${analytics.polls} polls, avg ${analytics.average_latency_ms ?? "-"} ms`);
      setText("node-total", bytes(total));
      const complete = (analytics.traffic.series || []).slice(0, -1).at(-1);
      setText("node-rate", complete?.total !== null && complete?.total !== undefined ? `${rate(complete.total / analytics.traffic.bucket_seconds)} recent average` : "recent throughput unavailable");
      setText("node-up", bytes(upload));
      setText("node-down", bytes(download));
      setText("node-online", String(online));
      renderNodeUsers(users);
      setText("node-user-count", `${analytics.active_users} active / ${users.length} tracked`);
      renderTrafficChart(analytics.traffic, "node-traffic-chart", "node-traffic-coverage");
      renderNodeSamples(samples);
      setConnection(health.ok ? "ok" : "bad", health.ok ? "LIVE" : "DEGRADED");
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
