// Headless end-to-end test of the W debugger UI (tools/wdbg_ui.w): starts
// bin/wdbg_web over plain HTTP on the debug fixture, runs bin/wdbg_ui.wasm
// under Node against a no-op WebGL context with the real "wdbg" HTTP bridge
// (wdbg_bridge.mjs), and drives it with key events the way a person would.
// The UI prints one "wdbg_ui: ..." line per stop; this script waits for
// each expected one before sending the next keys.
//
//   Alt+S, Down x11, F2   breakpoint on line 11 of the source view
//   F9                    run to the 'debugger' statement (line 9)
//   F9                    run to the F2 breakpoint (line 11)
//   F9 ...                run until the program exits
//
// Usage (from the repo root): bin/wrun node tools/wdbg_web/run_ui_test.mjs
// Prints "wdbg_ui test OK" on success; UI_TRACE=1 logs every request the
// UI makes to stderr.
import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { exit } from 'node:process';
import { makeEnv } from '../web/webgl_env.mjs';
import { makeWasi } from '../web/wasi_lite.mjs';
import { makeWdbgBridge } from './wdbg_bridge.mjs';

const fail = (msg) => {
  console.error(`run_ui_test: FAIL: ${msg}`);
  server?.kill('SIGKILL');
  exit(1);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------- the server -------------------------------------
const server = spawn('bin/wdbg_web',
  ['--http', '--code', 'uitest', '--port', '0', 'tests/debug_fixture.w'],
  { stdio: ['ignore', 'pipe', 'inherit'] });
const base = await new Promise((resolve) => {
  let buf = '';
  const timer = setTimeout(() => fail('wdbg_web printed no URL'), 180000);
  server.stdout.on('data', (d) => {
    buf += d;
    const nl = buf.indexOf('\n');
    if (nl >= 0) {
      clearTimeout(timer);
      resolve(buf.slice(0, nl).replace(/\/\?code=.*$/, ''));
    }
  });
  server.on('exit', () => fail('wdbg_web exited before printing its URL'));
});

// ------------------------- a WebGL2 that does nothing --------------------------
// Every method is a no-op returning a fresh object, except the few whose
// results the glue checks (compile/link status, errors, attribute slots).
let attrib = 0;
const special = {
  getShaderParameter: () => true,
  getProgramParameter: () => true,
  getShaderInfoLog: () => '',
  getProgramInfoLog: () => '',
  getError: () => 0,
  getAttribLocation: () => attrib++,
  getParameter: () => 'fake',
};
const gl = new Proxy({}, { get: (_, name) => special[name] ?? (() => ({})) });

// ------------------------------ the module -------------------------------------
const events = [];
let frameCallback = 0;
const host = {
  canvasInit: () => 1,
  pollState: () => ({
    width: 1280, height: 800, shouldClose: 0,
    mouseX: 0, mouseY: 0, mouseButtons: 0, lastKeycode: 0,
  }),
  setFrameCallback: (i) => { frameCallback = i; },
  nextEvent: () => events.shift() ?? null,
};
let out = '';
let instance = null;
const memory = () => instance.exports.memory;
const wasi = makeWasi({ memory, onWrite: (fd, text) => { if (fd === 1) out += text; } });
instance = await WebAssembly.instantiate(await WebAssembly.compile(await readFile('bin/wdbg_ui.wasm')), {
  wasi_snapshot_preview1: wasi.imports,
  env: makeEnv({ memory, gl, host }),
  wdbg: makeWdbgBridge({ memory, base, code: 'uitest', fetch: process.env.UI_TRACE ? (u, i) => { console.error('>>', i.method, u, i.body ?? ''); return fetch(u, i); } : fetch }),
});
wasi.runStart(instance);
if (!frameCallback) fail('the UI registered no frame callback');

const key = (code, mods = 0) => events.push({ kind: 1, code, x: 0, y: 0, mods });
const nav = (code) => events.push({ kind: 7, code, x: 0, y: 0, mods: 0 });

// Run frames (letting fetches settle between them) until the UI's output
// contains want, starting from offset.
let seen = 0;
const frames = async (n) => {
  for (let i = 0; i < n; i++) {
    instance.exports.table.get(frameCallback)();
    if (instance.exports.ax.value === 0) fail('the frame callback stopped');
    await sleep(2);
  }
};
const waitFor = async (want) => {
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline) {
    const at = out.indexOf(want, seen);
    if (at >= 0) { seen = at + want.length; return; }
    await frames(5);
  }
  fail(`never printed "${want}"; output so far:\n${out}`);
};

await waitFor('wdbg_ui: Paused outside the program');
key(83, 4);                                   // Alt+S: source view
await frames(30);                             // the program's source loads
for (let i = 0; i < 11; i++) {                // Down to line 11
  nav(6);
  await frames(1);
}
key(113);                                     // F2: breakpoint there
await frames(30);
key(120);                                     // F9
await waitFor('wdbg_ui: Paused at main (debug_fixture.w:9)');
key(120);
await waitFor('wdbg_ui: Paused at main (debug_fixture.w:11)');
for (let i = 0; i < 4 && out.indexOf('wdbg_ui: exited', seen) < 0; i++) {
  key(120);
  await frames(40);
}
await waitFor('wdbg_ui: exited');
server.kill('SIGKILL');
console.log('wdbg_ui test OK');
exit(0);
