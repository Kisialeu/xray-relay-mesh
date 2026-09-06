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
// STATIC DATA
// ══════════════════════════════════════════════════════════════════════════════

const THOUGHTS = Object.freeze([
  {
    title: 'The update that wasn\'t optional',
    date:  '2025-03-10',
    body:  [
      'You hit Decline. It installed anyway.',
      'Reboot now. No snooze. No choice.',
      'Your hardware, their rules.',
      'Ownership is just a button they can hide.',
      'And they did.',
    ],
  },
  {
    title: 'The terms changed',
    date:  '2025-04-20',
    body:  [
      'An email arrived. You ignored it like always.',
      'Continued use = acceptance.',
      'You kept using it.',
      'The contract quietly rewrote itself while you slept.',
      'Now you’re legally fucked and didn’t even notice.',
    ],
  },
  {
    title: 'Signal and noise',
    date:  '2025-05-01',
    body:  [
      'You installed the “private” messenger.',
      'Your friends didn’t.',
      'A network is only as secure as its weakest, dumbest user.',
      'Congratulations. That’s you now.',
      'There are no islands. Only targets.',
    ],
  },
  {
    title: 'The backup',
    date:  '2025-05-10',
    body:  [
      '“Your photos are safe in the cloud.”',
      'Safe for who, exactly?',
      'Three continents, zero control.',
      'They own the copies. You own the illusion.',
      'Availability ≠ ownership, asshole.',
    ],
  },
  {
    title: 'Zero-click',
    date:  '2025-05-18',
    body:  [
      'You didn’t click anything suspicious.',
      'You didn’t click anything at all.',
      'Just existing online was enough.',
      'Your presence is the vulnerability.',
      'The attack surface is you.',
    ],
  },
  {
    title: 'The algorithm knows',
    date:  '2025-05-25',
    body:  [
      'You never searched for it.',
      'You just thought about it near your phone.',
      'Now the ad is staring you in the face.',
      '“Correlation, not causation,” they’ll lie.',
      'Your brain is already for sale.',
    ],
  },
  {
    title: 'Trust by default',
    date:  '2025-03-22',
    body:  [
      'The app asked for nothing.',
      'It just took everything it could reach.',
      'Permissions are a joke.',
      'What you don’t explicitly deny, they own.',
      'And you never deny shit.',
    ],
  },
  {
    title: 'The password you remember',
    date:  '2025-04-08',
    body:  [
      'Strong password. Twelve characters. Used everywhere.',
      'One of those sites got breached years ago.',
      'You were never told.',
      'Someone else was. They’ve been inside your accounts since.',
      'Sleep tight.',
    ],
  },
  {
    title: 'Encryption in transit',
    date:  '2025-04-15',
    body:  [
      'The little padlock means the pipe is sealed.',
      'Doesn’t mean shit about who reads it on the other end.',
      'Your message arrived perfectly.',
      'Straight into a database with no real deletion policy.',
      'End-to-end was always a marketing fairy tale.',
    ],
  },
  {
    title: 'Your attention is the product',
    date:  '2024-03-11',
    body:  [
      'Every scroll, every hesitation, every rage-click — logged.',
      'Not to help you. To hack you.',
      'The feed isn’t reality.',
      'It’s a weapon designed to keep you addicted and angry.',
      'You’re not the customer. You’re the livestock.',
    ],
  },
  {
    title: 'The illusion of private mode',
    date:  '2024-06-02',
    body:  [
      'Incognito mode is marketing bullshit.',
      'Your ISP sees you. Your DNS sees you.',
      'Every site fingerprints your exact device like a bloodhound.',
      'You’re not invisible. You’re just not locally logged.',
      'Big fucking difference.',
    ],
  },
  {
    title: 'Consent is a checkbox nobody reads',
    date:  '2024-08-19',
    body:  [
      '2,000 words of legalese in tiny font.',
      'Written so you won’t read it.',
      'You clicked Accept in 0.8 seconds.',
      'They knew you would.',
      'You’re not consenting. You’re surrendering.',
    ],
  },
  {
    title: 'Metadata is the message',
    date:  '2024-10-30',
    body:  [
      'They say “we don’t read your content.”',
      'They don’t need to.',
      'Who you talk to, when, how often, from where — that’s the real gold.',
      'Your entire social graph is worth more than your words.',
      'And it’s already sold.',
    ],
  },
  {
    title: 'On the permanence of digital acts',
    date:  '2025-01-07',
    body:  [
      'You deleted it.',
      'The cache didn’t. The backup didn’t. The replica in another country didn’t.',
      'Your “right to be forgotten” is a polite joke.',
      'Deletion is a request they can ignore.',
      'Once it’s out there, it’s forever.',
    ],
  },
  {
    title: 'The network is the panopticon',
    date:  '2025-02-28',
    body:  [
      'Bentham dreamed of a prison where you never know if you’re being watched.',
      'We built it willingly and called it connection.',
      'Now we carry the cells in our pockets.',
      'And we pay for the privilege.',
    ],
  },
  {
    title: 'The free tier',
    date:  '2025-04-01',
    body:  [
      'Nothing is free.',
      'You’re just paying with something they don’t show on the price tag.',
      'Your time. Your data. Your future behavior.',
      'The ledger always balances.',
      'You just never see the debit column.',
    ],
  },

  // New, harsher ones
  {
    title: 'You are the product. Full stop.',
    date:  '2025-06-05',
    body:  [
      'Stop pretending otherwise.',
      'You’re not using the service.',
      'The service is using you.',
      'Every breath you take online is harvested, profiled, and sold.',
      'Welcome to the attention economy, livestock.',
    ],
  },
  {
    title: 'They patched your freedom',
    date:  '2025-06-14',
    body:  [
      'That feature you loved? Gone in the latest update.',
      'The one that let you control your data? Disabled by default.',
      'They didn’t ask. They just decided what’s best for you.',
      'And what’s best for you is maximum extraction.',
    ],
  },
  {
  title: 'What actually helps',
  date:  '2025-08-02',
  body:  [
    'You’re not completely powerless.',
    'But the fixes aren’t convenient, and that’s the point.',
    'Unique passwords. Hardware keys. Less cloud, more local.',
    'You won’t do all of it.',
    'They’re counting on that.',
  ],
},
{
  title: 'Friction is security',
  date:  '2025-08-06',
  body:  [
    'Every extra step you hate is a barrier they have to cross.',
    'Security that feels smooth is usually security that’s been gutted.',
    'Yes, it’s annoying.',
    'That’s what makes it work.',
    'Convenience is the vulnerability.',
  ],
},
  {
    title: 'Your smartphone might be a snitch',
    date:  '2025-06-22',
    body:  [
      'It listens when you’re not talking to it.',
      'It watches when you’re not using it.',
      'You carry a traitor in your pocket every day.',
      'And you paid for it yourself.',
    ],
  },
  {
    title: 'Privacy is dead. You just didn’t attend the funeral.',
    date:  '2025-07-03',
    body:  [
      'It didn’t die in some dramatic hack.',
      'It died quietly, one “accept” button at a time.',
      'You helped kill it.',
      'Now you’re just pretending the corpse isn’t rotting next to you.',
    ],
  },
  {
    title: 'Two-factor exhaustion',
    date:  '2025-07-11',
    body:  [
      'Another code. Another device. Another “trust this browser?”',
      'You’re so tired of proving you’re you that you just click yes.',
      'That’s exactly when they strike.',
      'Security theater at its finest.',
    ],
  },
  {
    title: 'The cloud owns your life',
    date:  '2025-07-19',
    body:  [
      'All your memories, documents, photos — sitting on someone else’s servers.',
      'One lawsuit, one bankruptcy, one policy change away from disappearing.',
      'Or worse — from being handed to whoever pays more.',
      'You don’t have files anymore.',
      'You have subscriptions to your own data.',
    ],
  },
  {
    title: 'You consented. Forever.',
    date:  '2025-07-28',
    body:  [
      'That one click years ago still binds you.',
      'They can change the terms whenever they want.',
      'You can leave… but good luck untangling your entire digital life.',
      'You’re not a user. You’re property with a login.',
    ],
  },
]);

const PRIVACY_KV = Object.freeze([
  ['the model', "every service builds a statistical model of you. not to understand you — to predict you. a predicted person is a profitable person."],
  ['the trade', "you pay with attention, behavior, and identity. the service is free because you are the inventory."],
  ['the drift', "surveillance becomes infrastructure. infrastructure becomes invisible. invisible things are never questioned."],
  ['the math',  "one breach. millions of records. zero accountability. your data, someone else's liability, nobody's responsibility."],
  ['the lie',   "you were told you could opt out. the opt-out is buried in a settings menu designed to be abandoned."],
]);

const HYGIENE_LIST = Object.freeze([
  ['01 — password manager',       "not reusing passwords is table stakes. a unique 32-char random string per service costs you nothing except the illusion of memorability."],
  ['02 — encrypt your disk',      "full-disk encryption is free on every modern OS. an unencrypted laptop is an open filing cabinet left on a bus."],
  ['03 — DNS over HTTPS',         "your DNS queries are a map of your interests. stop sending them in plaintext to your ISP, who sells them."],
  ['04 — separate identities',    "work email ≠ personal email ≠ throwaway. compartmentalization limits blast radius when one burns."],
  ['05 — audit permissions',      "does the flashlight app need your contacts? no. revoke what was never justified. do it now, not later."],
  ['06 — 2FA everywhere',         "TOTP > SMS. hardware key > TOTP. a stolen password without a second factor is noise. make yourself noise."],
  ['07 — delete dormant accounts',"dormant accounts are attack surface you forgot you had. close them. request deletion. shrink your footprint."],
  ['08 — update, always',         "unpatched software is an unlocked door. attackers know which CVEs are unpatched. they have scripts."],
]);

const MANIFEST_LINES = Object.freeze([
  'This site does not track you.',
  'No analytics. No cookies. No pixel. No CDN beacon.',
  'You arrived. You read. You left.',
  'That is how it should work.',
  '',
  'We build systems that remember everything',
  'for people who want to forget nothing —',
  'and then we are surprised when memory',
  'becomes a weapon.',
  '',
  'The network was designed to survive a nuclear strike.',
  'It was not designed to protect a person.',
  'That gap is where the industry lives.',
  '',
  'Convenience is the anesthetic.',
  'You do not feel the extraction',
  'because the interface is smooth',
  'and the product is pleasant',
  'and the alternative requires effort.',
  '',
  'Effort is the price of autonomy.',
  'Nobody told you that either.',
  '',
  '— ride life, 2006–2026',
]);

// ══════════════════════════════════════════════════════════════════════════════
// COMMAND REGISTRY
// ══════════════════════════════════════════════════════════════════════════════

// Whitelisted navigation targets — never constructed from user input
const NAV_TARGETS = Object.freeze({
  archive: '/archive',
  blog:    '/archive',
  admin:   '/admin/sys',
  stats:   '/admin/stats',
  xray:    '/stats/xray',
});

const CMD_META = Object.freeze({
  help:     'list commands. help <cmd> for detail.',
  think:    'random thought on surveillance and control.',
  privacy:  'structured breakdown of the privacy contract you never signed.',
  hygiene:  'eight practical principles for the paranoid and rational alike.',
  manifest: 'what this site is. what it is not. why it exists.',
  archive:  'navigate to /archive.',
  clear:    'clear terminal output. also: ctrl+l.',
});

const CMD_DETAIL = Object.freeze({
  help:     ['Lists all public commands.', 'Usage: help <command> for per-command detail.'],
  think:    ['Outputs a randomly selected thought from a static dataset.', 'Topics: attention economy, surveillance, consent, metadata, impermanence.', 'Run multiple times — the selection is random.'],
  privacy:  ['Structured key-value breakdown:', '  the model — how prediction replaces understanding.', '  the trade — you are the inventory.', '  the drift — surveillance → infrastructure → invisible.', '  the math — breach economics.', '  the lie — the opt-out that was never meant to be used.'],
  hygiene:  ['numbered security principles.', 'Covers: passwords, disk encryption, DNS, identity separation,', 'permissions, 2FA, account hygiene, patch discipline.'],
  manifest: ["The site's statement of intent.", 'No tracking. No extraction. No compromise.'],
  archive:  ['Navigates to /archive.'],
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

  archive() { safeNavigate('archive'); },
  blog()    { safeNavigate('blog'); },
  admin()   { safeNavigate('admin'); },
  stats()   { safeNavigate('stats'); },
  xray()    { safeNavigate('xray'); },
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

document.addEventListener('click', function() {
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
  lineBlank();
  lineBlank();
  lineBlank();
  lineBlank();
  lineBlank();
  lineText('this site is about one thing:', 'c-muted');
  lineText('your data is somewhere you cannot reach it.', 'c-white');
  lineBlank();
lineDivider();
lineBlank();
lineText('TLS 1.3', 'c-amber');
  lineText('post-quantum key exchange: none', 'c-red');
    lineBlank();
    lineBlank();
lineText('connection: ', 'c-amber');
lineText('logged by 3 parties you never chose', 'c-red');
  lineBlank();
    lineBlank();
lineText('cookies: ', 'c-amber');
lineText('set on 73% of sites before first click', 'c-red');
  lineBlank();
    lineBlank();
lineText('this session:', 'c-amber');
lineText('already fingerprinted', 'c-red');
  lineBlank();
    lineBlank();
lineText('CVEs (2025):', 'c-amber');
lineText('40,000+ published. patch rate: unknown', 'c-red');
lineBlank();
lineDivider();
  lineBlank();
  lineBlank();
  lineText('not a warning. a modern reality.', 'c-muted');
  lineBlank();
  renderInline([
    { text: 'type ',  classes: ['c-muted'] },
    { text: 'help',   classes: ['c-amber'] },
    { text: ' to begin.', classes: ['c-muted'] },
  ]);
  lineBlank();
}());
