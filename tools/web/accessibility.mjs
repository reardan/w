// Opt-in semantic snapshot -> DOM mirror. No HTML parsing, canvas input hooks,
// or dependencies. The application paints focus and republishes after actions.
const roles = ['', 'document', 'group', '', 'heading', 'link', 'button',
  'checkbox', 'textbox', 'img', 'list', 'listitem', 'table', 'row', 'cell'];
const encoder = new TextEncoder();
let nextBridgeId = 0;
const integer = n => Number.isInteger(n) && n >= 0 && n <= 0x7fffffff;

export function createAccessibility({ document, container, canvas = null }) {
  let staging = null, current = null, queue = [], serial = 0, suppressFocus = false;
  let savedCanvas = null, queuedBytes = 0;
  const bridgeId = ++nextBridgeId;
  const fail = () => { if (staging) staging.failed = true; return 0; };
  const allowed = (n, action) => !n.inert && !!(n.actions & action) &&
    !(action === 4 && (n.states & 16));
  const request = (snapshot, n, action, value = '') => {
    if (current !== snapshot || suppressFocus || !allowed(n, action) || queue.length >= 64) return 0;
    const data = encoder.encode(value);
    if (data.length > snapshot.maxBytes - queuedBytes) return 0;
    queuedBytes += data.length;
    queue.push({ id: n.id, action, data });
    return 1;
  };
  return {
    begin(maxNodes, maxBytes, snapshot) {
      staging = null;
      // Hard caps protect a browser host from unbounded producer budgets.
      if (!integer(maxNodes) || maxNodes < 1 || maxNodes > 100000 ||
          !integer(maxBytes) || maxBytes > 16777216 || !integer(snapshot) || !snapshot) return 0;
      staging = { nodes: new Map(), root: null, maxNodes, maxBytes, snapshot,
        textBytes: 0, failed: false };
      return 1;
    },
    add(id, parent, role, states, actions, level) {
      const s = staging;
      if (!s || s.failed || !integer(id) || !id || !integer(parent) ||
          !integer(role) || role < 1 || role >= roles.length ||
          !integer(states) || states > 127 || !integer(actions) || actions > 15 ||
          !integer(level) || (role === 4 && (level < 1 || level > 6)) ||
          s.nodes.has(id) || s.nodes.size >= s.maxNodes) return fail();
      const p = s.nodes.get(parent);
      if ((parent && !p) || (!parent && s.root) || (p && p.role === 8)) return fail();
      const n = { id, parent, role, states, actions, level, text: ['', '', ''],
        inert: !!(states & 33) || !!p?.inert,
        hidden: !!(states & 32) || !!p?.hidden };
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
    fail,
    commit(focusedId) {
      const s = staging;
      staging = null;
      if (!s || s.failed || !s.root || !integer(focusedId)) return 0;
      const focused = s.nodes.get(focusedId);
      if (focusedId && (!focused || focused.inert || !(focused.states & 64) || !(focused.actions & 2))) return 0;
      const fragment = document.createElement('div');
      // Visually clipped, not display:none/visibility:hidden/aria-hidden: this
      // is the canvas's alternate reading/interaction surface, not an overlay.
      fragment.style.cssText = 'position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap;border:0';
      const generation = ++serial;
      for (const n of s.nodes.values()) {
        const el = document.createElement(n.role === 8 ? 'textarea' : 'div');
        n.element = el;
        if (roles[n.role]) el.setAttribute('role', roles[n.role]);
        if (n.role === 3) el.textContent = n.text[0];
        else if (n.text[0]) el.setAttribute('aria-label', n.text[0]);
        if (n.hidden) el.setAttribute('aria-hidden', 'true');
        if (n.inert) el.setAttribute('aria-disabled', 'true');
        if (n.role === 4) el.setAttribute('aria-level', String(n.level));
        if (n.role === 7) el.setAttribute('aria-checked', String(!!(n.states & 2)));
        if (n.role === 13 || n.role === 14) el.setAttribute('aria-selected', String(!!(n.states & 4)));
        if ((n.states & 8) && [5, 6, 7, 13].includes(n.role)) el.setAttribute('aria-expanded', 'true');
        if (n.role === 8) {
          el.value = n.text[1];
          el.readOnly = !!(n.states & 16) || !(n.actions & 4);
          el.disabled = n.inert;
          el.setAttribute('aria-multiline', 'true');
          el.setAttribute('aria-readonly', String(el.readOnly));
          el.addEventListener('input', e => { if (!e.isComposing) request(s, n, 4, el.value); });
        }
        if (!n.inert && (n.states & 64) && (n.actions & 2)) el.tabIndex = 0;
        else if (n.role === 8) el.tabIndex = -1;
        el.addEventListener('focus', () => request(s, n, 2));
        // Do not let a child's action bubble into an actionable ancestor.
        el.addEventListener('click', e => {
          if (e.target !== el) return;
          request(s, n, n.role === 7 ? 8 : 1);
        });
        el.addEventListener('keydown', e => {
          if (e.target !== el || e.repeat || n.role === 8) return;
          const action = n.role === 7 ? 8 : 1;
          if ((e.key === 'Enter' || (e.key === ' ' && n.role !== 5)) && allowed(n, action)) {
            e.preventDefault();
            request(s, n, action);
          }
        });
        const parent = n.parent ? s.nodes.get(n.parent).element : fragment;
        parent.appendChild(el);
        if (n.text[2]) {
          const help = document.createElement('span');
          help.id = `w-access-${bridgeId}-${generation}-${n.id}-help`;
          help.textContent = n.text[2];
          // Described-by text remains available without duplicate reading stops.
          help.hidden = true;
          el.setAttribute('aria-describedby', help.id);
          fragment.appendChild(help);
        }
      }
      if (canvas && !savedCanvas) {
        savedCanvas = { hidden: canvas.getAttribute('aria-hidden'), tab: canvas.getAttribute('tabindex') };
        canvas.setAttribute('aria-hidden', 'true');
        canvas.setAttribute('tabindex', '-1');
      }
      queue = [];
      queuedBytes = 0;
      current = s;
      container.replaceChildren(fragment);
      if (focused) {
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
