// Minimal WASI preview1 runner on Node's built-in implementation, the
// fallback path of bin/wrun wasm (tools/wrun.w). The module path doubles as
// argv[0], mirroring the wasmtime CLI.
import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';
import { argv, exit } from 'node:process';
import { setFlagsFromString } from 'node:v8';

// Node 22's WASI fast API calls can run a garbage collection from inside
// uvwasi_fd_read (external-memory accounting), which then crashes walking the
// wasm frames. A large heap such as the self-hosted compiler's AST front end
// hits it; turn the fast calls off before the module is compiled.
setFlagsFromString('--no-turbo-fast-api-calls');

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
