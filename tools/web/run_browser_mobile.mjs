// Opt-in real-browser check of tools/web/index.html on an emulated phone.
// Usage:
//   ./wbuild graphics_ui_mobile_web
//   node tools/web/run_browser_mobile.mjs bin/graphics_ui_mobile.wasm [screenshot.png]
//
// Serves the repository root on a free loopback port with node:http, starts
// headless Chromium ($CHROMIUM, else chromium/chromium-browser/google-chrome
// on PATH or /snap/bin/chromium) and drives it over the DevTools protocol:
// a 412x764 CSS-pixel viewport at device pixel ratio 1.75 with touch. It
// checks layout overflow, the DPR backing store and GL viewport, touch tap
// and pan translation, soft-keyboard text (including Android's keyCode 229
// keydown), IME composition, and an orientation change, all through the
// compiled W form. No npm dependencies (Node 22's built-in WebSocket).
// Exits 0 with "SKIP" when no Chromium is installed.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { existsSync, mkdirSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, resolve, extname, sep } from 'node:path';

const wasmPath = process.argv[2] ?? 'bin/graphics_ui_mobile.wasm';
const shotPath = process.argv[3];
const root = resolve('.');
const which = name => {
  try { return execFileSync('sh', ['-c', `command -v ${name}`]).toString().trim() || null; }
  catch { return null; }
};
const chromium = process.env.CHROMIUM ?? which('chromium') ?? which('chromium-browser') ??
  which('google-chrome') ?? (existsSync('/snap/bin/chromium') ? '/snap/bin/chromium' : null);
if (!chromium) { console.log('run_browser_mobile SKIP (no Chromium; set CHROMIUM)'); process.exit(0); }
if (typeof WebSocket !== 'function') throw new Error('Node 22+ (global WebSocket) required');

// ------------------------------ static server ------------------------------
const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript',
  '.wasm': 'application/wasm', '.json': 'application/json' };
const server = createServer(async (req, res) => {
  const pathname = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  const path = resolve(root, '.' + pathname);
  const file = pathname.endsWith('/') ? join(path, 'index.html') : path;
  if (!file.startsWith(root + sep)) { res.writeHead(403); res.end(); return; }
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' });
    res.end(body);
  } catch { res.writeHead(404); res.end(); }
});
await new Promise(ok => server.listen(0, '127.0.0.1', ok));
const origin = `http://127.0.0.1:${server.address().port}`;

// --------------------------------- browser ---------------------------------
// A snap-confined Chromium cannot see the host /tmp or dot-directories.
const profileBase = chromium.startsWith('/snap/') ? join(homedir(), 'snap', 'chromium', 'common') : tmpdir();
mkdirSync(profileBase, { recursive: true });
const profile = await mkdtemp(join(profileBase, 'w-web-mobile-'));
const browser = spawn(chromium, ['--headless=new', '--remote-debugging-port=0',
  `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check',
  '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist',
  'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
let stderr = '';
const wsUrl = await new Promise((ok, fail) => {
  const timer = setTimeout(() => fail(new Error(`no DevTools endpoint:\n${stderr}`)), 30000);
  browser.stderr.on('data', chunk => {
    stderr += chunk;
    const m = /DevTools listening on (ws:\/\/\S+)/.exec(stderr);
    if (m) { clearTimeout(timer); ok(m[1]); }
  });
  browser.on('exit', code => fail(new Error(`chromium exited ${code}:\n${stderr}`)));
});
const cleanup = async () => {
  browser.kill('SIGKILL');
  server.close();
  await rm(profile, { recursive: true, force: true }).catch(() => {});
};

const ws = new WebSocket(wsUrl);
await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = fail; });
let nextId = 1;
const pending = new Map();
const consoleLines = [];
ws.onmessage = ({ data }) => {
  const msg = JSON.parse(data);
  if (msg.id && pending.has(msg.id)) {
    const { ok, fail } = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) fail(new Error(`${msg.error.message} ${msg.error.data ?? ''}`)); else ok(msg.result);
  } else if (msg.method === 'Runtime.exceptionThrown') {
    consoleLines.push(`exception: ${msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text}`);
  } else if (msg.method === 'Runtime.consoleAPICalled') {
    consoleLines.push(msg.params.args.map(a => a.value ?? a.description).join(' '));
  }
};
let sessionId;
const send = (method, params = {}) => new Promise((ok, fail) => {
  const id = nextId++;
  pending.set(id, { ok, fail });
  ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
});
const evaluate = async expression => {
  const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(`${expression}: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
  return r.result.value;
};
const sleep = ms => new Promise(ok => setTimeout(ok, ms));
// Headless rAF runs at display rate; wait for whole W frames, not wall time.
const frames = async (n = 3) => {
  const start = await evaluate('window.__w.frames');
  for (let i = 0; i < 200; i++) {
    if (await evaluate('window.__w.frames') >= start + n) return;
    await sleep(10);
  }
  throw new Error(`W frame loop stalled\n${consoleLines.join('\n')}`);
};

// Observe the page's real host ABI without changing index.html: wrap the env
// imports at instantiation to count frames and record the event stream and
// the W-reported text field. Memory reads mirror run_mobile_ui.mjs.
const probe = `(() => {
  const w = window.__w = { frames: 0, events: [], textInput: null, width: 0, height: 0 };
  const instantiate = WebAssembly.instantiate;
  WebAssembly.instantiate = async (mod, imports) => {
    const env = imports.env;
    const poll = env.gfx_host_poll_state, next = env.gfx_host_next_event, text = env.gfx_host_text_input;
    env.gfx_host_poll_state = ptr => {
      poll(ptr); w.frames++;
      const v = new Int32Array(w.instance.exports.memory.buffer, ptr, 2);
      w.width = v[0]; w.height = v[1];
    };
    env.gfx_host_next_event = ptr => {
      const got = next(ptr);
      if (got) w.events.push(Array.from(new Int32Array(w.instance.exports.memory.buffer, ptr, 5)));
      return got;
    };
    env.gfx_host_text_input = (...args) => { w.textInput = args; return text(...args); };
    const result = await instantiate(mod, imports);
    w.instance = result.instance ?? result;
    return result;
  };
  w.contains = s => {
    const hay = new Uint8Array(w.instance.exports.memory.buffer);
    const needle = new TextEncoder().encode(s + '\\0');
    outer: for (let i = 0; i + needle.length <= hay.length; i++) {
      for (let j = 0; j < needle.length; j++) if (hay[i + j] !== needle[j]) continue outer;
      return true;
    }
    return false;
  };
})()`;

const KIND = { CHAR: 3, DOWN: 4, UP: 5, SCROLL_PIXELS: 8, CANCEL: 9 };
let passed = 0;
const check = (cond, message) => { assert.ok(cond, message); passed++; };
try {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  ({ sessionId } = await send('Target.attachToTarget', { targetId, flatten: true }));
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Emulation.setDeviceMetricsOverride',
    { width: 412, height: 764, deviceScaleFactor: 1.75, mobile: true });
  await send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
  await send('Page.addScriptToEvaluateOnNewDocument', { source: probe });
  await send('Page.navigate', { url: `${origin}/tools/web/?module=/${wasmPath}` });
  for (let i = 0; i < 500 && !(await evaluate('!!(window.__w && window.__w.frames > 2)').catch(() => false)); i++)
    await sleep(20);
  await frames(2);

  // Layout: the page fits the phone, the canvas uses DPR-sized storage.
  const layout = await evaluate(`(() => {
    const c = document.getElementById('canvas'), r = c.getBoundingClientRect();
    const gl = c.getContext('webgl2');
    return { inner: innerWidth, dpr: devicePixelRatio, scrollW: document.documentElement.scrollWidth,
      bodyW: document.body.scrollWidth, css: [r.left, r.top, r.width, r.height], buffer: [c.width, c.height],
      viewport: Array.from(gl.getParameter(gl.VIEWPORT)), w: [__w.width, __w.height],
      log: document.getElementById('log').textContent };
  })()`);
  check(layout.inner === 412 && layout.dpr === 1.75, `emulated phone viewport: ${JSON.stringify(layout)}`);
  check(layout.scrollW <= layout.inner && layout.bodyW <= layout.inner, `no horizontal overflow: ${JSON.stringify(layout)}`);
  check(layout.css[0] >= 0 && layout.css[0] + layout.css[2] <= 412, 'canvas inside viewport');
  check(layout.css[2] === 412 && layout.css[3] === 720, `canvas clamped to the phone width: ${layout.css}`);
  check(layout.buffer[0] === Math.round(412 * 1.75) && layout.buffer[1] === Math.round(720 * 1.75),
    `backing store scaled by DPR: ${layout.buffer}`);
  check(layout.w[0] === 412 && layout.w[1] === 720, `W polls logical size: ${layout.w}`);
  check(layout.viewport[2] === layout.buffer[0] && layout.viewport[3] === layout.buffer[1],
    `GL viewport covers device pixels: ${layout.viewport}`);
  const [left, top] = layout.css;

  // A tap on the Name field: MOUSE_DOWN/UP at logical canvas coordinates,
  // then the DOM sink takes focus on release so the soft keyboard opens.
  const tap = async (x, y) => {
    await send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: left + x, y: top + y }] });
    await send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await frames(3);
  };
  await evaluate('__w.events.length = 0');
  await tap(30, 150);
  let events = await evaluate('__w.events');
  const down = events.find(e => e[0] === KIND.DOWN), up = events.find(e => e[0] === KIND.UP);
  check(down && up && down[1] === 1 && up[1] === 1, `tap emits button-1 down/up: ${JSON.stringify(events)}`);
  check(down[2] === 30 && down[3] === 150, `tap uses logical canvas coordinates: ${down}`);
  check(await evaluate('document.activeElement && document.activeElement.id') === 'text-input',
    'tap on a W textbox focuses the soft-keyboard sink');
  const field = await evaluate('__w.textInput');
  check(field[0] === 1 && field[1] === 0 && field[6] > 0, `W published its focused field: ${field}`);

  // Soft keyboard commits (Input.insertText is the IME commit path), then
  // Android Gboard's shape: keydown 229/"Unidentified" followed by input.
  await send('Input.insertText', { text: 'héllo🙂' });
  await frames(3);
  check(await evaluate(`__w.contains('héllo🙂')`), 'IME commit reaches the W textbox as CHAR events');
  await send('Input.dispatchKeyEvent', { type: 'rawKeyDown', windowsVirtualKeyCode: 229, key: 'Unidentified' });
  await send('Input.insertText', { text: 'x' });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', windowsVirtualKeyCode: 229, key: 'Unidentified' });
  await frames(3);
  check(await evaluate(`__w.contains('héllo🙂x')`), 'keyCode 229 keydown + input inserts once');
  await send('Input.dispatchKeyEvent', { type: 'rawKeyDown', windowsVirtualKeyCode: 8, key: 'Backspace', code: 'Backspace' });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', windowsVirtualKeyCode: 8, key: 'Backspace', code: 'Backspace' });
  await frames(3);
  check(await evaluate(`__w.contains('héllo🙂')`) && !(await evaluate(`__w.contains('héllo🙂x')`)),
    'Backspace deletes one scalar');
  await send('Input.imeSetComposition', { text: 'に', selectionStart: 1, selectionEnd: 1 });
  await frames(2);
  check(!(await evaluate(`__w.contains('héllo🙂に')`)), 'composition preedit is not committed text');
  await send('Input.insertText', { text: '日本' });
  await frames(3);
  check(await evaluate(`__w.contains('héllo🙂日本')`), 'composition commit arrives once');
  check(!(await evaluate(`__w.contains('héllo🙂日本日本')`)), 'composition commit is not duplicated');

  // One-finger vertical pan: cancels the press, then pixel scroll deltas.
  await evaluate('__w.events.length = 0');
  await send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: left + 200, y: top + 600 }] });
  for (let y = 590; y >= 400; y -= 10)
    await send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: left + 200, y: top + y }] });
  await send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await frames(3);
  events = await evaluate('__w.events');
  const kinds = events.map(e => e[0]);
  const scrolled = events.filter(e => e[0] === KIND.SCROLL_PIXELS).reduce((sum, e) => sum + e[1], 0);
  check(kinds.includes(KIND.CANCEL) && !kinds.includes(KIND.UP), `pan cancels instead of clicking: ${kinds}`);
  check(scrolled === 200, `pan scrolls 200 logical pixels down (got ${scrolled})`);
  check(await evaluate('document.documentElement.scrollTop === 0 && scrollY === 0'), 'page itself did not scroll');

  // Orientation change: W sees the new logical size on its next poll.
  await send('Emulation.setDeviceMetricsOverride',
    { width: 764, height: 412, deviceScaleFactor: 1.75, mobile: true,
      screenOrientation: { type: 'landscapePrimary', angle: 90 } });
  await frames(3);
  const land = await evaluate(`(() => { const c = document.getElementById('canvas');
    return { w: [__w.width, __w.height], buffer: [c.width, c.height], scrollW: document.documentElement.scrollWidth }; })()`);
  check(land.w[0] === 720 && land.w[1] === 412, `landscape logical size: ${land.w}`);
  check(land.buffer[0] === 1260 && land.buffer[1] === 721, `landscape backing store: ${land.buffer}`);
  check(land.scrollW <= 764, 'landscape has no horizontal overflow');
  // DPR-only change (browser zoom, another display): same logical size, so
  // the host itself re-covers the new device-pixel buffer.
  await send('Emulation.setDeviceMetricsOverride',
    { width: 764, height: 412, deviceScaleFactor: 3, mobile: true,
      screenOrientation: { type: 'landscapePrimary', angle: 90 } });
  await frames(3);
  const dense = await evaluate(`(() => { const c = document.getElementById('canvas'), gl = c.getContext('webgl2');
    return { w: [__w.width, __w.height], buffer: [c.width, c.height], viewport: Array.from(gl.getParameter(gl.VIEWPORT)) }; })()`);
  check(dense.w[0] === 720 && dense.w[1] === 412 && dense.buffer[0] === 2160 && dense.buffer[1] === 1236,
    `DPR 3 keeps logical size, grows buffer: ${JSON.stringify(dense)}`);
  check(dense.viewport[2] === 2160 && dense.viewport[3] === 1236, `viewport follows DPR change: ${dense.viewport}`);
  if (shotPath) {
    await send('Emulation.setDeviceMetricsOverride', { width: 412, height: 764, deviceScaleFactor: 1.75, mobile: true });
    await frames(3);
    const { data } = await send('Page.captureScreenshot', { format: 'png' });
    await writeFile(shotPath, Buffer.from(data, 'base64'));
  }
  const errors = consoleLines.filter(l => /exception|error/i.test(l));
  check(errors.length === 0, `no page errors:\n${errors.join('\n')}`);
  console.log(`run_browser_mobile OK (${passed} checks: layout, DPR, tap, soft keyboard, IME, pan, rotate, zoom)`);
} catch (e) {
  console.error(consoleLines.join('\n'));
  throw e;
} finally {
  ws.close();
  await cleanup();
}
