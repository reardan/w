// Browser execution gate for WASI wasm32 modules (safe_wasm_browser_test).
// Usage:
//   node tools/web/run_browser_wasi.mjs [--steps <file.w>]... [--list <file>]...
//
// --steps reads a W source's `# wbuild: step="bin/wrun wasm <module> [args]"`
// directive lines, with their expect_fail / expect_stdout= / expect_stderr=
// decorations, so the browser runs exactly the corpus the tests_wasm targets
// run. --list reads a file of module paths (one per line) that must exit 0;
// tests/safe_wasm_contract_test.w writes one for its accepted programs.
//
// Each module first runs under bin/wrun wasm (wasmtime, else node's WASI),
// the reference, then in headless Chromium through tools/web/wasi_lite.mjs.
// The browser run must reproduce the reference's stdout, stderr and exit
// status exactly (a wasm trap, which wasmtime and node report with their own
// stderr text, must match a nonzero reference whose stderr starts with the
// program's), and must meet the directive's own expectations.
//
// With no Chromium (tools/web/headless_chromium.mjs findChromium) it prints
// a SKIP line and exits 0, or exits 1 when W_REQUIRE_BROWSER=1.
import { spawn } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { findChromium, openPage } from './headless_chromium.mjs';

const label = 'safe_wasm_browser';
const groups = [];
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i += 2) {
  const [flag, path] = [argv[i], argv[i + 1]];
  if (!path || (flag !== '--steps' && flag !== '--list')) {
    console.error(`usage: run_browser_wasi.mjs [--steps <file.w>]... [--list <file>]...`);
    process.exit(2);
  }
  if (!existsSync(path)) throw new Error(`${label}: ${path} does not exist (build its target first)`);
  const text = readFileSync(path, 'utf8');
  const cases = [];
  if (flag === '--list') {
    for (const line of text.split('\n').map(l => l.trim()).filter(Boolean))
      cases.push({ module: line, args: [], fail: false, stdout: [], stderr: [] });
  } else {
    for (const line of text.split('\n')) {
      const m = /^# wbuild: step="bin\/wrun wasm ([^"]+)"(.*)$/.exec(line);
      if (!m) continue;
      const [module, ...args] = m[1].trim().split(/\s+/);
      const rest = m[2];
      const values = key => [...rest.matchAll(new RegExp(`${key}="((?:[^"\\\\]|\\\\.)*)"`, 'g'))].map(v => v[1]);
      cases.push({ module, args, fail: /(^|\s)expect_fail(\s|$)/.test(rest),
        stdout: values('expect_stdout'), stderr: values('expect_stderr') });
    }
  }
  if (cases.length === 0) throw new Error(`${label}: no wasm modules found in ${path}`);
  groups.push({ path, cases });
}
if (groups.length === 0) throw new Error(`${label}: nothing to run`);
const total = groups.reduce((n, g) => n + g.cases.length, 0);

const chromium = findChromium();
if (!chromium) {
  if (process.env.W_REQUIRE_BROWSER === '1') {
    console.error(`${label} FAIL: W_REQUIRE_BROWSER=1 but no Chromium (set CHROMIUM)`);
    process.exit(1);
  }
  console.log(`${label} SKIP (no Chromium; set CHROMIUM) — ${total} modules not run in a browser`);
  process.exit(0);
}

// --------------------------- reference runs (bin/wrun) ---------------------------
const reference = c => new Promise((ok, fail) => {
  const child = spawn('bin/wrun', ['wasm', c.module, ...c.args], { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '', err = '';
  child.stdout.on('data', d => { out += d; });
  child.stderr.on('data', d => { err += d; });
  child.on('error', fail);
  child.on('close', status => ok({ out, err, status }));
});
const all = groups.flatMap(g => g.cases);
const refs = new Array(all.length);
let next = 0;
await Promise.all(Array.from({ length: 4 }, async () => {
  while (next < all.length) { const i = next++; refs[i] = await reference(all[i]); }
}));

// ------------------------------- browser runs -------------------------------
const runInPage = (module, args) => `(async () => {
  const { makeWasi } = await import('/tools/web/wasi_lite.mjs');
  const response = await fetch(${JSON.stringify('/' + module)});
  if (!response.ok) throw new Error('fetch ' + response.status);
  let out = '', err = '', instance;
  const wasi = makeWasi({ memory: () => instance.exports.memory, args: ${JSON.stringify(args)},
    onWrite: (fd, text) => { if (fd === 2) err += text; else out += text; } });
  ({ instance } = await WebAssembly.instantiate(await response.arrayBuffer(),
    { wasi_snapshot_preview1: wasi.imports }));
  let status, trap = null;
  try { status = wasi.runStart(instance); }
  catch (e) { status = 'trap'; trap = String(e); }
  return { out, err, status, trap };
})()`;

const page = await openPage({ chromium });
const failures = [];
const counts = [];
try {
  let index = 0;
  for (const group of groups) {
    let passed = 0;
    for (const c of group.cases) {
      const ref = refs[index++];
      const name = [c.module, ...c.args].join(' ');
      const problems = [];
      let got, timer;
      try {
        got = await Promise.race([page.evaluate(runInPage(c.module, [c.module, ...c.args])),
          new Promise((_, fail) => { timer = setTimeout(() => fail(new Error('timed out after 60s')), 60000); })]);
      } catch (e) {
        problems.push(`browser run failed: ${e.message}`);
      } finally {
        clearTimeout(timer);
      }
      if (got) {
        if (got.status === 'trap') {
          if (ref.status === 0) problems.push(`trapped (${got.trap}); reference exited 0`);
          if (!ref.err.startsWith(got.err)) problems.push(`stderr ${JSON.stringify(got.err)} is not a prefix of the reference's ${JSON.stringify(ref.err)}`);
        } else {
          if (got.status !== ref.status) problems.push(`exit ${got.status}, reference exit ${ref.status}`);
          if (got.err !== ref.err) problems.push(`stderr ${JSON.stringify(got.err)} != reference ${JSON.stringify(ref.err)}`);
        }
        if (got.out !== ref.out) problems.push(`stdout ${JSON.stringify(got.out)} != reference ${JSON.stringify(ref.out)}`);
        const failed = got.status !== 0;
        if (failed !== c.fail) problems.push(c.fail ? 'expected a nonzero exit' : `expected exit 0, got ${got.status}`);
        for (const s of c.stdout) if (!got.out.includes(s)) problems.push(`stdout lacks ${JSON.stringify(s)}`);
        for (const s of c.stderr) if (!got.err.includes(s)) problems.push(`stderr lacks ${JSON.stringify(s)}`);
      }
      if (problems.length) failures.push(`${name}:\n  ${problems.join('\n  ')}`);
      else passed++;
    }
    counts.push(`${passed}/${group.cases.length} from ${group.path}`);
  }
} finally {
  await page.close();
}
if (failures.length) {
  console.error(failures.join('\n'));
  if (page.consoleLines.length) console.error(page.consoleLines.join('\n'));
  console.error(`${label} FAIL: ${failures.length} of ${total} modules differ in ${page.version} (${counts.join(', ')})`);
  process.exit(1);
}
console.log(`${label} OK: ${total} modules matched bin/wrun wasm in ${page.version} (${counts.join(', ')})`);
