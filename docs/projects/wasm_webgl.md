# Host imports + WebGL for the wasm target

The browser/host-import design note the wasm backend plan deferred
("graphics/events would want a real host-import design — worth a design
note when attempted", docs/projects/wasm_backend.md). Implemented in one
pass: `c_lib`/`extern` compile to typed wasm imports, the `graphics/`
tree gains a wasm backend that renders through WebGL2, and `tools/web/`
holds the JS host glue plus the Node test harnesses.

**Status: implemented.** `./wbuild wasm_extern_test` gates the FFI
(imports, f32 marshalling, multiple import modules, table callbacks,
the rejection diagnostics); `./wbuild wasm_webgl_test` gates the whole
graphics path headlessly; `tools/web/index.html` runs the same module
in a real browser (`graphics/demo_web.w` is the demo). Both need Node,
like `tools/run_wasm.sh`'s fallback path.

## D1: extern → import section (the compiler change)

On the native targets an extern is a GOT slot + a generated ABI shim.
On wasm there is no loader, but the container has exactly the right
primitive: the import section. So on `target_isa == 2`:

- Each `extern` becomes a function import with a **real typed
  signature** mapped from the W declaration: `int`/pointers → `i32`,
  `float32` → `f32`, `void` results → empty. One type-section entry per
  extern (duplicates are spec-legal; dedup is not worth the code).
- The enclosing `c_lib` string names the **import module** — the same
  statement that names a soname on ELF names a namespace here. With no
  c_lib in scope the module defaults to `"env"` (the ecosystem
  convention). `graphics/` uses `"env"` throughout; a program may group
  its own surface under any name (`wasm_extern_test` uses a second
  `"wtest"` module to pin the behavior).
- Import function indices are 10.. (after the fixed WASI set), assigned
  in declaration order and **final at declaration time**: W code never
  calls defined functions by function index (only through the funcref
  table), so late imports never renumber anything — the property the
  backend's D2 design bought deliberately.
- In front of each import sits a W-callable `[] -> []` stub, the wasm
  twin of `emit_ffi_shim`: load each argument word from the shadow
  stack, `f32.reinterpret_i32` the float32 ones (W floats ride the
  integer pipeline as raw bits), `call` the import, reinterpret/store
  the result to `$ax`. The extern's symbol resolves to the stub's table
  index, so calls look like any W call. This is the same shape as the
  compiler-synthesized WASI wrappers (`wasm_stub_simple`).
- Rejected with diagnostics (wexec-asserted fixtures): **variadic
  externs** (imports have fixed signatures), **extern data objects**
  (no loader, no COPY relocation), and **c_import** (native ABI shims).
  Previously all three silently emitted x86 bytes into the wasm code
  section, producing invalid modules.

## D2: the host-callback contract (exports)

The module now exports four names: `memory` and `_start` (as before),
plus:

- **`table`** — the funcref table. A W function pointer IS a table
  index, so W code can hand a callback to the host (`cast(int, f)`
  through any import) and the host calls `table.get(index)()`. This
  generalizes: input handlers, timers, any host-driven event can call
  back into W without per-function export machinery.
- **`ax`** — the accumulator global. Every W function has wasm type
  `[] -> []` and returns in `$ax`, so a host reads a callback's return
  value from this export after the call.

Re-entry is safe in both directions: the shadow stack is balanced by
each completed activation, whether the host calls during an import
(synchronous event) or after `_start` returned (the rAF loop).

## D3: graphics backend — invert the render loop

The `graphics.window` contract is a blocking poll loop; a browser
cannot block, and the canvas only presents when control returns to the
event loop. The wasm backend (`graphics/window_web.w`, selected via
`graphics/__arch__/wasm/`) keeps the surface but inverts the driver:

- `gfx_window_open` binds the host canvas (`gfx_host_canvas_init`).
- `gfx_window_poll` is non-blocking: one `gfx_host_poll_state` import
  refreshes the 7-field input snapshot (the gfx_window struct layout is
  the import's contract).
- `gfx_window_swap` is a no-op — the browser composites on return.
- `gfx_window_run(win, frame)` registers a `fn() -> int` frame callback
  (D2's table-index convention); the host calls it once per
  requestAnimationFrame until it returns 0. Programs structure as
  setup-in-main + frame function (`graphics/demo_web.w`); main returns
  before the first frame runs.
- `gfx_shader_header()` returns `"#version 300 es"` + a default float
  precision; the shared demo shader bodies compile unchanged on GLSL
  130/150/ES-300.

JSPI (JavaScript Promise Integration) could instead suspend the
blocking loop and was rejected for now: it ties the target to newer
engines, and the inverted shape matches the backend's existing "no
stack switching" stance (the same reason generators are out of scope).

- `graphics/gl_web.w` declares the same core-GL extern surface as
  `gl_linux.w` minus GLX. The JS glue (`tools/web/webgl_env.mjs`) maps
  it onto WebGL2: a handle table for GL objects (WebGL handles are JS
  objects, native GL's are ints), fresh memory views per call
  (`memory.grow` detaches ArrayBuffers), strings decoded/encoded
  through linear memory, `glGetString` results copied into the reserved
  low page ([3072, 4096); the WASI wrappers use [256, 512)), and the
  WebGL-isms absorbed in one place (INFO_LOG_LENGTH from the JS-side
  log string, boolean parameters to 0/1).

## Language gaps the graphics path uncovered (fixed en route)

None of these were reachable from the self-host corpus, which is why
the fixpoint never caught them:

- **Enum constants** were emitted inline in the code stream and read
  through their symbol address — but wasm code is not addressable
  memory, and the stray bytes between the size-prefixed function units
  corrupted the code section. On wasm they now live in the data
  segment (`grammar/enum_declaration.w`), including the compile-time
  read for parameter defaults (`grammar/program.w`).
- **`wasm_mov_ebx_esp` mistranslated `mov ebx,[esp]`** (a load of the
  W stack top) as `$bx = $sp` (the pointer itself), corrupting the
  stack in every struct-constructor / `new` / array-field-descriptor
  path. The smoke slice now includes struct_test, default_args_test,
  and graphics/math_test as wasm twins to keep these paths covered.

## Testing

- `wasm_extern_test` (build.base.json; source in generate.exclude):
  compiles `tests/wasm_extern_test.w` and runs it under
  `tools/web/run_env_test.mjs` — int/f32/void imports, a second import
  module, callback re-entry during a host call and after `_start`,
  `$ax` readback — plus the three rejection fixtures via wexec
  `expect_fail`/`expect_stderr` steps (wfixture has no arch selector,
  so the directives in the fixture headers are documentation until it
  grows one).
- `wasm_webgl_test`: compiles `graphics/demo_web.w` and drives 3
  frames under `tools/web/run_webgl_stub.mjs` (a recording fake WebGL2
  context), asserting the call trace: 2 shaders with the ES header, 1
  link, the 60-byte vertex upload, per-frame clear/uniformMatrix4fv/
  drawArrays, and the frame callback stopping via `$ax == 0`.
- Both are outside the default `tests` umbrella (Node-bound), like the
  qemu-bound arm64 targets and the other wasm gates. The native
  fixpoints (`verify`, `verify_x64`, `verify_arm64`) stay byte-identical
  — every change is gated on `target_isa == 2`.

## Deferred

- Textures, element-array demos, and the rest of the GL surface —
  extend `gl_web.w`/`gl_linux.w` and the glue together as consumers
  appear.
- Keyboard/mouse callback events (state polling covers the demos; event
  callbacks are D2-ready when wanted).
- A real-browser CI gate (headless Chromium + pixel asserts via
  `glReadPixels`); the recording fake covers the plumbing today.
- JSPI as an alternative driver for unmodified blocking demos.
- Direct `call` optimization for extern calls (they go through the
  stub + `call`; inlining the import call at W call sites is a pure
  backend change).
