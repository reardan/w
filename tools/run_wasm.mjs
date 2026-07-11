// Minimal WASI preview1 runner on Node's built-in implementation, the
// fallback path of tools/run_wasm.sh. The module path doubles as
// argv[0], mirroring the wasmtime CLI.
import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';
import { argv, exit } from 'node:process';

const wasi = new WASI({
  version: 'preview1',
  args: argv.slice(2),
  env: {},
  preopens: { '.': process.cwd() },
  returnOnExit: true,
});
const wasm = await WebAssembly.compile(await readFile(argv[2]));
const instance = await WebAssembly.instantiate(wasm, wasi.getImportObject());
exit(wasi.start(instance));
