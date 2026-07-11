# tools/web: browser + Node hosts for W wasm modules

The JS half of the wasm target's host-import convention
(design: `docs/projects/wasm_webgl.md`): a W program declares its host
surface with `c_lib`/`extern` (see `graphics/gl_web.w` and
`graphics/window_web.w`), the compiler turns each extern into a typed
entry in the module's import section, and the embedder supplies the
functions at instantiation.

## Files

- `webgl_env.mjs` — the `"env"` import module: the WebGL2 bridge
  (handle tables, linear-memory marshalling for strings, buffers, and
  out-parameters) plus the `gfx_host_*` canvas surface. Environment-
  agnostic: pass a real WebGL2 context or a fake.
- `wasi_lite.mjs` — a browser-side WASI preview1 subset: stdout/stderr,
  clock, `proc_exit`; no filesystem, no args. (Node hosts use
  `node:wasi` instead.)
- `index.html` — the browser host page: canvas, input wiring, and the
  requestAnimationFrame loop that drives the module's registered frame
  callback until it returns 0.
- `run_env_test.mjs` — Node runner for `tests/wasm_extern_test.w`
  (the `wasm_extern_test` build target): deterministic `env`/`wtest`
  import modules plus callback/`$ax` assertions.
- `run_webgl_stub.mjs` — Node runner for headless graphics testing
  (the `wasm_webgl_test` build target): drives the frame loop over a
  recording fake WebGL2 context and asserts the GL call trace.

## Running the demo in a browser

```sh
./wbuild build
./bin/wv2 wasm graphics/demo_web.w -o bin/graphics_demo.wasm
python3 -m http.server 8000
# open http://localhost:8000/tools/web/?module=/bin/graphics_demo.wasm
```

## The host-callback contract

`gfx_window_run(win, frame)` hands the host a W function pointer, which
on wasm is an index into the module's exported `table`. The host calls
`table.get(index)()` once per animation frame — after `_start` has
returned — and reads the callback's result from the exported `ax`
global (every W function has wasm type `[] -> []`; values return in
`$ax`). A result of 0 stops the loop.
