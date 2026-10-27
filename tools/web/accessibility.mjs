// Opt-in semantic snapshot -> DOM mirror. No HTML parsing, canvas input hooks,
// or dependencies. The application paints focus and republishes after actions.
const roles = ['', 'document', 'group', '', 'heading', 'link', 'button',
  'checkbox', 'textbox', 'img', 'list', 'listitem', 'table', 'row', 'cell',
  'radio', 'switch', 'combobox', 'tablist', 'tab', 'progressbar', 'dialog'];
// Toggle when the node supports it (checkboxes, switches), else activate.
const pressAction = n => (n.actions & 8) ? 8 : 1;
const encoder = new TextEncoder();
let nextBridgeId = 0;
const integer = n => Number.isInteger(n) && n >= 0 && n <= 0x7fffffff;
// Snapshot offsets count code points; the DOM's count UTF-16 units.
const step = (text, i) => (text.codePointAt(i) > 0xffff ? 2 : 1);
const toUnits = (text, chars) => {
  let i = 0;
  for (let k = 0; k < chars && i < text.length; k++) i += step(text, i);
  return i;
};
const toChars = (text, units) => {
  let k = 0;
  for (let i = 0; i < units && i < text.length; k++) i += step(text, i);
  return k;
};

const politeness = ['', 'polite', 'assertive'];
const clipped = 'position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap;border:0';

// Set or (value === null) remove an attribute, touching the DOM only on change.
const attr = (el, name, value) => {
  if (value === null) { if (el.getAttribute(name) !== null) el.removeAttribute(name); }
  else if (el.getAttribute(name) !== String(value)) el.setAttribute(name, value);
};

// What a live region announces for node n given its previous version (as
// graphics/ui/accessibility.w's ui_access_live_change): its name when new or
// renamed, else a changed non-textbox value.
const liveChange = (n, was) => {
  if (!n.liveRoot || n.hidden) return null;
  if (!was || n.text[0] !== was.text[0]) {
    if (n.text[0]) return { text: n.text[0], field: 0 };
    if (!was) return null;
  }
  if (was && n.role !== 8 && n.text[1] && n.text[1] !== was.text[1]) return { text: n.text[1], field: 1 };
  return null;
};

export function createAccessibility({ document, container, canvas = null }) {
  let staging = null, current = null, queue = [], suppressFocus = false;
  let savedCanvas = null, queuedBytes = 0;
  // One DOM element per node id, kept across publications and updated in
  // place, so focus, text selection and IME composition in a textarea survive
  // a republish. The surface holds the root element, the described-by texts
  // and two visually hidden live regions for announcements.
  let surface = null, descriptions = null, regions = null, flip = false;
  let records = new Map();
  const bridgeId = ++nextBridgeId;
  const fail = () => { if (staging) staging.failed = true; return 0; };
  const allowed = (n, action) => !n.inert && !!(n.actions & action) &&
    !(action === 4 && (n.states & 16));
  const request = (rec, action, value = '') => {
    const n = rec.node, snapshot = current;
    if (rec.dead || !snapshot || suppressFocus || !allowed(n, action) || queue.length >= 64) return 0;
    const data = encoder.encode(value);
    if (data.length > snapshot.maxBytes - queuedBytes) return 0;
    queuedBytes += data.length;
    queue.push({ id: n.id, action, data });
    return 1;
  };
  const create = tag => {
    const el = document.createElement(tag);
    const rec = { el, tag, node: null, help: null, dead: false, composing: false };
    el.addEventListener('focus', () => request(rec, 2));
    // Do not let a child's action bubble into an actionable ancestor.
    el.addEventListener('click', e => {
      if (e.target !== el) return;
      request(rec, pressAction(rec.node));
    });
    el.addEventListener('keydown', e => {
      const n = rec.node;
      if (e.target !== el || e.repeat || n.role === 8) return;
      const action = pressAction(n);
      if ((e.key === 'Enter' || (e.key === ' ' && n.role !== 5)) && allowed(n, action) && !rec.dead) {
        e.preventDefault();
        request(rec, action);
      }
    });
    if (tag === 'textarea') {
      // The caret and selection as [anchor, active] in code points:
      // published ones are not echoed back (rec.sent), user moves are
      // queued (after the edit that caused them, when there was one).
      const select = () => {
        const n = rec.node;
        if (rec.dead || rec.composing || !(n.actions & 16) || typeof el.selectionStart !== 'number') return;
        const text = el.value;
        let anchor = toChars(text, el.selectionStart), active = toChars(text, el.selectionEnd);
        if (el.selectionDirection === 'backward') [anchor, active] = [active, anchor];
        if (rec.sent && rec.sent[0] === anchor && rec.sent[1] === active) return;
        if (request(rec, 16, `${anchor} ${active}`)) rec.sent = [anchor, active];
      };
      el.addEventListener('input', e => {
        if (e.isComposing || rec.composing) return;
        request(rec, 4, el.value);
        select();
      });
      // A composition commits at compositionend: Chromium's last input event
      // of a composition still reports isComposing.
      el.addEventListener('compositionstart', () => { rec.composing = true; });
      el.addEventListener('compositionend', () => {
        rec.composing = false;
        request(rec, 4, el.value);
        select();
      });
      for (const name of ['select', 'selectionchange', 'keyup', 'mouseup']) el.addEventListener(name, select);
    }
    return rec;
  };
  const retire = rec => {
    rec.dead = true;
    rec.el.parentNode?.removeChild(rec.el);
    rec.help?.parentNode?.removeChild(rec.help);
  };
  const update = (rec, n) => {
    const el = rec.el;
    attr(el, 'role', roles[n.role] || null);
    if (n.role === 3 || n.role === 17) {
      // Plain text and a select-only combobox's value are text content.
      const text = n.role === 3 ? n.text[0] : n.text[1];
      if (el.textContent !== text) el.textContent = text;
    }
    attr(el, 'aria-label', n.role !== 3 && n.text[0] ? n.text[0] : null);
    attr(el, 'aria-valuetext', n.role === 20 && n.text[1] ? n.text[1] : null);
    attr(el, 'aria-modal', n.role === 21 ? 'true' : null);
    attr(el, 'aria-hidden', n.hidden ? 'true' : null);
    attr(el, 'aria-disabled', n.inert ? 'true' : null);
    attr(el, 'aria-level', n.role === 4 ? String(n.level) : null);
    attr(el, 'aria-checked', [7, 15, 16].includes(n.role) ? String(!!(n.states & 2)) : null);
    attr(el, 'aria-selected', [13, 14, 19].includes(n.role) ? String(!!(n.states & 4)) : null);
    attr(el, 'aria-expanded', n.role === 17 ? String(!!(n.states & 8)) :
      ((n.states & 8) && [5, 6, 7, 13].includes(n.role)) ? 'true' : null);
    attr(el, 'aria-live', n.live ? politeness[n.live] : null);
    attr(el, 'aria-atomic', n.live ? 'true' : null);
    if (n.role === 8) {
      // Only a real change is written: assigning value moves the caret and
      // would cancel an IME composition in progress.
      if (!rec.composing && el.value !== n.text[1]) el.value = n.text[1];
      el.readOnly = !!(n.states & 16) || !(n.actions & 4);
      el.disabled = n.inert;
      attr(el, 'aria-multiline', 'true');
      attr(el, 'aria-readonly', String(el.readOnly));
    }
    if (!n.inert && (n.states & 64) && (n.actions & 2)) { if (el.tabIndex !== 0) el.tabIndex = 0; }
    else if (n.role === 8) { if (el.tabIndex !== -1) el.tabIndex = -1; }
    else if (el.tabIndex === 0) { el.removeAttribute('tabindex'); if (el.tabIndex === 0) el.tabIndex = -1; }
    if (n.text[2]) {
      if (!rec.help) {
        rec.help = document.createElement('span');
        rec.help.id = `w-access-${bridgeId}-${n.id}-help`;
      }
      if (rec.help.textContent !== n.text[2]) rec.help.textContent = n.text[2];
      // Described-by text remains available without duplicate reading stops.
      if (rec.help.parentNode !== descriptions) descriptions.appendChild(rec.help);
      attr(el, 'aria-describedby', rec.help.id);
    } else {
      rec.help?.parentNode?.removeChild(rec.help);
      rec.help = null;
      attr(el, 'aria-describedby', null);
    }
  };
  // Put exactly want, in order, under parent. Only out-of-place children
  // move, so a focused element stays put unless its own position changed.
  const arrange = (parent, want) => {
    for (let i = 0; i < want.length; i++) {
      const at = parent.children[i];
      if (at !== want[i]) parent.insertBefore(want[i], at ?? null);
    }
    while (parent.children.length > want.length) parent.removeChild(parent.children[want.length]);
  };
  // Write to the hidden live region of that politeness. A trailing no-break
  // space alternates, so repeating the same text is still a change.
  const say = (texts, live) => {
    if (!texts.length) return;
    flip = !flip;
    regions[live - 1].textContent = texts.join(' ') + (flip ? ' ' : '');
  };
  return {
    begin(maxNodes, maxBytes, snapshot) {
      staging = null;
      // Hard caps protect a browser host from unbounded producer budgets.
      if (!integer(maxNodes) || maxNodes < 1 || maxNodes > 100000 ||
          !integer(maxBytes) || maxBytes > 16777216 || !integer(snapshot) || !snapshot) return 0;
      staging = { nodes: new Map(), root: null, maxNodes, maxBytes, snapshot,
        textBytes: 0, failed: false, announcement: null };
      return 1;
    },
    add(id, parent, role, states, actions, level, live = 0) {
      const s = staging;
      if (!s || s.failed || !integer(id) || !id || !integer(parent) ||
          !integer(role) || role < 1 || role >= roles.length ||
          !integer(states) || states > 127 || !integer(actions) || actions > 31 ||
          !integer(level) || (role === 4 && (level < 1 || level > 6)) ||
          !integer(live) || live > 2 ||
          s.nodes.has(id) || s.nodes.size >= s.maxNodes) return fail();
      const p = s.nodes.get(parent);
      if ((parent && !p) || (!parent && s.root) || (p && p.role === 8)) return fail();
      const n = { id, parent, role, states, actions, level, live, text: ['', '', ''],
        inert: !!(states & 33) || !!p?.inert,
        hidden: !!(states & 32) || !!p?.hidden };
      n.liveRoot = live ? n : (p?.liveRoot ?? null);
      s.nodes.set(id, n);
      if (!parent) s.root = n;
      return 1;
    },
    text(id, field, value) {
      const s = staging, n = s?.nodes.get(id);
      if (!s || s.failed || !n || !integer(field) || field < 1 || field > 3 || typeof value !== 'string') return fail();
      const total = s.textBytes - encoder.encode(n.text[field - 1]).length + encoder.encode(value).length;
      if (total > s.maxBytes) return fail();
      n.text[field - 1] = value;
      s.textBytes = total;
      return 1;
    },
    // caret is one end of [start, end]; the other is the anchor.
    selection(id, caret, start, end) {
      const s = staging, n = s?.nodes.get(id);
      if (!s || s.failed || !n || ![caret, start, end].every(integer) || start > end ||
          (caret !== start && caret !== end) || end > [...n.text[1]].length) return fail();
      n.selection = [caret === start ? end : start, caret];
      return 1;
    },
    // A one-shot announcement, spoken when this publication commits.
    announce(value, live) {
      const s = staging;
      if (!s || s.failed || typeof value !== 'string' || !value || (live !== 1 && live !== 2) ||
          encoder.encode(value).length > s.maxBytes) return fail();
      s.announcement = { text: value, live };
      return 1;
    },
    fail,
    commit(focusedId) {
      const s = staging;
      staging = null;
      if (!s || s.failed || !s.root || !integer(focusedId)) return 0;
      const focused = s.nodes.get(focusedId);
      if (focusedId && (!focused || focused.inert || !(focused.states & 64) || !(focused.actions & 2))) return 0;
      if (!surface) {
        // Visually clipped, not display:none/visibility:hidden/aria-hidden: this
        // is the canvas's alternate reading/interaction surface, not an overlay.
        surface = document.createElement('div');
        surface.style.cssText = clipped;
        descriptions = document.createElement('div');
        descriptions.hidden = true;
        regions = [1, 2].map(live => {
          const region = document.createElement('div');
          region.setAttribute('aria-live', politeness[live]);
          region.setAttribute('aria-atomic', 'true');
          return region;
        });
        container.replaceChildren(surface);
      }
      // As on the native bridges, content present at the first publication
      // is not announced.
      const announcing = current !== null;
      const next = new Map(), fresh = new Set(), spoken = [[], []];
      for (const n of s.nodes.values()) {
        let rec = records.get(n.id);
        const tag = n.role === 8 ? 'textarea' : 'div';
        if (rec && rec.tag !== tag) { retire(rec); rec = null; }
        if (!rec) { rec = create(tag); fresh.add(n.id); }
        const was = fresh.has(n.id) ? null : rec.node;
        rec.node = n;
        n.element = rec.el;
        update(rec, n);
        next.set(n.id, rec);
        const said = announcing ? liveChange(n, was) : null;
        // The browser itself announces text-content changes inside a live
        // region it already knows. A region that just appeared, and names or
        // values held in attributes, go through the hidden regions instead.
        if (said && (fresh.has(n.liveRoot.id) || n.role !== 3 || said.field !== 0)) spoken[n.liveRoot.live - 1].push(said.text);
      }
      for (const [id, rec] of records) if (next.get(id) !== rec) retire(rec);
      records = next;
      const children = new Map();
      for (const n of s.nodes.values()) {
        if (!n.parent) continue;
        const parent = s.nodes.get(n.parent).element;
        if (!children.has(parent)) children.set(parent, []);
        children.get(parent).push(n.element);
      }
      for (const rec of records.values()) if (rec.tag !== 'textarea') arrange(rec.el, children.get(rec.el) ?? []);
      arrange(surface, [s.root.element, descriptions, ...regions]);
      // The published caret and selection, written only when the textarea's
      // differs (and never during a composition), so a republish does not
      // disturb a user's selection that the model already reflects.
      for (const n of s.nodes.values()) {
        if (n.role !== 8) continue;
        const rec = records.get(n.id), el = rec.el;
        rec.sent = n.selection;
        if (!n.selection || rec.composing) continue;
        const [anchor, active] = n.selection, text = el.value;
        const start = toUnits(text, Math.min(anchor, active)), end = toUnits(text, Math.max(anchor, active));
        const direction = active < anchor ? 'backward' : 'forward';
        if (el.selectionStart !== start || el.selectionEnd !== end || (start !== end && el.selectionDirection !== direction))
          el.setSelectionRange(start, end, direction);
      }
      if (s.announcement) spoken[s.announcement.live - 1].push(s.announcement.text);
      say(spoken[0], 1);
      say(spoken[1], 2);
      if (canvas && !savedCanvas) {
        savedCanvas = { hidden: canvas.getAttribute('aria-hidden'), tab: canvas.getAttribute('tabindex') };
        canvas.setAttribute('aria-hidden', 'true');
        canvas.setAttribute('tabindex', '-1');
      }
      queue = [];
      queuedBytes = 0;
      current = s;
      if (focused && document.activeElement !== focused.element) {
        suppressFocus = true;
        try { focused.element.focus({ preventScroll: true }); }
        finally { suppressFocus = false; }
      }
      return 1;
    },
    next(snapshot, capacity) {
      if (!current || current.snapshot !== snapshot || !integer(capacity) || !queue.length) return null;
      if (queue[0].data.length > capacity) return null; // Retry with a larger buffer.
      const event = queue.shift();
      queuedBytes -= event.data.length;
      return event;
    },
    close() {
      current = staging = null;
      queue = [];
      queuedBytes = 0;
      for (const rec of records.values()) rec.dead = true;
      records = new Map();
      surface = descriptions = regions = null;
      container.replaceChildren();
      if (canvas && savedCanvas) {
        for (const [name, value] of [['aria-hidden', savedCanvas.hidden], ['tabindex', savedCanvas.tab]]) {
          if (value === null) canvas.removeAttribute(name); else canvas.setAttribute(name, value);
        }
        savedCanvas = null;
      }
    },
  };
}

// Explicit-length UTF-8 plus a fixed three-i32 action header. Never retain a
// memory view across calls: W allocations can grow/detach wasm linear memory.
export function makeAccessibilityEnv({ memory, access }) {
  const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
  const valid = (ptr, length) => integer(ptr) && integer(length) &&
    (ptr !== 0 || length === 0) && ptr <= memory().buffer.byteLength - length;
  return {
    gfx_access_begin: (...args) => access?.begin(...args) ?? 0,
    gfx_access_add: (...args) => access?.add(...args) ?? 0,
    gfx_access_text: (id, field, ptr, length) => {
      if (!access) return 0;
      if (!valid(ptr, length)) return access.fail();
      try { return access.text(id, field, decoder.decode(new Uint8Array(memory().buffer, ptr, length))); }
      catch { return access.fail(); }
    },
    gfx_access_selection: (...args) => access?.selection(...args) ?? 0,
    gfx_access_announce: (ptr, length, live) => {
      if (!access) return 0;
      if (!valid(ptr, length)) return access.fail();
      try { return access.announce(decoder.decode(new Uint8Array(memory().buffer, ptr, length)), live); }
      catch { return access.fail(); }
    },
    gfx_access_commit: id => access?.commit(id) ?? 0,
    gfx_access_next: (snapshot, metadata, ptr, capacity) => {
      if (!access || !valid(metadata, 12) || !valid(ptr, capacity) ||
          (capacity > 0 && ptr < metadata + 12 && metadata < ptr + capacity)) return 0;
      const event = access.next(snapshot, capacity);
      if (!event) return 0;
      const view = new DataView(memory().buffer);
      new Uint8Array(memory().buffer, ptr, event.data.length).set(event.data);
      view.setInt32(metadata, event.id, true);
      view.setInt32(metadata + 4, event.action, true);
      view.setInt32(metadata + 8, event.data.length, true);
      return 1;
    },
    gfx_access_close: () => access?.close(),
  };
}
