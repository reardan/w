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
- `run_export_test.mjs` — Node runner for `tests/wasm_export_test.w`
  (the `wasm_export_test` build target): calls `export`-marked W
  functions through their real-signature exports.
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

## Real-signature exports

A W function marked `export` (`export int add3(int a, int b, int c):`)
also appears in the module's export section under its own name, bound
to a wrapper with its real typed signature (`int`/pointers → `i32`,
`float32` → `f32`, `void` → no result), so an embedder calls
`instance.exports.add3(1, 2, 3)` directly — no `table.get`, no `ax`
readback. The table/`ax` contract above still works unchanged for
callbacks held as W function pointers. See
`docs/projects/wasm_backend.md` (2026-08 execution notes).

## Mobile browser input and sizing

`index.html` now uses `mobile_input.mjs` for mouse, pen, and touch input.
A primary pointer is captured until release; cancellation, lost capture,
window blur, and page hiding clear the pressed state. A touch movement of
8 CSS pixels starts panning and cancels the pending click. Widgets that
explicitly report drag capture (scroll thumbs and splitters) retain their
pointer stream. Wheel units and touch movement become pixel scroll events;
there is no momentum/fling implementation yet.

The viewport follows `visualViewport`, including software-keyboard resize,
orientation changes, and safe-area padding. W receives logical CSS-pixel
window sizes and coordinates. The canvas backing buffer uses device pixel
ratio, and the WebGL bridge scales `glViewport` and `glScissor`. This host
convention applies to onscreen drawing: framebuffer/readback clients must
account for device pixels separately. Applications must lay out against
`win.width` / `win.height`; resizing the host cannot make fixed widget
coordinates responsive.

Focused W textboxes and textareas publish their rectangle through
`gfx_host_text_input(active, multiline, x, y, width, height, focus_id)`. A small DOM
textarea provides the software keyboard and IME. Pointer handlers run one
W frame synchronously before focusing it, preserving iOS's trusted-gesture
requirement and avoiding a keyboard on ordinary button taps. Touch focuses
on release only after a tap; swiping across a field does not open the keyboard. Committed
Unicode scalar values become CHAR events; composition preedit stays in the
browser and is committed once. A stable `focus_id` prevents a pending
composition from being committed into a different field. Paste is queued across frames (32 characters and 8 navigation events
per frame, matching the W UI buffers), so large pastes are not truncated.
Backspace, forward delete, and line breaks use the existing editor events.
Browser shortcuts with Ctrl/Command/Alt are left to the browser.

The DOM textarea is an input sink, not a synchronized copy of W's complete
text selection. Autocorrect is disabled; native selection handles, dictation
replacement, cut/copy of a W selection, rich clipboard content, and full
screen-reader widget semantics are not implemented. The host does not yet
expose a semantic accessibility tree for canvas controls. Real-device Safari
and Android checks remain necessary: Node event tests cannot prove keyboard
presentation or browser composition behavior on every OS.

Host ABI additions (existing headless hosts may omit these callbacks):

- `gfx_host_text_input(active, multiline, x, y, width, height, focus_id)` forwards to
  `host.textInput(...)`.
- `gfx_host_pointer_mode(mode)` forwards to `host.pointerMode(mode)`;
  `1` keeps a widget's touch drag, `0` permits page-style touch panning.
- Event kind `8` carries signed pixel scroll distance in `code` (positive
  down); kind `9` cancels the current pointer gesture.

Run the input/viewport/GL-bridge regression suite with:

```sh
node tools/web/mobile_input_test.mjs
```

It covers pointer capture and cancellation, secondary contacts, scroll-unit
conversion, drag versus pan, focus during a gesture, Unicode and IME event
ordering, long paste backpressure, browser shortcuts, keyboard viewport
sizing, and Retina viewport/clipping conversion.

The actual wasm form is exercised separately with the shared recording GL host:

```sh
./bin/wv2 wasm graphics/ui/mobile_demo_web.w -o bin/graphics_ui_mobile.wasm
node tools/web/run_mobile_ui.mjs bin/graphics_ui_mobile.wasm
```

On Apple Silicon macOS, build the native compiler first and use it for the
compile step (the Linux `bin/wv2` executable cannot run directly on macOS):

```sh
./wbuild build_darwin
bin/wv2_darwin arm64_darwin tools/generate_ui_atlas.w -o bin/generate_ui_atlas_darwin
bin/generate_ui_atlas_darwin
bin/wv2_darwin wasm graphics/ui/mobile_demo_web.w -o bin/graphics_ui_mobile.wasm
node tools/web/run_mobile_ui.mjs bin/graphics_ui_mobile.wasm
python3 -m http.server 8000
```

Open `http://localhost:8000/tools/web/?module=/bin/graphics_ui_mobile.wasm`, or
use the Mac's LAN address from a phone on the same network. On Linux,
`./wbuild graphics_ui_mobile_web` builds the demo, and
`./wbuild web_mobile_input_test wasm_mobile_ui_test` runs both mobile checks
(Node 20+ required).

This drives Unicode editing, long paste, the focused-field ABI, keyboard
viewport shrink, exact pixel scrolling, gesture cancellation and scroll bounds
through the compiled W widgets (18 frames), in addition to the 24 JavaScript
input-policy scenarios. It is a headless integration check, not a substitute
for physical device keyboard/IME testing.
