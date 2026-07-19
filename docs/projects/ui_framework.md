# A cross-platform UI framework for W

Design assessment for issue #334: "Create a w UI framework that can be
run anywhere - desktop, mobile, web. Need elements of all these that
can be seamlessly integrated. Need Forms and form elements. Wanted:
minimal, modern, material design. Black/white/grayscale color scheme
by default, but fully customizable, including dark/light modes."
Companion to `docs/projects/graphics.md` (the module this framework
builds on) and `docs/projects/wasm_webgl.md` (the wasm/WebGL path that
is this framework's web backend). Follows the same survey →
options → staged-recommendation shape as `docs/projects/compress.md`
and `docs/projects/wbuildd.md`.

Status: design only, 2026-07-18. No code changes ship with this file.

## 0. Where this framework would live, and what it does not replace

`graphics.md`'s own "Next steps" section already names this project in
one line: "UI layer: immediate-mode widgets on top of the 2D layer and
the existing input state on `gfx_window`." This doc is that project,
worked out in detail. The natural home is a new `graphics/ui/` tree
(`graphics/ui/theme.w`, `graphics/ui/text.w`, `graphics/ui/widgets.w`,
...), a sibling of `graphics/math`, `graphics/gl`, `graphics/window` —
not a new top-level directory, since every widget draws through
`graphics.gl` and polls input through `graphics.window`'s existing
`gfx_window` contract. Like `graphics/` itself, none of this enters
`w.w`'s transitive import closure (confirmed by grep: `w.w` does not
import `graphics`), so it is a **leaf consumer** — current W syntax is
fine throughout, no `SEEDS` bump implicated, same status
`libs/extras/compress` and `libs/extras/vcs` already have.

**Explicitly out of scope for this doc, a different project**:
`docs/ui.txt` sketches a *different* "web ui" — a browser front end for
the compiler's own tooling (a CodeMirror-based editor, a debugger, a
REPL terminal, driven by a websocket "repl server" over
`libs/standard/web/http_server.w`, per `docs/projects/repl_improvements.md`
and `docs/projects/wbuildd.md` §5 stage 3/§6 point 3). That is
dev-tooling chrome for *this repository*, transported over HTTP/
websockets, and it depends on the still-undecided wbuildd design. Issue
#334 asks for something else: a UI framework **W programs** use to
build their own apps (forms, buttons, windows), rendered the same way
`graphics/demo.w` renders its triangle. The two could someday share a
widget-drawing layer if the REPL web UI is ever rendered to a wasm
canvas instead of the DOM, but that is speculative and not assumed
here. This doc does not touch `libs/standard/web/` design; it is cited
only in §3 to rule out a DOM-based alternative.

## 1. What "runs anywhere" means against this repo's actual targets

The compiler emits six targets today (`CLAUDE.md`): x86 and x64 Linux
ELF, arm64 Linux ELF, `arm64_darwin` Mach-O, win64 PE, and wasm32/WASI.
`graphics/window.w` already dispatches per-target through
`graphics/__arch__/<target>/window_native.w`; verified current state of
that dispatch (each file read directly):

| Target | Window backend | Input tracked | Status |
|---|---|---|---|
| x64 Linux | `graphics.window_x11` (X11/GLX) | mouse x/y, 3-button mask, last keycode, resize/close | real, tested (`graphics_gl_smoke_test`) |
| arm64 Linux | `graphics.window_x11` (same file) | same as x64 | real, needs qemu to run in CI |
| `arm64_darwin` | `graphics.window_cocoa` (AppKit/NSOpenGL) | last keycode only — **mouse fields stay 0 in v1** (`graphics/window_cocoa.w:17`) | real but input-incomplete |
| wasm32 (browser) | `graphics.window_web` (canvas + WebGL2 via `tools/web/webgl_env.mjs`) | 7-field snapshot: width, height, should_close, mouse_x, mouse_y, mouse_buttons, last_keycode (`graphics/window_web.w:59`-`60`) | real, tested (`wasm_webgl_test`), needs Node or a browser |
| win64 | `graphics.window_stub` (`graphics/__arch__/win64/window_native.w` imports it directly) | none — `gfx_window_open` prints a gap message and returns 0 | **no backend at all** |
| x86 Linux | `graphics.window_stub` | none | **no backend at all** (32-bit is the seed/bootstrap target, not expected to grow a GUI) |

Two things this table settles up front: **"desktop" today means Linux
(X11) and macOS (Cocoa) only** — win64 has an OpenGL binding
(`graphics/__arch__/win64/gl_native.w` imports the same `graphics.gl_linux`
externs, which is almost certainly a placeholder, since win64 has no
`libGL.so`/GLX and no window to make a context current in) but no real
window or input path, so it is unusable for a UI today, not merely
input-incomplete like macOS. And **"mobile" does not exist as a
compile target in this repo at all** — no iOS or Android backend, and
none is close: iOS requires sandboxed, App-Store-signed Mach-O with no
JIT and a UIKit-not-AppKit event model; Android requires an entirely
different (Linux-kernel-but-not-glibc, Java/NDK-hosted) launch story.
The only realistic "mobile" story for v1 is the existing wasm/WebGL2
canvas path running inside a mobile browser — same artifact as the
desktop-web target, not a separate mobile backend. §8's non-goals
section states this plainly rather than implying mobile is one release
away.

## 2. Capability inventory: what `graphics/` gives you today

Read directly, not inferred: `graphics/math.w`, `graphics/gl.w`,
`graphics/gl_linux.w`, `graphics/gl_web.w`, `graphics/window.w`,
`graphics/window_x11.w`, `graphics/window_cocoa.w`, `graphics/window_web.w`,
`graphics/window_stub.w`, `graphics/demo.w`, `graphics/demo_web.w`.

**What exists**:
- A full GLM-style `vec2`/`vec3`/`vec4`/`mat4`/`quat` math library, pure
  W, no libm — usable for 2D layout math (rects, transforms) as-is.
- Core GL bindings (buffers, shaders compiled from string sources at
  runtime, draw calls) on every real backend, plus the wasm target's
  WebGL2 mapping (`graphics/gl_web.w` + `tools/web/webgl_env.mjs`).
- A `gfx_window` struct with a uniform four-call contract
  (`open`/`poll`/`swap`/`destroy`) across backends, plus `gfx_window_run`
  for the wasm target's inverted (host-driven, requestAnimationFrame)
  control flow — the exact abstraction a widget framework's event loop
  would sit on, already proven to compile the *same* draw code
  (`graphics/demo.w` vs `graphics/demo_web.w` differ only in how the
  frame is driven, not in a single GL call).
- A working, tested "headless-safe" pattern
  (`graphics_gl_smoke_test`'s SKIP-when-no-display convention) for
  gating any new visual test in CI without a real display.

**What is verified absent** (grep confirms zero hits repo-wide for
`truetype`/`freetype`/`font`/`glyph` outside an unrelated errno string
`"EBFONT: Bad font file format"` in `lib/lib.w:687` and unrelated
homoglyph/confusables discussion in `docs/projects/utf8_source.md`; and
zero hits for `widget`/`material design`/`design token`/`imgui` outside
`graphics.md`'s own one-line future-work mention):

1. **No text or font rendering of any kind.** Not bitmap, not vector,
   not even a hardcoded 8x8 glyph table. This is the single biggest gap
   for a *forms* framework specifically — every form element (label,
   button caption, text input's own contents) needs to draw characters.
   §6 assesses this in depth; it is this doc's central open problem.
2. **No layout engine.** Every vertex in `graphics/demo.w` is a literal
   float in NDC space. There is no rect model, no flex/stack/grid
   arrangement, no notion of a widget's bounding box, no text
   measurement (which requires the font work in (1) to even define).
3. **No widget code at all**, immediate- or retained-mode. `graphics.md`
   names this as unstarted future work, not partially started.
4. **Incomplete, inconsistent input across backends** — detailed in §7:
   only "last" state (not an event queue) anywhere, no text-input
   events (only raw keycodes, no keysym-to-Unicode translation, no
   IME), no scroll wheel on any backend, no touch/pointer-gesture
   events (moot until a real mobile/touch target exists), and macOS
   mouse tracking is simply not implemented yet (`window_cocoa.w:17`).
5. **No accessibility surface whatsoever** — no focus order, no screen
   reader hooks, no semantic roles, nothing to build on; a custom
   GL-rendered UI (as opposed to native platform widgets or DOM
   elements) starts an accessibility story from zero on every backend
   except the web one, where the DOM canvas element itself is opaque to
   assistive tech unless a parallel accessibility tree is built by
   hand. Flagged as a later-phase problem in §9, not solved here.

This inventory is the honest headline: **the plumbing (GL, math,
windowing, input polling, a build/test pattern) is solid across three
real targets; the actual UI — text, layout, widgets, theming — is
100% unbuilt.** Nothing below should be read as "mostly there, needs
polish"; it needs the whole stack built starting from rectangles.

## 3. Architecture options

### (a) Immediate-mode (dear imgui style) over the existing graphics layer

Widgets are function calls made every frame (`ui_button(rect, "OK")`
returns true the frame it's clicked), no retained tree, no allocation
per widget beyond a per-frame scratch arena. State that must persist
across frames (a text field's cursor position, a checkbox's checked
value) lives in caller-owned structs, exactly like the caller-owned
`gfx_window` today.

- **Fits the tiny-toolchain philosophy directly**: no scene graph, no
  diffing/reconciliation, no allocator pressure beyond one arena reset
  per frame — the same "boring, explicit, no magic" posture
  `graphics.md`'s hand-rolled math library and `compress.md`'s
  from-scratch DEFLATE both already commit to instead of binding a C
  library.
- **Composes with the existing `gfx_window` poll loop with zero new
  abstraction**: a frame is already "poll, draw stuff, swap" on every
  backend including the web's inverted callback shape: `ui_button` is
  just more drawing between `gfx_window_poll` and `gfx_window_swap`.
- **Cost**: immediate-mode UIs recompute layout every frame (cheap at
  this scale — a form has dozens of widgets, not thousands) and put
  more of the "what changed" logic on the caller. Text input in
  particular is the traditionally awkward corner of imgui-style
  frameworks (owning a cursor/selection state across frames without a
  retained node) — solvable, but worth flagging as the widget that
  will take the most design care in stage 2.

### (b) Retained-mode widget tree with per-platform render backends

A `ui_node` tree (parent/child, style, event handlers) persisted across
frames, diffed or dirty-flagged, walked by a separate renderer per
target — potentially a *native* renderer per platform (real X11
widgets, real AppKit controls, real DOM elements on web) rather than
one GL renderer everywhere.

- **Rejected as the primary design.** A native-widget-per-platform
  renderer is the opposite of "seamlessly integrated" — it means
  building (and keeping visually consistent) three to four completely
  different widget toolkits' worth of code, each with its own theming
  API, sizing quirks, and font-rendering story already solved by the
  host platform but at the cost of losing this repo's "one small
  compiler, no external deps" identity: an AppKit or Win32 backend
  is exactly the kind of large per-platform native dependency this
  project has avoided everywhere else (the graphics module itself
  binds AppKit only for the *window and GL context*, deliberately not
  reaching for `NSButton`/`NSTextField`).
- A GL-rendered retained tree (same renderer as (a), just with a
  persisted node graph instead of per-frame calls) is a legitimate
  *later* evolution of (a) once real apps expose where per-frame
  layout recomputation actually costs something — not a reason to
  start there. Framed as stage-2-or-later in §8, not a competing v1
  option.

### (c) Web-first: render to HTML/canvas via wasm, desktop embeds a webview

Ship one DOM/CSS-driven renderer; desktop "runs" the same UI by
embedding a system webview (WebKitGTK on Linux, WKWebView on macOS,
WebView2 on Windows) instead of a native window.

- **Rejected.** A webview is exactly the kind of large external runtime
  dependency this project's whole toolchain (statically linked, no
  libc, no assembler/linker, no external UI runtime) exists to avoid —
  it would make "run the UI" depend on a system component `wbuild`
  cannot vendor, verify, or reason about, breaking the "self-hosting,
  sha256-pinned seed" trust model even though the *compiler* itself
  wouldn't be touched. It also means writing and maintaining a second,
  fundamentally different renderer (HTML/CSS layout) purely for the
  embed case, alongside the GL renderer the already-working wasm/WebGL2
  path needs anyway for the actual browser target — double the surface
  for a worse fit.
- **What's worth keeping from (c)**: the *web target itself*. It
  already exists and already works end to end
  (`wasm_webgl_test`, `tools/web/index.html`) — a GL-rendered UI on
  wasm/WebGL2 is not a hypothetical, it is `graphics/demo_web.w` with
  widgets drawn instead of a triangle. That is folded into the
  recommendation below, not treated as a separate track.

### Recommendation

**(a), immediate-mode, one GL renderer shared by every real backend**
(X11 desktop, Cocoa desktop, wasm/WebGL2 web/"mobile"), built as
`graphics/ui/*.w`. This is the only option that does not add an
external dependency, does not fork into per-platform toolkits, and
reuses 100% of the already-tested `gfx_window`/`graphics.gl` plumbing.
"Seamlessly integrated" is delivered by writing widget code once
against the existing `gfx_window`/GL abstraction that already compiles
unchanged across x64/arm64/wasm (proven today by `demo.w`/`demo_web.w`
sharing every draw call) — not by a new cross-platform abstraction this
project would have to invent. win64 and true mobile stay non-goals
(§9) until a native window backend exists for the former and forever
for the latter (native mobile is not a target this compiler produces
at all, per §1).

## 4. Forms/widgets v1 set

Scoped to what stage 1's font-and-layout foundation (§6, §8) can
actually support without the widget list itself becoming the
long pole. All GL-rendered rectangles/quads plus the bitmap-font glyphs
from §6:

- **Layout containers**: fixed rect, horizontal stack, vertical stack
  (a "row"/"column" pair is enough for v1 — no flex-grow/wrap
  negotiation yet).
- **Static**: label (text), spacer/divider, panel/card background.
- **Forms** (the issue's explicit ask): button, checkbox, radio button
  (single-select group), single-line text input (with a blinking
  caret; multi-line and IME are §9 non-goals), and a dropdown/select
  (closed-state box + an open-state list rendered as an overlay of the
  same widgets — no separate popup-window primitive needed since
  everything already renders into the one `gfx_window`).
- **Feedback**: a plain progress bar and a toggle/switch (both are
  visually simple rects, cheap wins that round out "forms" into
  something demo-able).

A slider and a scrollable list are natural stage-2 adds (both need a
drag-state model the input work in §7 should design for even if they
ship later). Multi-line text areas, date pickers, color pickers, and
anything requiring platform-native affordances (a real OS file picker
dialog) are explicitly deferred — each is its own small design problem
once the base widgets exist.

## 5. Theming: grayscale/material default, dark/light, fully customizable

The issue's ask decomposes cleanly into two independent layers:

1. **A material-inspired *shape and spacing* language**: flat fills
   (no bevels/gradients/skeuomorphism), a small fixed corner-radius
   scale, a consistent spacing/sizing scale (e.g. a single `unit`
   constant — 8px-equivalent in NDC-relative terms — with widget
   paddings expressed as small integer multiples of it, the way
   Material Design's 8dp grid works), and a one-level elevation model
   (flat vs. "raised" — a subtle border or fill-shade change, not a
   drop-shadow renderer, which is out of scope for v1's GL primitives).
2. **A *design-token* color layer**, fully separate from (1): a
   `ui_theme` struct holding named colors (`background`, `surface`,
   `on_surface_text`, `border`, `accent`, `disabled`, ...) that every
   widget-drawing function reads through instead of hardcoding a color.
   The default theme is pure grayscale (black/white/gray steps, per the
   issue's explicit ask), with a single `accent` token as the only
   allowed non-gray default color (Material's convention of one
   accent color against a neutral field maps directly onto "minimal,
   modern, grayscale by default"). Dark/light mode is two token sets
   sharing the same token *names* (so widget code never branches on
   mode, only the active `ui_theme*` pointer changes) — swapping modes
   at runtime is a pointer swap plus a redraw, not a recompile.
   Full customization is "supply your own `ui_theme`" — no separate
   theming DSL, config file format, or runtime style-sheet parser for
   v1; a theme is just a W struct literal, which is also the simplest
   possible thing to make fully typo-proof at compile time (a missing
   token is a compile error, not a silently-missing CSS rule).

This mirrors `graphics.md`'s own math module precedent: a small,
explicit, struct-based API (like `mat4`/`vec3`) rather than a rules
engine — a `ui_theme` is data, applying it is a function reading fields,
nothing more.

## 6. Font strategy — the biggest missing piece, assessed honestly

Three real options, assessed for cost and fit rather than picked by
default:

1. **Fixed-size bitmap font, baked as data.** A single monospace glyph
   set (ASCII, maybe Latin-1) stored as a packed bitmap (1 bit or 1
   byte per pixel per glyph, in a small fixed cell size like 8x16),
   compiled in as a data array the way `lib/sha256.w` embeds its
   constant tables. Rendering a glyph is: look up its cell in the
   bitmap, upload it as (or blit into) a texture, draw a textured
   quad. No parsing, no curve math, no hinting — genuinely a few
   hundred lines including the texture-atlas packing.
   - **Pros**: buildable in stage 1, on every target including wasm
     (a texture atlas is just bytes plus `glTexImage2D`, already an
     "extend `gl_web.w`" item `wasm_webgl.md`'s own Deferred section
     already names). Crisp, "minimal/modern" reads fine at fixed UI
     sizes — plenty of real UI toolkits (early GUIs, terminal-style
     modern tools) ship exactly this look on purpose.
   - **Cons**: no arbitrary font sizes (a "modern" look often wants a
     couple of type-scale steps — this can be approximated by baking
     2-3 fixed cell sizes rather than one, at proportional cost), no
     custom/branded fonts, no non-Latin scripts without growing the
     baked glyph set considerably.
2. **A from-scratch TTF/OTF rasterizer** (stb_truetype-style: parse
   `glyf`/`loca`/`cmap` tables, rasterize quadratic Bézier outlines to
   a coverage bitmap, cache glyphs in a runtime-built atlas). This is
   consistent with the repo's stated posture (no libc/libm, no bound
   C library — `sha256.w`, `libs/extras/compress`, and the math module
   all reimplement rather than bind), and would be the "real" long-term
   answer: arbitrary fonts, arbitrary sizes, proper metrics.
   - **Honest sizing**: this is not a small side task. A workable
     subset (glyph outline extraction + scanline/coverage rasterization
     + a dynamic atlas + basic kerning) is realistically a
     multi-hundred-to-low-thousand-line project on its own — comparable
     in shape to `libs/extras/compress`'s own "~1-2k lines, budget
     accordingly, split into staged PRs" framing, not something to fold
     into UI stage 1 as a subtask. Full OpenType feature support
     (ligatures, complex script shaping, hinting) is far larger still
     and is not being proposed here.
3. **Signed-distance-field (SDF) font atlas**, generated offline from a
   TTF by a *separate, one-time* tool (not shipped in the compiler's
   runtime path) and checked in as baked texture data plus a metrics
   table — rendering then only needs a small SDF fragment shader, no
   rasterizer in W at all.
   - **Pros**: scales cleanly to any size from one baked atlas
     (SDF's whole point), better "modern" typography than option 1's
     fixed bitmaps, and the runtime cost is close to option 1's (one
     texture, one shader) rather than option 2's (a rasterizer).
   - **Cons**: the *offline generator* is still real work (whether
     hand-written once in W/Python/anything, or borrowing an existing
     `msdfgen`-style algorithm's math), and still needs a real font's
     glyph outlines as input from somewhere — it does not remove the
     "where do glyph shapes come from" question, it relocates it out
     of the hot path.

**Recommendation: option 1 (baked bitmap font, 1-2 fixed cell sizes)
for stage 1**, explicitly as a placeholder, not a final answer — it
unblocks every widget in §4 (all of them need to draw *some* text) at
a cost of days, not weeks, and matches "minimal" honestly rather than
apologetically. **Option 2 or 3 is the right follow-up**, scoped as its
own design doc once stage 1's widgets exist and real usage shows
whether fixed-size bitmap text is actually the limiting factor (it may
not be, for a genuinely minimal/grayscale aesthetic) — deciding between
2 and 3 up front, before any UI widget exists to motivate it, would be
premature. This doc explicitly does not pick between them; it only
rules out "bind an existing rasterizer" (freetype, stb_truetype.h as a
vendored C header) as inconsistent with every other library decision
this repo has made.

## 7. Event/input model per platform

Read directly from each backend (§1's table cites the exact structs).
Today's model everywhere is **"last known state," not an event
queue**: `gfx_window` stores `mouse_x`/`mouse_y`/`mouse_buttons`/
`last_keycode` as plain fields, overwritten on each new event during
`gfx_window_poll`. This is suffient for a spinning-triangle demo but
has a real consequence for forms: **two key presses (or a
press-then-release) that land in the same poll cycle collapse into
one observed state** — a fast typist's keystrokes can be lost. A
widget framework needs at minimum a small per-frame event queue
(`[]{type, code/button, x, y}`) rather than scalar "last" fields, which
is a `gfx_window` change every backend must make consistently — flagged
here as a stage-1 prerequisite, not an incidental nice-to-have.

- **X11 (x64/arm64 Linux)**: the most complete backend — button-down/up
  with correct bit tracking (`window_x11.w:118`-`126`), motion, resize,
  close via `WM_DELETE_WINDOW`. Still missing: scroll wheel (X11 reports
  wheel as synthetic button 4/5 press events, unhandled today), and
  keycode-to-Unicode translation (`XLookupString`/keysym tables) for
  actual text entry — `last_keycode` is a raw X keycode, not a
  character, so a naive text-input widget cannot currently render what
  was typed beyond mapping a hardcoded keycode-to-ASCII table by hand.
- **macOS (`arm64_darwin`, Cocoa)**: keycode tracked
  (`window_cocoa.w:151`-`152`), but **mouse position and buttons are
  not implemented at all yet** ("Mouse fields stay 0 in v1,"
  `window_cocoa.w:17`) — a real, not cosmetic, gap: no macOS widget can
  detect a click until this lands. Same missing-text-translation gap as
  X11 (`keyCode` is a raw HID scancode, not a character).
- **Web (wasm/WebGL2)**: the *widest* snapshot today (7 fields,
  `window_web.w:59`-`60`) but the *narrowest* actual event coverage —
  `wasm_webgl.md`'s own Deferred section already states "Keyboard/mouse
  callback events (state polling covers the demos; event callbacks are
  D2-ready when wanted)" — meaning the plumbing (the D2 table-callback
  contract) exists and is proven for the frame-callback use case, but
  no keyboard/mouse *callback* is wired yet, only the polled snapshot.
  No scroll wheel, no text input (`beforeinput`/`keydown` composition
  events), no touch events at all.
- **win64**: no backend, no input, full stop (§1).
- **Mobile (no compile target)**: not applicable — see §1/§9. If the
  wasm/WebGL2 path is ever run inside a mobile browser, the "web" row
  above already covers it, but touch (as distinct from mouse) events
  are entirely unaddressed in that row too.

**What a UI framework needs beyond today's polling model**, in priority
order for forms specifically: (1) a real per-frame event queue instead
of "last" scalars, (2) keycode-to-character translation for text input
on every native backend (the web backend gets this closer to free via
`document`-level `keydown`/`input` events once wired), (3) a completed
macOS mouse path, (4) scroll wheel on every backend. None of this is
started; §8 stages (1) and (2) into stage 1 itself since text input is
in the v1 widget list (§4) and cannot work without them.

## 8. Staged plan

1. **Stage 1 — small, testable foundation.** `graphics/ui/` gains:
   a rect/layout primitive (axis-aligned rects, row/column stacking,
   §4's containers), the baked bitmap font (§6 option 1) plus a
   `ui_draw_text(rect, string, theme)` primitive, the per-frame input
   queue and keycode-to-character table (§7 points 1-2) on the X11
   backend first (the most complete one today), and exactly three
   widgets: label, button, checkbox — chosen as the smallest set that
   exercises layout, static text, click detection, and toggled state
   without yet needing the harder text-input caret/selection work.
   Ships as an X11 demo *and* a wasm/WebGL2 demo from the same widget
   source (mirroring `demo.w`/`demo_web.w`'s existing split — only the
   window-driving `main`/frame-callback shape differs, exactly as
   today). Tested with the same SKIP-when-no-display convention
   `graphics_gl_smoke_test` already established, plus the recording
   fake-WebGL2 harness (`tools/web/run_webgl_stub.mjs`) for the wasm
   twin — no new test infrastructure needed, both patterns already
   exist and are proven.
2. **Stage 2 — the rest of the forms v1 set.** Text input (now that
   stage 1's input queue and char translation exist), radio groups,
   dropdown, progress/toggle (§4's remaining widgets). Extend input
   completeness to macOS (mouse tracking) and add scroll wheel on X11
   and web. Revisit immediate- vs. retained-mode (§3(b)) with real
   usage data — only now, not before there is a widget set to profile.
3. **Stage 3 — theming depth.** The full `ui_theme` token set (§5),
   dark/light toggle wired to a live demo, and a second non-grayscale
   example theme proving the "fully customizable" claim isn't only
   theoretical.
4. **Stage 4 and beyond, each its own future design doc**: the
   TTF/SDF font follow-up (§6), a win64 native window backend (blocks
   any win64 UI at all — currently a stub, §1), accessibility semantics
   (§9), and a retained-mode evolution if stage 2's usage motivates it.

## 9. Non-goals for v1

- **Native mobile app packaging** (iOS/Android). Not a compile target
  today (§1) and not proposed here; the wasm/WebGL2 web target running
  in a mobile browser is the only "mobile" story in scope.
- **Accessibility depth** (screen readers, semantic roles, platform
  a11y APIs). §2 point 5 stands: this starts from zero and needs its
  own design once there is a widget tree to attach semantics to.
- **A general animation/transition system.** Flat, static widget
  states only for v1 — matches "minimal" and avoids a whole extra
  design axis (easing, timelines) before the base widgets exist.
- **Rich text, multi-line text areas, IME, complex script shaping,
  RTL.** Single-line ASCII/Latin-1 text entry only (§6, §7).
- **A styling DSL, theme file format, or hot-reloadable stylesheet.**
  A theme is a W struct (§5) — no new file format or parser.
- **win64 and x86 UI support.** Both are stub backends today (§1); a
  real win64 window/input backend is a prerequisite this doc does not
  scope, and x86 is the seed/bootstrap target, not expected to grow a
  GUI at all.
- **A retained-mode / scene-graph renderer.** §3 explicitly stages this
  as a possible post-v1 evolution of the immediate-mode design, not a
  v1 deliverable.

## 10. Open questions for the maintainer

1. **Bitmap font glyph coverage**: ASCII-only for stage 1, or is
   Latin-1/basic accented-character coverage worth the extra baked
   glyphs up front, given `docs/projects/utf8_source.md` shows this
   repo already takes UTF-8 source text seriously? Recommend
   ASCII-only for stage 1 (labels/buttons in English demos) with
   Latin-1 as a cheap stage-2 add, but this is a product decision, not
   a technical one.
2. **Where does the per-frame input-event-queue change to `gfx_window`
   live?** It is a `graphics.window` (not `graphics.ui`) change, since
   every backend's struct needs it — should it land as a `graphics/`
   PR ahead of and independent from `graphics/ui/`, given it also
   benefits any future non-UI consumer of `gfx_window` (games, tools)?
   This doc assumes yes (staged as part of stage 1, but as a distinct
   commit/PR against `graphics/window*.w`) but flags it explicitly
   since it is the one piece of stage 1 that touches already-shipped,
   tested code rather than only adding new files.
3. **Is a win64 window/input backend worth prioritizing** specifically
   to unblock UI framework parity, or does it stay deprioritized
   indefinitely as it is today (§1)? This doc takes no position beyond
   flagging that "runs anywhere" currently cannot include Windows at
   all until this exists, independent of anything in this doc.
4. **SDF vs. from-scratch TTF rasterizer for the post-v1 font work**
   (§6, options 2 vs. 3) — worth a maintainer steer now on which
   direction is preferred long-term, even though this doc recommends
   deferring the actual decision until stage 1's bitmap-font placeholder
   has real usage to learn from?
5. **Should `graphics/ui/` widgets be react-like (pure functions of a
   theme + state struct, per this doc's immediate-mode recommendation)
   or is there an appetite for exploring a declarative/retained
   builder syntax sooner**, given W's ongoing ergonomics work
   (`docs/projects/golf_ergonomics.md`, `docs/projects/protocol_ergonomics.md`)
   might make a nicer widget-tree-construction syntax feasible earlier
   than "only once stage 2 usage data exists"? This doc's
   recommendation (§3) is conservative on purpose; flagging in case the
   maintainer wants to bet earlier on retained-mode.
