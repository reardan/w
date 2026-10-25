// Headless Chromium over the DevTools protocol, for browser execution gates.
// No npm dependencies: Node 22's built-in WebSocket and node:http.
//
// findChromium() looks for a browser binary: $CHROMIUM, then chromium,
// chromium-browser, google-chrome or google-chrome-stable on PATH, then
// /snap/bin/chromium, then the Chromium build of a globally resolvable
// Playwright install (its executablePath(); nothing is downloaded). It
// returns null when there is none, so callers can SKIP loudly.
//
// openPage({ chromium, root }) serves `root` on a free loopback port,
// launches the browser, attaches to one blank page on that origin and
// returns { origin, evaluate(expression), consoleLines, close() }.
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { existsSync, mkdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { homedir, tmpdir } from 'node:os';
import { join, resolve, extname, sep } from 'node:path';

const which = name => {
  try { return execFileSync('sh', ['-c', `command -v ${name}`]).toString().trim() || null; }
  catch { return null; }
};

const playwrightChromium = () => {
  for (const base of [join(process.cwd(), 'x.js'), import.meta.url]) {
    try {
      const path = createRequire(base)('playwright').chromium.executablePath();
      if (path && existsSync(path)) return path;
    } catch { /* not installed there */ }
  }
  return null;
};

export function findChromium() {
  return (process.env.CHROMIUM || null) ?? which('chromium') ?? which('chromium-browser') ??
    which('google-chrome') ?? which('google-chrome-stable') ??
    (existsSync('/snap/bin/chromium') ? '/snap/bin/chromium' : null) ??
    playwrightChromium();
}

const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript',
  '.wasm': 'application/wasm', '.json': 'application/json' };

export async function openPage({ chromium, root = resolve('.') }) {
  if (typeof WebSocket !== 'function') throw new Error('Node 22+ (global WebSocket) required');
  // Any module file under root, plus a blank page that gives evaluated
  // code an http origin (dynamic import() needs one).
  const server = createServer(async (req, res) => {
    const pathname = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (pathname === '/__blank') {
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end('<!doctype html><meta charset="utf-8"><title>w</title>');
      return;
    }
    const file = resolve(root, '.' + pathname);
    if (!file.startsWith(root + sep)) { res.writeHead(403); res.end(); return; }
    try {
      const body = await readFile(file);
      res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' });
      res.end(body);
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise(ok => server.listen(0, '127.0.0.1', ok));
  const origin = `http://127.0.0.1:${server.address().port}`;

  // A snap-confined Chromium cannot see the host /tmp or dot-directories.
  const profileBase = chromium.startsWith('/snap/') ? join(homedir(), 'snap', 'chromium', 'common') : tmpdir();
  mkdirSync(profileBase, { recursive: true });
  const profile = await mkdtemp(join(profileBase, 'w-web-'));
  const flags = ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check'];
  // The page only loads this loopback server's checkout files, so the OS
  // sandbox buys nothing here, and it cannot start as root (containers) or
  // under Ubuntu 24.04's AppArmor user-namespace restriction (CI runners).
  flags.push('--no-sandbox');
  const browser = spawn(chromium, [...flags, 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = '';
  const close = async () => {
    browser.kill('SIGKILL');
    server.close();
    await rm(profile, { recursive: true, force: true }).catch(() => {});
  };
  let ws;
  try {
    const wsUrl = await new Promise((ok, fail) => {
      const timer = setTimeout(() => fail(new Error(`no DevTools endpoint:\n${stderr}`)), 30000);
      browser.stderr.on('data', chunk => {
        stderr += chunk;
        const m = /DevTools listening on (ws:\/\/\S+)/.exec(stderr);
        if (m) { clearTimeout(timer); ok(m[1]); }
      });
      browser.on('exit', code => { clearTimeout(timer); fail(new Error(`chromium exited ${code}:\n${stderr}`)); });
    });
    ws = new WebSocket(wsUrl);
    await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = fail; });
  } catch (e) {
    await close();
    throw e;
  }
  let nextId = 1;
  let sessionId;
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
  const send = (method, params = {}) => new Promise((ok, fail) => {
    const id = nextId++;
    pending.set(id, { ok, fail });
    ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  const evaluate = async expression => {
    const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
    return r.result.value;
  };
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  ({ sessionId } = await send('Target.attachToTarget', { targetId, flatten: true }));
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Page.navigate', { url: `${origin}/__blank` });
  const href = () => evaluate('document.readyState === "complete" && location.href').catch(() => null);
  for (let i = 0; i < 1000 && await href() !== `${origin}/__blank`; i++)
    await new Promise(ok => setTimeout(ok, 10));
  const version = (await send('Browser.getVersion').catch(() => ({})))?.product ?? 'Chromium';
  return {
    origin, evaluate, consoleLines, version,
    close: async () => { ws.close(); await close(); },
  };
}
