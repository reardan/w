// Host runner for tests/wasm_export_test.w: after the module's own
// _start runs (its main exercises the exported functions from the W
// side and leaves counter == 3), each 'export'-marked W function is
// called directly through its real-signature export — int and f32
// values cross as ordinary wasm params/results, no table.get or $ax
// readback involved. The uniform contract stays alongside: the funcref
// table and the $ax global are still exported.
//
// Usage: node tools/web/run_export_test.mjs bin/wasm_export_test
import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';
import { argv, exit } from 'node:process';

const fail = (msg) => { console.error(`run_export_test: FAIL: ${msg}`); exit(1); };
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

const wasm = await WebAssembly.compile(await readFile(argv[2]));
const instance = await WebAssembly.instantiate(wasm, wasi.getImportObject());
assertEq(0, wasi.start(instance), 'module exit code');

const e = instance.exports;

// The export surface: the four uniform exports plus the typed ones.
for (const name of ['memory', '_start', 'table', 'ax', 'add3', 'scale', 'bump', 'get_counter']) {
  if (!(name in e)) fail(`missing export '${name}'`);
}

// Real typed signatures: ints in, int out.
assertEq(42, e.add3(10, 20, 12), 'add3(10, 20, 12)');
assertEq(-5, e.add3(-10, 2, 3), 'add3(-10, 2, 3)');

// f32 param + result mixed with an i32 param.
assertEq(6, e.scale(1.5, 4), 'scale(1.5, 4)');
assertEq(-0.5, e.scale(-0.25, 2), 'scale(-0.25, 2)');

// void result + instance state: main already left counter == 3, and
// repeated post-_start calls keep mutating the same instance.
assertEq(undefined, e.bump(4), 'bump(4) result');
e.bump(2);
assertEq(9, e.get_counter(), 'get_counter() after bump(4), bump(2)');

console.log('run_export_test OK');
