// Host runner for tests/wasm_extern_test.w: provides the deterministic
// "env" and "wtest" import modules the test declares with c_lib/extern,
// exercises the callback path (a W function pointer is a table index;
// the host calls back through the exported table, re-entering the module
// both during a host call and after _start returned), and checks the
// callback's return value through the exported $ax global.
//
// Usage: node tools/web/run_env_test.mjs bin/wasm_extern_test
import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';
import { argv, exit } from 'node:process';

const fail = (msg) => { console.error(`run_env_test: FAIL: ${msg}`); exit(1); };
const assertEq = (want, got, what) => {
  if (want !== got) fail(`${what}: want ${want}, got ${got}`);
};

const wasi = new WASI({
  version: 'preview1',
  args: [argv[2]],
  env: {},
  preopens: { '.': process.cwd() },
  returnOnExit: true,
});

let instance = null;
let noted = 0;
let callbackIndex = 0;
const callbackReturns = [];

// Call the registered W callback through the exported table; the return
// value of a [] -> [] W function travels in the exported $ax global.
const callback = () => {
  instance.exports.table.get(callbackIndex)();
  const ax = instance.exports.ax.value;
  callbackReturns.push(ax);
  return ax;
};

const env = {
  env_default_add: (a, b) => a + b,          // extern before any c_lib -> "env"
  env_add: (a, b) => a + b,
  env_scale: (x, k) => x * k,                // f32 in, f32 out
  env_note: (v) => { noted = v; },           // void import
  env_get_note: () => noted,
  env_set_callback: (fn) => {
    callbackIndex = fn;
    // Re-enter the module twice while this host call is still on the
    // W stack — the same shape as a synchronous browser event handler.
    assertEq(10, callback(), 'first re-entrant callback return ($ax)');
    assertEq(20, callback(), 'second re-entrant callback return ($ax)');
  },
};
const wtest = {
  wtest_mul: (a, b) => a * b,                // a second import module
};

const wasm = await WebAssembly.compile(await readFile(argv[2]));
instance = await WebAssembly.instantiate(wasm, {
  ...wasi.getImportObject(),
  env,
  wtest,
});

const code = wasi.start(instance);
assertEq(0, code, 'module exit code');
if (callbackIndex === 0) fail('module never registered a callback');

// The requestAnimationFrame shape: calls into the module after _start
// has returned still work against the same instance state.
assertEq(30, callback(), 'post-_start callback return ($ax)');
assertEq('10,20,30', callbackReturns.join(','), 'callback return sequence');

console.log('run_env_test OK');
