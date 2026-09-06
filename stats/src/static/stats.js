(function () {
  "use strict";

  const STATS_BASE = "/stats";
  const query = new URLSearchParams(window.location.search);
  const token = query.get("token") || window.localStorage.getItem("stats_token") || "";
  if (token) window.localStorage.setItem("stats_token", token);
  const state = { users: [], refreshMs: 15000 };

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
    if (token) headers["X-Stats-Token"] = token;
    const response = await fetch(`${STATS_BASE}${path}`, { headers, cache: "no-store" });
    if (!response.ok) throw new Error(response.status === 401 ? "Authentication failed" : `Request failed (${response.status})`);
    return response.json();
  }

  function renderNodes(nodes, users = []) {
    const target = document.getElementById("nodes");
    if (!target) return;
    document.getElementById("node-count").textContent = `${nodes.length} node${nodes.length === 1 ? "" : "s"}`;
    target.innerHTML = nodes.length ? nodes.map((node) => `<tr>
      <td><a class="user-link" href="${STATS_BASE}/nodes/${encodeURIComponent(node.node)}${token ? `?token=${encodeURIComponent(token)}` : ""}">${escapeHtml(node.node)}</a></td><td><span class="state ${node.ok ? "ok" : "bad"}">${node.ok ? "OK" : "DOWN"}</span></td>
      <td>${Number(node.latency_ms) || 0} ms</td><td>${users.filter((user) => user.node === node.node && user.online).length}</td><td class="muted">${escapeHtml(node.error || "-")}</td><td>${date(node.ts)}</td>
    </tr>`).join("") : `<tr><td colspan="6" class="empty">No node data yet.</td></tr>`;
  }

  function aggregateUsers(users) {
    const grouped = new Map();
    users.forEach((item) => {
      const current = grouped.get(item.user) || {
        user: item.user, nodes: [], total: 0, uplink: 0, downlink: 0,
        online: false, online_nodes: [], active: false, last_seen: 0
      };
      current.nodes.push(item.node);
      current.total += Number(item.total || 0);
      current.uplink += Number(item.uplink || 0);
      current.downlink += Number(item.downlink || 0);
      current.online = current.online || Boolean(item.online);
      if (item.online) current.online_nodes.push(item.node);
      current.active = current.active || Boolean(item.active);
      current.last_seen = Math.max(current.last_seen, Number(item.last_seen || 0));
      grouped.set(item.user, current);
    });
    return [...grouped.values()].map((item) => {
      item.nodes = [...new Set(item.nodes)].sort();
      item.online_nodes = [...new Set(item.online_nodes)].sort();
      return item;
    }).sort((left, right) => right.total - left.total || left.user.localeCompare(right.user));
  }

  function renderUsers(users) {
    const target = document.getElementById("users");
    if (!target) return;
    const filter = (document.getElementById("user-filter")?.value || "").toLowerCase().trim();
    const visible = users.filter((user) => !filter || `${user.user} ${user.nodes.join(" ")}`.toLowerCase().includes(filter));
    target.innerHTML = visible.length ? visible.map((user) => `<tr>
      <td><a class="user-link" href="${STATS_BASE}/users/${encodeURIComponent(user.user)}${token ? `?token=${encodeURIComponent(token)}` : ""}">${escapeHtml(user.user)}</a></td>
      <td>${user.nodes.map(escapeHtml).join(", ")}</td><td>${bytes(user.total)}</td><td>${bytes(user.uplink)}</td><td>${bytes(user.downlink)}</td>
      <td class="${user.online ? "yes" : "no"}">${user.online ? "yes" : "no"}</td><td class="${user.online ? "yes" : "muted"}">${user.online_nodes.length ? user.online_nodes.map(escapeHtml).join(", ") : "-"}</td><td class="${user.active ? "active" : "muted"}">${user.active ? "active" : "idle"}</td><td>${date(user.last_seen)}</td>
    </tr>`).join("") : `<tr><td colspan="9" class="empty">No matching users.</td></tr>`;
  }

  function renderSummary(data) {
    const rawUsers = data.users || [];
    const users = aggregateUsers(rawUsers);
    const nodes = data.nodes || [];
    const total = users.reduce((sum, user) => sum + Number(user.total || 0), 0);
    const down = users.reduce((sum, user) => sum + Number(user.downlink || 0), 0);
    const online = users.filter((user) => user.online).length;
    const healthy = nodes.filter((node) => node.ok).length;
    document.getElementById("metric-total").textContent = bytes(total);
    document.getElementById("metric-down").textContent = bytes(down);
    document.getElementById("metric-online").textContent = String(online);
    document.getElementById("metric-users-note").textContent = `${users.length} tracked user${users.length === 1 ? "" : "s"}`;
    document.getElementById("metric-nodes").textContent = `${healthy}/${nodes.length}`;
    renderNodes(nodes, rawUsers); state.users = users; renderUsers(users);
  }

  async function loadDashboard() {
    try {
      renderSummary(await api("/api/summary"));
      const stamp = document.getElementById("last-refresh");
      if (stamp) stamp.textContent = `Updated ${new Date().toLocaleTimeString()}`;
      setConnection("ok", "LIVE");
      document.getElementById("access-error")?.classList.add("hidden");
    } catch (error) { showError(error.message); }
  }

  function renderChart(samples) {
    const target = document.getElementById("traffic-chart");
    if (!target) return;
    const recent = samples.slice(-48);
    const max = Math.max(1, ...recent.map((sample) => Math.max(Number(sample.uplink) || 0, Number(sample.downlink) || 0)));
    target.innerHTML = recent.length ? recent.map((sample) => {
      const up = Math.max(2, (Number(sample.uplink) || 0) / max * 100);
      const down = Math.max(2, (Number(sample.downlink) || 0) / max * 100);
      return `<div class="bar-group" title="${escapeHtml(date(sample.ts))}"><i class="bar upload" style="height:${up}%"></i><i class="bar download" style="height:${down}%"></i></div>`;
    }).join("") : `<span class="empty">No samples recorded for this user.</span>`;
    const count = document.getElementById("sample-count");
    if (count) count.textContent = `${samples.length} sample${samples.length === 1 ? "" : "s"}`;
  }

  function renderUserChart(samples, scopedNode = "") {
    const target = document.getElementById("traffic-chart");
    const legend = document.getElementById("chart-legend");
    if (!target) return;
    const colors = ["#65a9ff", "#b18cff", "#55d68b", "#f2b762", "#ff7373", "#65d9d2"];
    const series = new Map();
    samples.forEach((sample) => {
      const node = sample.node || scopedNode || "node";
      const bucket = Math.floor(Number(sample.ts) / 60) * 60;
      const values = series.get(node) || new Map();
      values.set(bucket, (values.get(bucket) || 0) + Number(sample.total || 0));
      series.set(node, values);
    });
    const buckets = [...new Set([...series.values()].flatMap((values) => [...values.keys()]))].sort().slice(-48);
    if (!buckets.length) {
      target.innerHTML = `<span class="empty">No traffic samples recorded for this user.</span>`;
      if (legend) legend.innerHTML = "";
      return;
    }
    const max = Math.max(1, ...[...series.values()].flatMap((values) => buckets.map((bucket) => values.get(bucket) || 0)));
    const left = 58, right = 986, top = 22, bottom = 244;
    const width = Math.max(1, buckets.length - 1);
    const x = (index) => left + index * ((right - left) / width);
    const y = (value) => bottom - (value / max) * (bottom - top);
    const grid = [0, 0.5, 1].map((ratio) => {
      const lineY = y(max * ratio);
      return `<line class="chart-grid-line" x1="${left}" y1="${lineY}" x2="${right}" y2="${lineY}"></line><text class="chart-axis-label" x="4" y="${lineY + 4}">${escapeHtml(bytes(max * ratio))}</text>`;
    }).join("");
    const axis = `<text class="chart-axis-label" x="${left}" y="278">${escapeHtml(shortTime(buckets[0]))}</text><text class="chart-axis-label" text-anchor="end" x="${right}" y="278">${escapeHtml(shortTime(buckets[buckets.length - 1]))}</text>`;
    const lines = [...series.entries()].map(([node, values], index) => {
      const color = colors[index % colors.length];
      const points = buckets.map((bucket, bucketIndex) => `${x(bucketIndex)},${y(values.get(bucket) || 0)}`).join(" ");
      const dots = buckets.map((bucket, bucketIndex) => `<circle cx="${x(bucketIndex)}" cy="${y(values.get(bucket) || 0)}" r="3" fill="${color}"><title>${escapeHtml(`${node} - ${shortTime(bucket)} - ${bytes(values.get(bucket) || 0)}`)}</title></circle>`).join("");
      return `<polyline class="chart-line" points="${points}" stroke="${color}"></polyline>${dots}`;
    }).join("");
    target.innerHTML = `<svg viewBox="0 0 1000 300" preserveAspectRatio="none" aria-hidden="true">${grid}${axis}${lines}</svg>`;
    if (legend) legend.innerHTML = [...series.keys()].map((node, index) => `<span><i class="legend-line" style="background:${colors[index % colors.length]}"></i>${escapeHtml(node)}</span>`).join("");
    const count = document.getElementById("sample-count");
    if (count) count.textContent = `${buckets.length} minute${buckets.length === 1 ? "" : "s"}`;
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

  function shortTime(timestamp) {
    return new Date(Number(timestamp) * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  function renderUserNodes(users) {
    const target = document.getElementById("user-nodes-table");
    if (!target) return;
    target.innerHTML = users.length ? users.map((user) => `<tr>
      <td>${escapeHtml(user.node)}</td><td>${bytes(user.total)}</td><td>${bytes(user.uplink)}</td><td>${bytes(user.downlink)}</td>
      <td class="${user.online ? "yes" : "no"}">${user.online ? "yes" : "no"}</td>
      <td class="${user.active ? "active" : "muted"}">${user.active ? "active" : "idle"}</td><td>${date(user.last_seen)}</td>
    </tr>`).join("") : `<tr><td colspan="7" class="empty">No node traffic recorded for this user.</td></tr>`;
    const count = document.getElementById("node-sample-count");
    if (count) count.textContent = `${users.length} node${users.length === 1 ? "" : "s"}`;
  }

  async function loadUser() {
    const identity = userIdentity();
    try {
      const allUsers = await api("/api/users");
      const nodeUsers = allUsers.filter((item) => item.user === identity.user && (!identity.node || item.node === identity.node));
      if (!nodeUsers.length) throw new Error("User not found");
      const historyPath = identity.node
        ? `/api/users/${encodeURIComponent(identity.node)}/${encodeURIComponent(identity.user)}/history`
        : `/api/users/${encodeURIComponent(identity.user)}/history`;
      const samples = await api(historyPath);
      const total = nodeUsers.reduce((sum, item) => sum + Number(item.total || 0), 0);
      const upload = nodeUsers.reduce((sum, item) => sum + Number(item.uplink || 0), 0);
      const download = nodeUsers.reduce((sum, item) => sum + Number(item.downlink || 0), 0);
      const lastSeen = Math.max(...nodeUsers.map((item) => Number(item.last_seen || 0)));
      const online = nodeUsers.some((item) => item.online);
      const active = nodeUsers.some((item) => item.active);
      setText("user-total", bytes(total));
      setText("user-up", bytes(upload));
      setText("user-down", bytes(download));
      setText("user-last-seen", date(lastSeen));
      setText("user-nodes", String(nodeUsers.length));
      setText("user-status", online ? "online on one or more nodes" : (active ? "active recently" : "offline"));
      renderUserNodes(nodeUsers);
      renderUserChart(samples, identity.node); setConnection("ok", "LIVE"); document.getElementById("access-error")?.classList.add("hidden");
    } catch (error) { showError(error.message); }
  }

  function renderNodeUsers(users) {
    const target = document.getElementById("node-users-table");
    if (!target) return;
    target.innerHTML = users.length ? users.map((user) => `<tr>
      <td><a class="user-link" href="${STATS_BASE}/users/${encodeURIComponent(user.user)}${token ? `?token=${encodeURIComponent(token)}` : ""}">${escapeHtml(user.user)}</a></td>
      <td>${bytes(user.total)}</td><td>${bytes(user.uplink)}</td><td>${bytes(user.downlink)}</td>
      <td class="${user.online ? "yes" : "no"}">${user.online ? "yes" : "no"}</td>
      <td class="${user.active ? "active" : "muted"}">${user.active ? "active" : "idle"}</td><td>${date(user.last_seen)}</td>
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
    const nodeName = nodeIdentity();
    try {
      const [nodes, users, samples] = await Promise.all([
        api("/api/nodes"),
        api(`/api/nodes/${encodeURIComponent(nodeName)}/users`),
        api(`/api/nodes/${encodeURIComponent(nodeName)}/history`)
      ]);
      const health = nodes.find((item) => item.node === nodeName);
      if (!health) throw new Error("Node not found");
      const total = users.reduce((sum, item) => sum + Number(item.total || 0), 0);
      const upload = users.reduce((sum, item) => sum + Number(item.uplink || 0), 0);
      const download = users.reduce((sum, item) => sum + Number(item.downlink || 0), 0);
      const online = users.filter((item) => item.online).length;
      setText("node-status", health.ok ? "OK" : "DOWN");
      setText("node-status-note", health.ok ? "poll successful" : (health.error || "poll failed"));
      setText("node-latency", `${Number(health.latency_ms) || 0} ms`);
      setText("node-last-poll", `last poll ${date(health.ts)}`);
      setText("node-total", bytes(total));
      setText("node-up", bytes(upload));
      setText("node-down", bytes(download));
      setText("node-online", String(online));
      renderNodeUsers(users); renderChart(samples); renderNodeSamples(samples);
      setConnection(health.ok ? "ok" : "bad", health.ok ? "LIVE" : "DEGRADED");
      document.getElementById("access-error")?.classList.add("hidden");
    } catch (error) { showError(error.message); }
  }

  window.initUserPage = function () {
    loadUser();
    window.setInterval(loadUser, state.refreshMs);
  };
  window.initNodePage = function () {
    loadNode();
    window.setInterval(loadNode, state.refreshMs);
  };
  if (document.getElementById("nodes")) {
    document.getElementById("user-filter")?.addEventListener("input", () => renderUsers(state.users));
    loadDashboard(); window.setInterval(loadDashboard, state.refreshMs);
  }
}());
