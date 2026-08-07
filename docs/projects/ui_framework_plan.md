# UI Framework: Stage 1 Implementation Plan

Execution plan for issue #334, implementing stage 1 of
[docs/projects/ui_framework.md](ui_framework.md) (the design doc, PR
#339). The design doc is the authority on *what* and *why*; this doc
pins *how*: the PR sequence, exact files, API shapes, and gates. Each
PR lands green on its own (`./wbuild tests` plus the Node-bound wasm
gates locally).

Maintainer decisions folded in (2026-08-07):

- **Compiler fix first**: the arm64_darwin extern-arity fix (PR 0)
  lands ahead of the texture externs, so the Darwin GL binding gets
  real 9-argument externs from day one instead of stub wrappers.
- **Font glyphs**: the public-domain dhepper/font8x8 ASCII set,
  committed as a text asset with a provenance header (the
  `tools/unicode/UnicodeData.txt` precedent). ASCII 32..126 only for
  stage 1 (design doc open question 1), drawn at 2x scale.

PR sequence: 0 → 1 → 2/3 (independent of each other) → 4 → 5.
(As landed: all five stages shipped as one commit per stage on the
`claude/ui-framework-plan-7t0l7o` branch, PR #428, each commit green
on its own.)

## Why this order

The design doc's stage 1 needs three things that do not exist: texture
upload (for the glyph atlas), an input event queue (so a press+release
inside one poll cycle is not lost), and the `graphics/ui/` tree itself.
Texture upload is blocked on a compiler limit: `glTexImage2D` and
`glTexSubImage2D` take 9 arguments, and
[code_generator/ffi.w](../../code_generator/ffi.w) rejects any
arm64_darwin extern whose arguments overflow the 8 integer registers.
Everything else is leaf-consumer work (`graphics/`, `tools/`,
`build.base.json`) with no seed or verify implications.

## PR 0 — arm64_darwin FFI: allow a single integer-class stack spill

The guard at `code_generator/ffi.w:381-385` rejects every Darwin
extern call with `stack_count > 0`, because Darwin packs on-stack
arguments at natural size while the emitter uses 8-byte slots, and the
three-class model does not carry argument sizes. The premise ("no
binding we author needs overflow arguments") ends with `glTexImage2D`.

The minimal correct relaxation: allow the call when **exactly one**
argument spills **and** its class is 0 (integer/pointer). One
integer-class spill in an 8-byte slot at `[sp]` is byte-identical to
Darwin natural packing: the leftmost (only) memory argument sits at
`[sp]` in both schemes; a pointer or word `int`'s natural size is 8;
for a narrower integer the callee reads the low bytes (little-endian)
and the pad bytes land in caller-owned scratch below the 16-aligned
spill area. Two or more spills would need per-argument natural sizes
the classifier does not track — keep rejecting those with the same
message (its text stays true, and nothing freezes it: no fixture
carries it today).

Changes:

- `code_generator/ffi.w`, `emit_c_abi_call_arm64`: replace the
  `stack_count > 0` reject with a reject for `stack_count > 1`, or a
  single spill whose class is not 0. Comment explains the natural-size
  argument above.
- Negative fixture: an `arm64_darwin` compile of an extern with 10
  integer args (two spills) must still fail with the frozen message —
  as a `# wbuild:` `compile_fail` fixture if it composes with an
  arm64_darwin arch selector, else a hand-written `build.base.json`
  step with `expect_fail` + `expect_stderr` (the `wasm_extern_test`
  reject-step shape).
- Positive compile coverage arrives with PR 1: `graphics_darwin`
  cross-compiles `graphics/gl_texture_test.w`, exercising the 9-arg
  emission path in PR CI.

Gates: `./wbuild verify`, `verify_x64`, `verify_arm64` (compiler
change; no new syntax, so the pinned seed still builds it).
`verify_darwin` and a real 9-arg call at runtime need the Mac
(`tools/mac/run_darwin_tests.sh`) — noted in the PR body rather than
claimed.

## PR 1 — GL texture surface on every backend

Adds the entry points a glyph atlas and UI clipping need, identically
across the three extern surfaces, plus the JS glue.

- [graphics/gl.w](../../graphics/gl.w) — new `gl_constant` entries
  (all below bit 31): `GL_TEXTURE0 = 0x84C0`,
  `GL_TEXTURE_MAG_FILTER = 0x2800`, `GL_TEXTURE_MIN_FILTER = 0x2801`,
  `GL_TEXTURE_WRAP_S = 0x2802`, `GL_TEXTURE_WRAP_T = 0x2803`,
  `GL_NEAREST = 0x2600`, `GL_LINEAR = 0x2601`,
  `GL_CLAMP_TO_EDGE = 0x812F`, `GL_RED = 0x1903`, `GL_R8 = 0x8229`,
  `GL_RGBA8 = 0x8058`, `GL_UNPACK_ALIGNMENT = 0x0CF5`,
  `GL_STREAM_DRAW = 0x88E0`.
- Nine externs added to [graphics/gl_linux.w](../../graphics/gl_linux.w)
  (covers x64/arm64/x86/win64 via `__arch__` dispatch),
  [graphics/gl_web.w](../../graphics/gl_web.w) (`c_lib "env"`), and
  [graphics/__arch__/arm64_darwin/gl_native.w](../../graphics/__arch__/arm64_darwin/gl_native.w)
  (the third copy of the binding, real 9-arg externs per PR 0):

  ```
  extern void glGenTextures(int count, int32* textures)
  extern void glDeleteTextures(int count, int32* textures)
  extern void glBindTexture(int target, int texture)
  extern void glTexImage2D(int target, int level, int internal_format, int width, int height, int border, int format, int pixel_type, char* pixels)
  extern void glTexSubImage2D(int target, int level, int x, int y, int width, int height, int format, int pixel_type, char* pixels)
  extern void glTexParameteri(int target, int pname, int param)
  extern void glActiveTexture(int texture_unit)
  extern void glScissor(int x, int y, int width, int height)
  extern void glBufferSubData(int target, int offset, int size, void* data)
  ```

  (`glScissor` finally makes the pre-existing `GL_SCISSOR_TEST`
  constant usable; `glBufferSubData` enables partial vertex updates
  later.)
- [tools/web/webgl_env.mjs](../../tools/web/webgl_env.mjs) — map all
  nine onto WebGL2: textures through the existing handle table
  (`allocObject`, the `glGenBuffers` shape); `glTexImage2D` /
  `glTexSubImage2D` build a **fresh, sized** `Uint8Array` view
  (`memory.grow` detaches cached views), computing bytes from
  width×height×bpp with bpp 1 for `GL_RED` and 4 for `GL_RGBA`,
  throwing on other formats (the `glReadPixels` guard idiom);
  a zero pointer uploads null (allocation-only). WebGL2 accepts only
  *sized* internal formats, so W callers always pass `GL_R8`/`GL_RGBA8`
  — valid on desktop GL 3.0+ too, and shaders sample `.r`, never `.a`.
- `tools/web/run_webgl_stub.mjs` is untouched: `demo_web.w` calls no
  textures, and both hosts satisfy imports through `makeEnv`, so
  `wasm_webgl_test`'s recorded trace stays green. The texture-capable
  recording fake arrives with PR 5's own gate script.
- New [graphics/gl_texture_test.w](../../graphics/gl_texture_test.w):
  `# wbuild: name=graphics_gl_texture_test arch_only=x64
  expect_stdout="graphics gl texture"`. The `gl_smoke_test.w` shape:
  SKIP-when-no-display (open returns 0 → print
  `graphics gl texture SKIP (no display)`, exit 0); otherwise upload a
  2x2 `GL_R8`/`GL_RED` checker, draw it on a fullscreen quad with
  NEAREST + CLAMP_TO_EDGE and blending enabled, `glReadPixels` the
  quadrants, print `graphics gl texture OK` (or `FAILED` + exit 1).
  Shader bodies compile as GLSL 130/150/300 es (`in`/`out`,
  `texture()`, explicit `out vec4`). GL-linking tests stay x64-only
  (CI has no 32-bit libGL).
- `build.base.json`: `graphics_darwin` gains a compile-only step for
  `graphics/gl_texture_test.w`; then `./wbuild manifest` regenerates
  `build.json` (never hand-edited).

## PR 2 — per-frame input event queue + keycode→char translation

The design doc's stage-1 prerequisite (§7 points 1–2), answered as its
own `graphics/window*` PR (open question 2). Today every backend keeps
"last known state" scalars, so a press+release landing in one poll
collapses; text input is impossible without character translation.

- New pure module `graphics/event.w`:

  ```
  enum gfx_event_kind:
  	GFX_EVENT_NONE = 0
  	GFX_EVENT_KEY_DOWN = 1     # code = backend-native keycode
  	GFX_EVENT_KEY_UP = 2
  	GFX_EVENT_CHAR = 3         # code = ASCII 32..126, or 8/9/13/27
  	GFX_EVENT_MOUSE_DOWN = 4   # code = button 1..3; x,y at event time
  	GFX_EVENT_MOUSE_UP = 5

  struct gfx_event:
  	int32 kind
  	int32 code
  	int32 x
  	int32 y
  ```

  plus fixed-ring helpers operating on a flat `int32[256]` (64 events
  x 4 fields, indices masked with `& 63`, push drops when full) so
  every backend shares push/pop logic through plain pointers.
- Each native backend appends `event_head`/`event_tail`/`event_ring`
  to **its own** `gfx_window` struct (layouts are already
  per-backend) and gains a uniform
  `int gfx_window_next_event(gfx_window* win, gfx_event* out)`.
  The **wasm struct stays frozen** — the host writes its 7 int32
  fields by hardcoded byte offsets (`webgl_env.mjs`,
  `gfx_host_poll_state`) — so `window_web.w` instead drains a
  host-side JS queue through one new import
  `extern int gfx_host_next_event(int32* out)`. The stub backend
  returns 0.
- X11 (`graphics/window_x11.w` + `graphics/x11.w`): bind
  `XLookupString` (the first key-translation extern; the server keymap
  gives shift/layout handling for free) and push `GFX_EVENT_CHAR` for
  printable ASCII + BS/TAB/CR/ESC on KeyPress; push KEY_DOWN/KEY_UP
  (KeyRelease is already in the event mask, currently dropped);
  ButtonPress/Release also update `mouse_x`/`mouse_y` from the event's
  own coordinates (fixes the click-without-motion stale position) and
  push MOUSE_DOWN/MOUSE_UP. Buttons 4/5 (wheel) stay out until stage 2.
- Web: event queue in `tools/web/index.html` (mousedown/mouseup/
  keydown/keyup listeners pushing kinds 4/5/1/2 + CHAR from `e.key`,
  capped, drop-on-full) and the `gfx_host_next_event` mapping in
  `webgl_env.mjs`; `run_webgl_stub.mjs`'s host gains
  `nextEvent: () => null` so the recorded trace is untouched.
- Cocoa: KEY_DOWN pushes where NSEventTypeKeyDown is already decoded;
  CHAR/mouse stay stage 2 (mouse fields are a documented v1 gap, and
  struct-returning selectors are forbidden — the mouse-position
  strategy needs its own design note).
- Test: `graphics/event_test.w`
  (`# wbuild: name=graphics_event_test x64 group=wasm_smoke_test@wasm`
  — pure code, safe under plain WASI): FIFO order, wraparound past 64,
  overflow drop, field fidelity, empty→0.

## PR 3 — `graphics/ui/` core: rect, theme, font, renderer, text

Everything needed to draw themed rectangles and ASCII text in pixel
coordinates. Pure modules never import `graphics.gl`, so their tests
run on every arch including wasm.

- `graphics/ui/rect.w`: `ui_rect {x, y, w, h}` (float32, by-value like
  `vec2`), `ui_rect_new`, `ui_rect_contains`, `ui_rect_inset`.
- `graphics/ui/theme.w`: `ui_color {r, g, b, a}`; `ui_theme` with the
  stage-1 grayscale token set — `background`, `surface`, `border`,
  `text`, `text_muted`, `widget`, `widget_hot`, `widget_active`,
  `accent` — plus metrics `unit = 8`, `text_scale = 2`,
  `widget_height = 32`, `pad = 8`, `gap = 8` (the design doc's 8dp
  grid, §5). `ui_theme_light` / `ui_theme_dark` fill the same token
  names with different values; swapping modes is a pointer swap.
- `tools/ui/font8x8.txt`: the CC0 dhepper/font8x8 glyphs for ASCII
  32..126 as hex text with a provenance/license header.
  `tools/generate_ui_font.w` (the `tools/generate_grapheme_data.w`
  precedent) reads it and emits the **generated, committed**
  `graphics/ui/font_data.w`: 95 glyphs x 8 bytes = 760 bytes as
  `c"\x.."` byte-string chunk functions of ≤256 bytes (the
  `lib/sha256.w` idiom — never int arrays, the bit-31 literal hazard)
  plus metrics accessors and `char* ui_font_glyph_bits(int ch)`.
  A `ui_font_data` regen target in `build.base.json`; drift checked by
  regenerating and diffing in the PR.
- `graphics/ui/font.w`: builds the atlas at runtime — a 128x48
  single-channel buffer, 16x6 cells of 8x8 (cells 0..94 = glyphs
  expanded 1bpp → 0/255, cell 95 = solid white so untextured fills use
  the same shader); UV helpers;
  `int ui_text_width(char* s, int scale)` = `strlen(s) * 8 * scale`
  (`char*` + `s[i]`, the existing `graphics/` string convention).
- `graphics/ui/render.w`: `ui_renderer` — one malloc'd vertex array
  (x,y,u,v,r,g,b,a — 32 bytes/vertex), one shader (bodies compile as
  GLSL 130/150/300 es; fragment
  `frag_color = vec4(v_color.rgb, v_color.a * texture(u_tex, v_uv).r)`),
  y-down pixel projection `mat4_ortho(0, w, h, 0, -1, 1)` matching
  mouse coordinates, atlas uploaded once with
  `glPixelStorei(GL_UNPACK_ALIGNMENT, 1)` + `GL_R8`/`GL_RED`,
  per-frame `glBufferData` with `GL_DYNAMIC_DRAW`, no VAO (matches
  every existing demo). `ui_render_init` (0 on failure),
  `ui_render_init_headless` (records vertices, skips all GL — the unit
  test seam), `ui_render_begin/rect/glyph/end`.
- `graphics/ui/text.w`: `ui_draw_text`, `ui_draw_text_centered`.
- Tests: `graphics/ui/core_test.w`
  (`# wbuild: name=graphics_ui_core_test x64 group=wasm_smoke_test@wasm`;
  rect edge cases, theme token parity, glyph bits for 'A' nonzero /
  ' ' zero, atlas white cell, `ui_text_width`);
  `graphics/ui/render_test.w`
  (`# wbuild: name=graphics_ui_render_test arch_only=x64`; headless:
  one rect + one glyph → `vert_count == 12` and exact first-vertex
  floats). `graphics_darwin` gains a compile-only step for
  `render_test.w`.

## PR 4 — widgets: context, label, button, checkbox

- `graphics/ui/widgets.w`:
  - `ui_input`: mouse snapshot + per-frame `mouse_pressed` /
    `mouse_released` edges and press coordinates, fed from the event
    queue — press+release within one poll registers correctly (§7's
    motivating bug).
  - `ui_context`: renderer*, theme*, input, `hot`/`active` widget ids,
    sequential per-frame id counter (call-order-stable; hash ids are a
    flagged stage-2 refinement), layout cursor (vertical stack,
    `ui_same_line` for rows; widget rects derive from the theme
    metrics).
  - `ui_begin` / `ui_end` / `ui_feed_event` / `ui_begin_window` (the
    only function touching `gfx_window`: drains
    `gfx_window_next_event`, copies the snapshot, starts the frame).
  - `ui_label(ctx, text)`; `int ui_button(ctx, text)` — returns 1 the
    frame it is clicked (release while `active == id && hot`);
    `int ui_checkbox(ctx, text, int32* checked)` — accent-filled inner
    rect when checked.
- Test: `graphics/ui/widgets_test.w`
  (`# wbuild: name=graphics_ui_widgets_test arch_only=x64`) — headless
  scripted frames: no input → 0; press-inside then release-inside →
  click; press-inside release-outside → no click; checkbox toggles
  across two click pairs; vertex batch grows per widget.

## PR 5 — demos and gates: X11 + wasm from one widget source

- `graphics/ui/demo_shared.w`: the whole form once —
  `ui_label(c"W UI demo")`, a click-counter button that prints
  `ui demo clicks: N`, a dark-mode checkbox swapping the active theme
  pointer (prototyping stage 3's toggle). Layout constants (window
  320x240, button rect, scripted click point) documented here and
  relied on by both gates.
- `graphics/ui/demo.w`: native driver, `demo.w`-shaped (`--frames N`,
  poll/swap/`sleep_ms(16)` loop).
- `graphics/ui/demo_web.w`: wasm driver, `demo_web.w`-shaped
  (file-scope globals, frame fn registered via `gfx_window_run`).
  Stronger than the existing demo pair: the form itself is shared
  source, not copied.
- `graphics/ui/smoke_test.w`
  (`# wbuild: name=graphics_ui_smoke_test arch_only=x64
  expect_stdout="graphics ui smoke"`): SKIP-when-no-display; one full
  frame, then tolerance-based `glReadPixels` probes (GL y counts from
  the bottom): button interior ≈ `widget` gray, far corner ≈
  `background`, and at least one of several samples across the label
  row ≈ `text` color (no bitmap-exact positions).
- `tools/web/run_ui_stub.mjs`: a **new** gate script (the existing
  `run_webgl_stub.mjs` asserts `demo_web.w`'s exact trace — not
  repurposed): texture-capable recording fake GL (missing methods
  throw — the safety net that catches unmapped entry points), a
  scripted host whose `nextEvent` delivers MOUSE_DOWN then MOUSE_UP at
  the documented button point across frames 2–3, asserts one 128x48
  `GL_R8` upload, one program link, per-frame draws, and the click
  itself via the step-level `expect_stdout`.
- `build.base.json`: new `wasm_ui_test` target (the `wasm_webgl_test`
  shape): compile `graphics/ui/demo_web.w`, run
  `tools/web/run_ui_stub.mjs --frames 4`,
  `expect_stdout: "ui demo clicks: 1"`. Stays outside the `tests`
  umbrella (Node-bound, like every wasm gate; release-time coverage
  alongside `verify_wasm`). `graphics_darwin` gains compile-only steps
  for `demo.w` and `smoke_test.w`.
- `docs/projects/ui_framework.md` status line updated to "stage 1
  implemented"; optional `package.wmeta` entries for the new modules
  (the check is one-directional).

Browser eyeball check:
`./bin/wv2 wasm graphics/ui/demo_web.w -o bin/graphics_ui_demo.wasm`,
serve the repo, open
`tools/web/?module=/bin/graphics_ui_demo.wasm`.

## Stage 2 and beyond (sketch — each its own PR, per design doc §8)

- **Stage 2** (implemented 2026-08-07): single-line text input
  (caller-owned `ui_textbox_state` consuming `GFX_EVENT_CHAR` +
  backspace/arrows — the PR 2 queue makes this widget-local; arrows
  arrive as the portable `GFX_EVENT_NAV`, since raw keycodes are
  backend-native), radio group, dropdown (overlay list via a renderer
  overlay batch + a ctx.modal popup claim — `glScissor` turned out
  unneeded), progress bar, toggle; scroll wheel (X11 buttons 4/5 →
  `GFX_EVENT_SCROLL`, a JS `wheel` listener). Cocoa mouse + CHAR
  stays deferred (needs a selector strategy that avoids struct
  returns — flagged for its own note).
- **Stage 3** (implemented 2026-08-07): full theme token set
  (accent_hot, on_accent, focus, disabled_widget/disabled_text + a
  `ui_disable` scope), the demo dropdown as a runtime light/dark/ocean
  theme picker, and `ui_theme_ocean` as the non-grayscale example
  theme.
- **Stage 4+**: TTF/SDF fonts (issue #379), a win64 window backend,
  accessibility — each a future design doc.

## Risks

- `GL_R8`/`GL_RED` needs GL 3.0 on the GLX compat context — fine on
  Mesa; the fallback is an RGBA8 atlas (4x memory, no API change).
- The PR 0 spill relaxation is compile-time-proven in CI
  (`graphics_darwin` cross-compiles) but runtime-proven only on real
  Darwin hardware via `tools/mac/run_darwin_tests.sh`.
- Event-kind constants are duplicated between `graphics/event.w` and
  the JS hosts — mitigated by cross-referencing comments; 6 values do
  not justify a generated constants file.
- The wasm UI gate hardcodes the demo's documented button coordinates
  — accepted coupling, localized to `demo_shared.w`'s comment block.
