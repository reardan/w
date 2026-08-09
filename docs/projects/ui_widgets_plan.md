# Widget expansion: round-1 implementation plan

Execution plan for issue #441, implementing the foundation round of
[docs/projects/ui_widgets.md](ui_widgets.md). The design doc is the
authority on *what* and *why*; this doc pins *how*: the commit
sequence, exact files, API shapes, and gates. Each commit lands green
on its own (`./wbuild tests`, plus the Node-bound wasm gates run
locally).

Maintainer decisions folded in (2026-08-09):

- **Foundation first.** This round lands the four missing pieces of
  foundation plus the three widgets that prove them (Modal, Table,
  Textarea). The other fourteen items in the issue get the staged
  roadmap in the design doc §6, not code.
- **Events as their own commit.** Modifier flags and the editor NAV
  codes touch `graphics/event.w` and all four window backends, so they
  land ahead of the UI work — the same call issue #334 made for the
  event queue itself (that doc's open question 2).
- **Email is a validated text field**: a `ui_textbox` variant with an
  email-shaped validator and an inline error state, sharing a
  validation hook with Form. Deferred to the Form round.
- **Docs first**, then one commit per stage.

Commit sequence: 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8.

**Status: all nine stages landed 2026-08-09.** Where the shipped code
diverged from the plan below, the divergence is recorded in the
stage's own section under *Landed*; the plan text itself is left as
written so the two can be compared.

## Why this order

Stage 1 is first because it is the only change to already-shipped,
tested code and because Textarea cannot exist without it. Stage 2 is a
pure code move, so it is reviewable as a move and cannot regress
anything. Stages 3-7 are strictly additive foundation, each with its
own headless test. Stage 8's widgets are the first thing that could not
have been written before, which is the point of the ordering.

## Stage 0 — docs

- `docs/projects/ui_widgets.md` — the design assessment.
- `docs/projects/ui_widgets_plan.md` — this file.
- `docs/projects/ui_framework.md` status paragraph points at both.

No code, no gates beyond the repo's doc conventions.

## Stage 1 — `graphics/event.w`: modifiers, editor nav codes, wider ring

**`graphics/event.w`**

```
enum gfx_mod:
	GFX_MOD_SHIFT = 1
	GFX_MOD_CTRL = 2
	GFX_MOD_ALT = 4
	GFX_MOD_SUPER = 8

struct gfx_event:
	int32 kind
	int32 code
	int32 x
	int32 y
	int32 mods
```

`enum gfx_nav_code` gains `GFX_NAV_UP = 5`, `GFX_NAV_DOWN = 6`,
`GFX_NAV_PAGE_UP = 7`, `GFX_NAV_PAGE_DOWN = 8`, `GFX_NAV_DELETE = 9`.

Ring stride 4 → 5 int32s per slot. `gfx_event_ring_capacity()` stays
64, so the `& 63` index masks are untouched; `gfx_event_ring_ints()`
returns 320. `gfx_event_ring_push` gains a trailing `int mods`
parameter and `gfx_event_ring_next` fills `out.mods`.

**Backends** — each widens its own `int32[256] event_ring` to `[320]`:

- `graphics/window_x11.w`: read `event.input.state` (the field exists
  at `graphics/x11.w:110` and is currently never read) and translate
  the X mask — `ShiftMask` 1, `ControlMask` 4, `Mod1Mask` 8 — into
  `gfx_mod` bits on every key and button push. Extend the keysym
  mapping at `window_x11.w:136-142` with `Up 0xff52`, `Down 0xff54`,
  `Page_Up 0xff55`, `Page_Down 0xff56`, `Delete 0xffff`.
- `graphics/window_web.w` + `tools/web/index.html` +
  `tools/web/webgl_env.mjs`: `pushEvent(kind, code, x, y)`
  (`index.html:62`) gains a `mods` argument built from
  `e.shiftKey/ctrlKey/altKey/metaKey`; the `keydown` nav mapping
  (`index.html:91`) gains `ArrowUp`/`ArrowDown`/`PageUp`/`PageDown`/
  `Delete`; `gfx_host_next_event` (`webgl_env.mjs:244`) writes a fifth
  int32 through its `DataView`, and the host-contract comment at
  `webgl_env.mjs:26` updates with it.
- `graphics/window_cocoa.w`: `modifierFlags` on the already-decoded
  `NSEventTypeKeyDown` path. Mouse and CHAR remain the documented v1
  gap.
- `graphics/window_stub.w`: struct width only.

**Tests**: `graphics/event_test.w` pins `gfx_event_ring_ints()` and the
NAV values — update in the same commit and add `mods` round-tripping
through the ring plus the five new NAV codes.
`tools/web/run_ui_stub.mjs` and `tools/web/run_webgl_stub.mjs` scripted
hosts get the extra field so their recorded traces stay green.

Gates: `./wbuild tests`; `graphics_event_test` / `graphics_event_64_test`;
`wasm_ui_test` and `wasm_webgl_test` locally (Node-bound, outside the
`tests` umbrella).

**Landed** as planned. Two notes: `window_stub.w` needed no change
(it has no ring at all, not just a narrower one), and the scripted
hosts in `tools/web/` needed none either — `webgl_env.mjs` writes
`e.mods ?? 0`, so a host that omits the field reports no modifiers
rather than breaking. The X11 keysym if-chain became a `nav` variable
plus one push, which keeps five new keys from doubling the branch
count.

## Stage 2 — the `graphics/ui/widgets/` split (pure code move)

`graphics/ui/widgets.w` becomes a pure umbrella of imports plus the
one dummy declaration the `grammar.w` / `codegen.w` umbrellas carry.
Import order is dependency order (W is single-pass; no cycles):

```
graphics/ui/widgets/state.w      ui_input, ui_layout, ui_context (structs only)
graphics/ui/widgets/layout.w     ui_same_line, ui_layout_next, region stack
graphics/ui/widgets/context.w    ui_context_init, ui_feed_event, ui_begin,
                                 ui_begin_window, ui_end, ui_disable,
                                 ui_click_behavior, ui_widget_fill, ui_text_color
graphics/ui/widgets/basic.w      ui_label, ui_title, ui_button
graphics/ui/widgets/choice.w     ui_checkbox, ui_radio, ui_toggle
graphics/ui/widgets/progress.w   ui_progress
graphics/ui/widgets/textbox.w    ui_textbox_state, ui_textbox_capacity,
                                 ui_textbox_init/set/insert/backspace, ui_textbox
graphics/ui/widgets/dropdown.w   ui_dropdown
```

Code moves verbatim — no logic edits — so `graphics_ui_widgets_test`,
`graphics_ui_render_test`, `graphics_ui_smoke_test` and `wasm_ui_test`
all pass unchanged and the diff reads as a move. Each new module gets
the house `/* */` header naming its role and citing
`docs/projects/ui_widgets.md §3`.

`package.wmeta` gains the eight new module names (`metadata_check`).
`./wbuild manifest` is a no-op here — no new test files yet.

Gates: `./wbuild tests`; the four UI targets above must be byte-for-byte
behaviorally identical.

**Landed** as planned: the 501 non-blank body lines are identical to
the ones they moved from, only regrouped, and the four UI targets
passed unmodified. The umbrella needed no dummy declaration (it
follows `graphics/window.w`, not `grammar.w`).

## Stage 3 — clipping and batch growth

- `graphics/ui/rect.w` (pure): `ui_rect ui_rect_intersect(ui_rect a,
  ui_rect b)`, `int ui_rect_is_empty(ui_rect r)`.
- `graphics/ui/render.w`: `ui_renderer` gains `ui_rect[8] clip_stack`,
  `int32 clip_depth`; `void ui_clip_push(ui_renderer* r, ui_rect rect)`
  (intersects with the current clip), `void ui_clip_pop(ui_renderer* r)`,
  `ui_rect ui_clip_current(ui_renderer* r)`. `ui_render_quad` clips the
  rect and lerps `u0..u1` / `v0..v1` by the trimmed fractions; a fully
  clipped quad emits zero vertices. Push past depth 8 is dropped.
- Batch growth: `ui_render_vertex` doubles the batch through
  `realloc(old, oldlen, newlen)` on overflow (`lib/memory.w` — takes
  the *old* length) instead of dropping. `ui_render_max_verts()` stays
  as the initial capacity.

Tests:

- `graphics/ui/core_test.w` gains the pure `ui_rect_intersect` /
  `ui_rect_is_empty` cases (runs on 32-bit, x64 and wasm).
- New `graphics/ui/widgets/clip_test.w`
  (`# wbuild: name=graphics_ui_clip_test arch_only=x64`): a quad wholly
  inside is untouched; wholly outside emits 0 verts; half-clipped emits
  6 verts with exactly-halved UVs; nested pushes intersect; a mirrored
  mask quad (`u0 > u1`) clips correctly; glyphs clipped mid-line drop
  only the outside glyphs.
- `graphics/ui/render_test.w`'s batch-cap assertion changes to assert
  growth. Expected churn, called out in the commit message.

**Landed**, with one design point the plan did not anticipate: an
empty clip stack is a *fast path*, not a viewport clip. Treating the
viewport as a clip would drop the zero-extent side fills a
pill-shaped rrect legitimately emits — which the pinned 42-vertex
rrect count would have caught. `ui_render_clip_depth()` is 8 per
layer once stage 4 lands.

## Stage 4 — layout regions and the layer/popup stack

**`state.w`**

```
struct ui_layout:
	ui_rect bounds
	float32 cursor_x, cursor_y, origin_x
	float32 last_right, last_top
	float32 content_w, content_h
	int32 pending_same_line
```

`ui_context` gains `ui_layout[8] layout_stack` + `int32 layout_depth`
(replacing the loose cursor fields), and replaces `int32 modal` with
`int32[4] popup_stack`, `int32 popup_depth`, `int32 scope`.

**`layout.w`**: `void ui_region_push(ui_context* ctx, ui_rect area)`,
`void ui_region_pop(ui_context* ctx)`,
`ui_rect ui_region_content(ui_context* ctx)`. `ui_layout_next` and
`ui_same_line` operate on `layout_stack[layout_depth]`; `ui_begin`
seeds depth 0 with the window rect, so today's behavior is the depth-0
case.

**`render.w`**: replace `to_overlay` / `overlay_verts` / `overlay_count`
with `ui_render_layer_count()` = 3 indexed batches (`UI_LAYER_BASE` 0,
`UI_LAYER_POPUP` 1, `UI_LAYER_TOP` 2) and
`void ui_render_layer(ui_renderer* r, int layer)`. `ui_render_end`
draws them in order; the clip stack is saved and restored per layer.

**`overlay.w`**:
`void ui_popup_begin(ui_context* ctx, int id, ui_rect area, int layer)`
and `void ui_popup_end(ui_context* ctx)` push/pop scope, layer, clip and
region together.

`ui_click_behavior` becomes: inert when `ctx.disabled`, or when
`popup_depth > 0` and `ctx.scope` is not the top of `popup_stack`.

`ui_dropdown` is rewritten onto `ui_popup_begin` / `ui_popup_end` here —
it is the only existing consumer of the old mechanism (`widgets.w:556`,
`:568`) and so doubles as the migration proof.

Tests:

- New `graphics/ui/widgets/layout_test.w`
  (`name=graphics_ui_layout_test arch_only=x64`): region push/pop
  placement, `same_line` inside a region, measured content extent,
  depth overflow dropped cleanly.
- New `graphics/ui/widgets/overlay_test.w`
  (`name=graphics_ui_overlay_test arch_only=x64`): nested popups make
  outer widgets inert; inner geometry lands in the higher layer;
  popping restores scope, layer, clip and region; popup-stack overflow
  does not corrupt.
- `graphics/ui/widgets_test.w`'s dropdown assertions (`:377`, `:407`)
  and `render_test.w`'s overlay-batch assertions move to the layer API.

**Landed**, with the popup API split in two lifetimes rather than one.
`ui_popup_begin`/`ui_popup_end` bracket the *issuing* of a popup
within a frame (scope, layer, clip, region — the four the plan names);
`ui_popup_open`/`ui_popup_dismiss` register *open-ness*, which has to
outlive the frame, because a popup opened on frame N must make the
widgets issued BEFORE it on frame N+1 inert too. `ctx.modal` had that
property by accident of never being reset; a bracket alone cannot
express it. The clip stack is per layer (`ui_rect[24]`,
`int32[3] clip_depth`), so entering a popup layer starts from a clean
clip, and `ui_popup_begin` inflates its clip by `ui_shadow_margin()`
since elevation draws outside the surface it belongs to. `ui_layout`
gained `content_w`/`content_h` here rather than in stage 5.

## Stage 5 — scroll

- `context.w`: `ui_feed_event` consumes `GFX_EVENT_SCROLL`. `ui_input`
  gains `int32 scroll_x`, `int32 scroll_y`, `int32 mods`, and
  `ui_context` gains `int32[32] char_mods` / `int32[8] nav_mods`
  parallel to the existing queues. All cleared in `ui_end`.
- New `graphics/ui/widgets/scroll.w`:

```
struct ui_scroll_state:
	float32 offset_x, offset_y
	float32 content_w, content_h
	float32 view_w, view_h

void ui_scroll_begin(ui_context* ctx, ui_rect area, ui_scroll_state* st)
void ui_scroll_end(ui_context* ctx, ui_scroll_state* st)
```

  `begin` pushes a clip plus a region offset by `-offset_*`; `end` pops
  both, records the extent, claims the frame's wheel delta when the
  pointer is inside `area`, clamps, and draws a thin rounded scrollbar
  via `ui_draw_rrect` when content overflows. Thumb dragging reuses
  `ui_click_behavior`'s active-id tracking.

Tests: new `graphics/ui/widgets/scroll_test.w`
(`name=graphics_ui_scroll_test arch_only=x64`) — wheel moves the offset;
the offset clamps at both ends; content shorter than the view draws no
bar and never scrolls; a widget scrolled out of view emits zero
vertices (clip and scroll composing).

**Landed**, with `ui_scroll_end(ctx, st)` taking no `area`: the
viewport is stored on the state at `ui_scroll_begin`, which keeps the
two calls from disagreeing about it. The wheel is *claimed* (the
viewport that ends first zeroes the notch) so nested regions never
both scroll — tested directly. `ui_scroll_reveal` was added here, not
in stage 7, because both Table and Textarea need it.

## Stage 6 — the text buffer

New `graphics/ui/widgets/buffer.w` — **pure** (no `graphics.gl` /
`graphics.window` import), so it runs on wasm and the 32-bit target:

```
struct ui_text_buffer:
	char* data
	int32 length, capacity
	int32* line_starts
	int32 line_count, line_capacity

void ui_text_buffer_init(ui_text_buffer* b)
void ui_text_buffer_free(ui_text_buffer* b)
void ui_text_buffer_set(ui_text_buffer* b, char* s)
void ui_text_buffer_insert(ui_text_buffer* b, int offset, int ch)
void ui_text_buffer_insert_text(ui_text_buffer* b, int offset, char* s)
void ui_text_buffer_delete(ui_text_buffer* b, int offset, int count)
int  ui_text_buffer_line_start(ui_text_buffer* b, int line)
int  ui_text_buffer_line_length(ui_text_buffer* b, int line)
int  ui_text_buffer_offset_to_line(ui_text_buffer* b, int offset)
int  ui_text_buffer_line_col_to_offset(ui_text_buffer* b, int line, int col)
```

Growth by doubling through `realloc`. The line index is rebuilt on
edit, O(n), with the incremental version documented in the header as
the editor's follow-up. Index arithmetic uses `&line_starts[n]`, never
`line_starts + n` — `T* + int` is an unscaled byte offset.

Note that `buffer.w` sits before `basic.w` in the umbrella import order
only if a widget needs it; as a pure leaf it can sit anywhere after
`state.w`. Placed with the foundation modules for readability.

Tests: new `graphics/ui/widgets/buffer_test.w`
(`# wbuild: name=graphics_ui_buffer_test x64 group=wasm_smoke_test@wasm`)
— insert and delete at every boundary, growth past the initial
capacity, line index after a multi-line set, offset ↔ line/col round
trips, empty-buffer edges, free leaving a reusable zeroed struct.

**Landed** as planned. One invariant worth stating that the plan left
implicit: a buffer always has at least one line, so an empty buffer is
one empty line rather than zero — every caret position is on a line and
no caller needs a zero-line special case. Every offset-taking entry
point clamps rather than trusting its caller.

## Stage 7 — Modal, Table, Textarea

**`graphics/ui/widgets/modal.w`**

```
int  ui_modal_begin(ui_context* ctx, char* title, float32 w, float32 h, int32* open)
void ui_modal_end(ui_context* ctx)
```

Returns 1 while open so the caller issues body widgets between the
calls. Scrim over the whole window on `UI_LAYER_POPUP`, centered
`ui_draw_shadow` + `ui_draw_rrect` surface, title row, close
affordance. Escape (arrives as `CHAR 27`) and a scrim click close it.

**`graphics/ui/widgets/table.w`**

```
struct ui_table_state:
	ui_scroll_state scroll
	int32 selected
	int32 row_height

void ui_table_begin(ui_context* ctx, ui_rect area, char** headers, int32* col_widths, int col_count, ui_table_state* st)
int  ui_table_row(ui_context* ctx, ui_table_state* st, int row_index)
void ui_table_cell(ui_context* ctx, ui_table_state* st, char* text)
int  ui_table_end(ui_context* ctx, ui_table_state* st)
```

Sticky header outside the scroll clip; zebra body rows inside it.
`ui_table_row` returns 0 for rows outside the viewport so the caller
skips their cells — row virtualization is what keeps a large table
inside the vertex budget. `ui_table_end` returns the selected row on a
change.

**`graphics/ui/widgets/textarea.w`**

```
struct ui_textarea_state:
	ui_text_buffer buf
	int32 caret_line, caret_col, caret_goal_col
	int32 sel_anchor          # -1 = no selection
	ui_scroll_state scroll

void ui_textarea_init(ui_textarea_state* st)
void ui_textarea_free(ui_textarea_state* st)
void ui_textarea_set(ui_textarea_state* st, char* s)
int  ui_textarea(ui_context* ctx, ui_rect area, ui_textarea_state* st)
```

Focus through `ctx.focus`, as `ui_textbox` does. Consumes CHAR
(printable, backspace, return inserting a newline), the new
UP/DOWN/PAGE_UP/PAGE_DOWN/DELETE nav codes, shift-modified nav
extending the selection from `sel_anchor`, ctrl+HOME/END for buffer
ends. Draws only the visible line range, a selection highlight behind
the glyph runs, and a caret; horizontal placement reuses
`ui_text_prefix_width` and `ui_text_caret_from_x`. Returns 1 on frames
the buffer changed.

Tests: `graphics/ui/widgets/{modal,table,textarea}_test.w`, each
`# wbuild: name=graphics_ui_<x>_test arch_only=x64`, all headless
through `ui_render_init_headless` with scripted `gfx_event`s — the
`widgets_test.w` house style. Modal: background widgets inert, geometry
in the popup layer, escape and scrim close. Table: virtualization emits
vertices for visible rows only, header stays put while the body
scrolls, selection edge. Textarea: typing, newline, arrow and page
motion, goal-column behavior across short lines, shift-selection
extent, delete-selection.

**Landed**, and the tests earned their keep — they caught two bugs
review would not have:

- Delete is an edit, not a motion. Routed through the motion path it
  cleared the selection anchor before it could delete the selection,
  so shift-select + Delete removed one character. It runs ahead of the
  anchor handling now.
- A modal closed from inside its own body (a Close button) left the
  popup registered, because `ui_modal_begin` returned early on the
  next frame without unregistering — the whole page would have stayed
  inert forever. `ui_modal_begin` now dismisses unconditionally when
  closed.

`ui_table_end` returns the selected row on a change and -1 otherwise.
`layout.w` gained `ui_region_claim` so widgets that place their own
geometry (table rows, editor lines) still get their extent measured
for the scroll region around them.

## Stage 8 — demo and gates

- `graphics/ui/demo_shared.w` gains a Modal opened by a button and a
  Table + Textarea pair. **The existing stage-1..3 rows keep their
  current coordinates** — `graphics/ui/smoke_test.w` and
  `tools/web/run_ui_stub.mjs` both probe them — so the new content goes
  below and to the right, and the header comment documents its
  coordinates the same way.
- `build.base.json`: `graphics_darwin` gains compile-only
  `arm64_darwin` steps for the new test files (the existing pattern at
  `build.base.json:2000-2003`). Then `./wbuild manifest` regenerates
  `build.json` — never hand-edited.
- `docs/projects/ui_framework.md` and `ui_widgets.md` status lines
  updated; `docs/images/ui_demo_*.png` refreshed via
  `graphics/ui/demo.w --screenshot` + `tools/ppm_to_png.py` if the
  default screen changed.
- Any friction hit in `w check` / `wtest` during the work gets an entry
  in `docs/projects/ai_tooling_next_steps.md` (repo rule).

**Landed**, with the demo window grown 320x400 → 320x680 to fit the
three new widgets below the existing rows, whose coordinates are
unchanged as required.

`docs/images/ui_demo_*.png` were refreshed, and a fourth
(`ui_demo_modal.png`) added for the one round-1 widget not on the
default screen. Capturing them needs a display, which a headless
checkout can supply: `Xvfb :99 -screen 0 1280x1024x24` plus Mesa's
llvmpipe renders the demo (and lets `graphics_ui_smoke_test` actually
run its pixel readback instead of SKIPping). `demo.w` gained
`--theme light|dark|ocean` and `--dialog` so every image is
reproducible from the CLI rather than by clicking the picker before
capturing — which is what made the refresh worth doing rather than a
manual ritual.

## Gates, per commit

1. `./bin/wv2 check --json <file>` (insert `x64` for the 64-bit target)
   on every touched file — empty stdout and exit 0. Warnings count:
   the self-host stages build `--strict`.
2. `git diff --name-only HEAD | ./bin/wtest changed` for the exact
   target list, then `./wbuild test_changed`. Do not guess targets. The
   first run after a build populates `bin/.wtest_deps_cache` and can
   take several minutes — let it finish.
3. `./wbuild manifest` after adding any `*_test.w`, then
   `./wbuild manifest_check`.
4. `./wbuild tests` before the commit is considered done.
5. `./wbuild graphics_ui_smoke_test` — SKIPs with exit 0 when there is
   no display; confirm it actually ran when one is available.
6. `./wbuild wasm_ui_test` and `./wbuild wasm_webgl_test` locally
   (Node-bound, outside the `tests` umbrella) — the gates Stage 1's JS
   changes can break.
7. `./wbuild graphics_darwin` for arm64_darwin compile coverage; real
   Darwin runtime needs the Mac and `tools/mac/run_darwin_tests.sh`.

## Risks

- **Pinned vertex counts.** `render_test.w` and `widgets_test.w` assert
  exact counts (rrect 42, disc 6, shadow 54, label 7 glyph quads,
  progress 42/126/210, checked checkbox 12). Stages 3 and 4 change the
  batch model and the dropdown's drawing, so those assertions update in
  the same commits — expected churn, not a regression.
- **The wasm host contract.** `window_web.w`, `tools/web/index.html`
  and `tools/web/webgl_env.mjs` must change in lockstep in Stage 1 or
  both wasm gates break. `gfx_window` itself stays byte-frozen.
- **`T* + int` is an unscaled byte offset** for every pointee width.
  `int32* line_starts` and `float32* verts` are both exposed to it —
  `&p[n]` or `lib/ptr.w`'s `ptr_add`, never `p + n`.
- **Bit-31 hex literals sign-extend** on every target; the new
  `gfx_mod` flags and X11 keysyms all stay well below it.
- **`build.json` is generated.** Only `build.base.json` and `# wbuild:`
  directive lines are hand-edited; `manifest_check` fails CI on drift.
- **Target-name collisions.** `wbuildgen` derives names from basenames
  and hard-errors on duplicates, so every test under
  `graphics/ui/widgets/` needs an explicit `name=graphics_ui_*`.
- **Cocoa has no mouse events**, so the new widgets are compile-verified
  on `arm64_darwin` but not interactively usable there this round.
