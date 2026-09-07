"use strict";

// ══════════════════════════════════════════════════════════════════════════════
// STATE
// ══════════════════════════════════════════════════════════════════════════════

const State = Object.seal({
  history: /** @type {string[]} */ ([]),
  histIdx: -1,
});

const DOM_LIMIT   = 400;
const HIST_LIMIT  = 100;
const PROMPT_TEXT = 'visitor@paravozika:~$ ';

// ══════════════════════════════════════════════════════════════════════════════
// RENDERING — zero innerHTML for dynamic content
// ══════════════════════════════════════════════════════════════════════════════

const outputEl = /** @type {HTMLElement} */ (document.getElementById('output'));
const inputEl  = /** @type {HTMLInputElement} */ (document.getElementById('cmd-input'));
const content  = window.RIDE_LIFE_CONTENT;

if (!content) {
  const error = document.createElement('div');
  error.className = 'out-line c-red bold';
  error.setAttribute('role', 'alert');
  error.textContent = 'terminal content unavailable. reload the page or try again later.';
  outputEl.appendChild(error);
  throw new Error('RIDE_LIFE_CONTENT is unavailable');
}

const {
  THOUGHTS,
  PRIVACY_KV,
  HYGIENE_LIST,
  MANIFEST_LINES,
} = content;

inputEl.disabled = false;

function pruneDOM() {
  while (outputEl.childElementCount > DOM_LIMIT) {
    outputEl.removeChild(outputEl.firstChild);
  }
}

function appendNode(node) {
  outputEl.appendChild(node);
  outputEl.scrollTop = outputEl.scrollHeight;
  pruneDOM();
}

/** @param {string} cls */
function makeDiv(cls) {
  const d = document.createElement('div');
  d.className = cls;
  return d;
}

/**
 * Safe text line — never interprets user input as markup.
 * @param {string} text
 * @param {...string} classes
 */
function lineText(text, ...classes) {
  const d = makeDiv(['out-line', 'fi', ...classes].filter(Boolean).join(' '));
  d.textContent = text;
  appendNode(d);
}

function lineBlank() {
  appendNode(makeDiv('out-blank fi'));
}

/**
 * @param {string} text
 * @param {...string} classes
 * @returns {HTMLSpanElement}
 */
function makeSpan(text, ...classes) {
  const s = document.createElement('span');
  s.className = classes.filter(Boolean).join(' ');
  s.textContent = text;
  return s;
}

/** Echoes typed command — prompt + input both via textContent. */
function renderCmdEcho(cmd) {
  const d = makeDiv('out-line fi');
  d.appendChild(makeSpan(PROMPT_TEXT, 'c-green', 'bold'));
  d.appendChild(makeSpan(cmd, 'c-white'));
  appendNode(d);
}

/**
 * Inline row of colored text segments. No markup — all textContent.
 * @param {Array<{text: string, classes?: string[]}>} segments
 */
function renderInline(segments) {
  const d = makeDiv('out-line fi');
  segments.forEach(({ text, classes }) => d.appendChild(makeSpan(text, ...(classes || []))));
  appendNode(d);
}

/** @param {string} cmd  @param {string} desc */
function renderHelpRow(cmd, desc) {
  const d = makeDiv('help-grid fi');
  d.appendChild(makeSpan(cmd, 'c-amber'));
  d.appendChild(makeSpan('# ' + desc, 'c-muted'));
  appendNode(d);
}

/** @param {string} key  @param {string} value */
function renderKV(key, value) {
  const d = makeDiv('kv-grid fi');
  d.appendChild(makeSpan(key + ':', 'c-amber'));
  d.appendChild(makeSpan(value, 'c-white'));
  appendNode(d);
}

/**
 * Structured card — title, date, multiline body. All textContent.
 * @param {string} title
 * @param {string} date
 * @param {string[]} bodyLines
 */
function renderCard(title, date, bodyLines) {
  const card  = makeDiv('card fi');
  const t     = makeDiv('card-title');  t.textContent = title; card.appendChild(t);
  const da    = makeDiv('card-date');   da.textContent = date;  card.appendChild(da);
  const body  = makeDiv('card-body');
  bodyLines.forEach((line, i) => {
    body.appendChild(document.createTextNode(line));
    if (i < bodyLines.length - 1) body.appendChild(document.createElement('br'));
  });
  card.appendChild(body);
  appendNode(card);
}

/** @param {string[]} lines */
function renderQuote(lines) {
  const q = makeDiv('quote-bar fi');
  lines.forEach((line, i) => {
    q.appendChild(document.createTextNode(line));
    if (i < lines.length - 1) q.appendChild(document.createElement('br'));
  });
  appendNode(q);
}

// ══════════════════════════════════════════════════════════════════════════════
// COMMAND REGISTRY
// ══════════════════════════════════════════════════════════════════════════════

// Whitelisted navigation targets — never constructed from user input
const NAV_TARGETS = Object.freeze({
  admin:    '/stats/xray',
});

const CMD_META = Object.freeze({
  help:     'list commands. help <cmd> for detail.',
  think:    'random thought on surveillance and control.',
  privacy:  'structured breakdown of the privacy contract you never signed.',
  hygiene:  'eight practical principles for the paranoid and rational alike.',
  manifest: 'what this site is. what it is not. why it exists.',
  clear:    'clear terminal output. also: ctrl+l.',
});

const CMD_DETAIL = Object.freeze({
  help:     ['Lists all public commands.', 'Usage: help <command> for per-command detail.'],
  think:    ['Outputs a randomly selected thought from a static dataset.', 'Topics: attention economy, surveillance, consent, metadata, impermanence.', 'Run multiple times — the selection is random.'],
  privacy:  ['Structured key-value breakdown:', '  the model — how prediction replaces understanding.', '  the trade — you are the inventory.', '  the drift — surveillance → infrastructure → invisible.', '  the math — breach economics.', '  the lie — the opt-out that was never meant to be used.'],
  hygiene:  ['numbered security principles.', 'Covers: passwords, disk encryption, DNS, identity separation,', 'permissions, 2FA, account hygiene, patch discipline.'],
  manifest: ["The site's statement of intent.", 'No tracking. No extraction. No compromise.'],
  clear:    ['Clears all terminal output.', 'Equivalent to ctrl+l.'],
});

/** @param {string} key */
function safeNavigate(key) {
  const target = NAV_TARGETS[key];
  if (typeof target === 'string' && target.startsWith('/')) {
    window.location.href = target;
  }
}

// Fixed command map — no dynamic dispatch, no eval
const COMMANDS = Object.freeze(/** @type {Record<string, (arg?: string) => void>} */ ({

  help(arg) {
    lineBlank();
    if (arg) {
      const detail = CMD_DETAIL[arg];
      if (detail) {
        lineText(arg, 'c-amber', 'bold');
        lineBlank();
        detail.forEach(l => lineText(l));
      } else {
        renderInline([
          { text: 'no help entry for: ', classes: ['c-muted'] },
          { text: arg,                   classes: ['c-white'] },
        ]);
      }
      lineBlank();
      return;
    }
    lineText('available commands', 'c-amber', 'bold');
    lineBlank();
    Object.entries(CMD_META).forEach(([cmd, desc]) => renderHelpRow(cmd, desc));
    lineBlank();
    lineText(' *your data stored somewhere outside your direct possession.', 'c-muted');
    lineBlank();
  },

  think: (() => {
    let lastIdx = -1;
    return function think() {
      lineBlank();
      let idx;
      do { idx = Math.floor(Math.random() * THOUGHTS.length); } while (idx === lastIdx && THOUGHTS.length > 1);
      lastIdx = idx;
      const t = THOUGHTS[idx];
      renderCard(t.title, t.date, t.body);
      lineBlank();
      lineText('run again for another thought. there are always more.', 'c-muted');
      lineBlank();
    };
  })(),

  privacy() {
    lineBlank();
    lineText('// on privacy', 'c-red', 'bold');
    lineBlank();
    renderQuote([
      'Privacy is not about having something to hide.',
      'It is about having something to protect.',
    ]);
    lineBlank();
    PRIVACY_KV.forEach(([k, v]) => renderKV(k, v));
    lineBlank();
  },

  hygiene() {
    lineBlank();
    lineText('// digital hygiene — minimal viable principles', 'c-green', 'bold');
    lineBlank();
    HYGIENE_LIST.forEach(([k, v]) => {
      lineText(k, 'c-amber', 'bold');
      lineText(v);
      lineBlank();
    });
  },

  manifest() {
    lineBlank();
    lineText('// manifest', 'c-red', 'bold');
    lineBlank();
    MANIFEST_LINES.forEach(l => { if (l === '') lineBlank(); else lineText(l); });
    lineBlank();
  },

  admin()    { safeNavigate('admin'); },
  clear()   { outputEl.textContent = ''; },

}));

// Tab-complete exposes only public commands
const PUBLIC_CMDS = Object.freeze(Object.keys(CMD_META));

// ══════════════════════════════════════════════════════════════════════════════
// INPUT HANDLING
// ══════════════════════════════════════════════════════════════════════════════

function handleEnter() {
  const raw = inputEl.value.trim();
  inputEl.value = '';
  State.histIdx = -1;
  if (!raw) return;
  if (State.history.length >= HIST_LIMIT) State.history.length = HIST_LIMIT - 1;
  State.history.unshift(raw);
  renderCmdEcho(raw);
  const parts = raw.toLowerCase().split(/\s+/);
  const name  = parts[0];
  const arg   = parts[1] || '';
  const fn    = COMMANDS[name];
  if (typeof fn === 'function') {
    fn(arg);
  } else {
    renderInline([
      { text: 'command not found: ', classes: ['c-red'] },
      { text: raw,                   classes: ['c-white'] },
    ]);
    lineText('type help for available commands.', 'c-muted');
    lineBlank();
  }
}

function handleArrowUp() {
  if (State.histIdx < State.history.length - 1) {
    State.histIdx++;
    inputEl.value = State.history[State.histIdx];
  }
}

function handleArrowDown() {
  if (State.histIdx > 0) {
    State.histIdx--;
    inputEl.value = State.history[State.histIdx];
  } else {
    State.histIdx = -1;
    inputEl.value = '';
  }
}

function handleTab() {
  const val   = inputEl.value.toLowerCase().trim();
  const match = PUBLIC_CMDS.filter(c => c.startsWith(val));
  if (match.length === 1) {
    inputEl.value = match[0];
  } else if (match.length > 1) {
    renderCmdEcho(inputEl.value);
    lineText(match.join('    '), 'c-muted');
  }
}

inputEl.addEventListener('keydown', function onKeyDown(e) {
  switch (e.key) {
    case 'Enter':    e.preventDefault(); handleEnter();    break;
    case 'ArrowUp':  e.preventDefault(); handleArrowUp();  break;
    case 'ArrowDown':e.preventDefault(); handleArrowDown();break;
    case 'Tab':      e.preventDefault(); handleTab();      break;
    case 'l':        if (e.ctrlKey) { e.preventDefault(); COMMANDS.clear(); } break;
  }
});

outputEl.addEventListener('click', function() {
  inputEl.focus({ preventScroll: true });
});

// ══════════════════════════════════════════════════════════════════════════════
// BOOT
// ══════════════════════════════════════════════════════════════════════════════
function lineDivider() {
  const d = document.createElement('div');
  d.className = 'divider fi';
  appendNode(d);
}


(function boot() {
  lineBlank();
  const logo = makeDiv('out-line fi');
  logo.style.fontSize = '2rem';
  logo.style.letterSpacing = '.08em';
  logo.style.lineHeight = '1';
  logo.textContent = 'ride life';
  logo.classList.add('c-muted', 'bold');
  appendNode(logo);
  lineText('2006–2026', 'c-muted');
  lineBlank();
  lineText('this site is about one thing:', 'c-muted');
  lineText('your data is somewhere you cannot reach it.', 'c-white');
  lineBlank();
  lineDivider();
  lineBlank();
  lineText('editorial snapshot - not a live scan', 'c-muted');
  renderKV('transport', 'TLS protects transit; endpoint access still matters.');
  renderKV('metadata', 'connections can expose identity, timing, and destination.');
  renderKV('cookies', 'tracking does not require meaningful consent.');
  renderKV('fingerprint', 'a browser can be identified without cookies.');
  renderKV('patching', 'unpatched software turns known flaws into active risk.');
  lineBlank();
  lineDivider();
  lineBlank();
  lineText('not a warning. a modern reality.', 'c-muted');
  lineBlank();
  renderInline([
    { text: 'type ',  classes: ['c-muted'] },
    { text: 'help',   classes: ['c-amber'] },
    { text: ' to begin.', classes: ['c-muted'] },
  ]);
  lineBlank();
  outputEl.classList.add('ready');
  outputEl.setAttribute('aria-live', 'polite');
  inputEl.focus({ preventScroll: true });
}());
