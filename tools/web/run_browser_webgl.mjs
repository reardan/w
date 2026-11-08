// Real-WebGL2 gate for W graphics programs that check their own pixels
// (graphics/gl_fbo_test.w, graphics/effects_gl_test.w): loads the module
// through tools/web/index.html (WASI-lite stdout to the console, the
// webgl_env.mjs glue over the page's WebGL2 canvas) in headless Chromium
// and waits for the program's verdict line.
//
// Usage: node tools/web/run_browser_webgl.mjs <module.wasm>
//
// The verdict is the native convention of those tests: a stdout line
// ending in " OK" passes; one containing " FAILED" or " SKIP", or an
// uncaught page exception, fails (a browser always has a canvas, so a
// SKIP means WebGL2 itself is missing). On a pass it prints
// "<verdict line> (webgl, <browser version>)"; otherwise it replays the
// page console and exits 1. Without a Chromium it prints a SKIP line and
// exits 0 (1 when W_REQUIRE_BROWSER=1).
import { findChromium, openPage } from './headless_chromium.mjs';

const wasmPath = process.argv[2];
if (!wasmPath) {
  console.error('usage: run_browser_webgl.mjs <module.wasm>');
  process.exit(2);
}
const chromium = findChromium();
if (!chromium) {
  if (process.env.W_REQUIRE_BROWSER === '1') {
    console.error(`run_browser_webgl FAIL: W_REQUIRE_BROWSER=1 but no Chromium (set CHROMIUM)`);
    process.exit(1);
  }
  console.log(`run_browser_webgl SKIP (no Chromium; set CHROMIUM): ${wasmPath}`);
  process.exit(0);
}

const page = await openPage({ chromium });
let code = 1;
try {
  await page.send('Page.navigate', { url: `${page.origin}/tools/web/index.html?module=/${wasmPath}` });
  const deadline = Date.now() + 60000;
  let passed = null;
  let failed = null;
  while (Date.now() < deadline && passed === null && failed === null) {
    for (const line of page.consoleLines.map(l => String(l).trimEnd())) {
      if (line.endsWith(' OK')) passed = line;
      else if (line.includes(' FAILED') || line.includes(' SKIP') || line.startsWith('exception:')) failed = line;
    }
    if (passed === null && failed === null) await new Promise(ok => setTimeout(ok, 50));
  }
  if (passed !== null && failed === null) {
    console.log(`${passed} (webgl, ${page.version})`);
    code = 0;
  } else {
    for (const line of page.consoleLines) console.error(`  page: ${String(line).trimEnd()}`);
    console.error(`run_browser_webgl FAIL: ${failed ?? 'no verdict within 60s'} (${wasmPath})`);
  }
} finally {
  await page.close();
}
process.exit(code);
