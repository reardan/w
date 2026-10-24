# Unicode editing and composition

The reusable UI text input foundation supports UTF-8 documents, extended
grapheme boundaries, Unicode native commits, and an explicit preedit preview.
Applications own document models, focus IDs, DOM input events, selection policy,
and undo transactions. These APIs do not implement browser contenteditable.

## Editing

`graphics.ui.grapheme` exposes `ui_grapheme_next`, `ui_grapheme_prev`, and
`ui_grapheme_floor`/`ui_grapheme_ceil` over NUL-terminated UTF-8 text and byte
offsets. `ui_grapheme_next_n` accepts an explicit byte length for scans that
already know their bounds. The helpers
use the Unicode break tables in `lib.grapheme`. Textbox and textarea horizontal
movement and deletion now consume a whole grapheme, including decomposed
accents, emoji ZWJ sequences and regional-indicator pairs. Vertical textarea
movement rounds its target byte column down to a grapheme boundary. Textbox
prefill truncates at a whole grapheme within its 127-byte capacity. When an
edit joins neighboring clusters, insertion advances to the resulting cluster
end and deletion rounds back to its start. Selection replacement keeps its
original insertion offset until the replacement is complete.

## Preedit events

The existing five-field `gfx_event` ABI gains three event kinds:

| Event | Meaning |
| --- | --- |
| `GFX_EVENT_PREEDIT_BEGIN` (10) | Replace the preview with an empty snapshot. |
| `GFX_EVENT_PREEDIT_TEXT` (11) | Append the Unicode scalar in `code`. |
| `GFX_EVENT_PREEDIT_END` (12) | Clear the preview on cancellation or commit. |

`x` identifies the owning stable focus ID; zero binds to the current focus.
`y` on BEGIN reserves a selection-start offset in Unicode scalars (currently
zero in platform adapters). A new BEGIN replaces the previous snapshot.
Committed text continues to use `GFX_EVENT_CHAR`; preedit never changes a
caller's text buffer or its selection. `ui_context` retains a UTF-8 snapshot
across frames, limited to 1023 bytes without splitting a scalar. Textbox and
textarea draw a clipped, underlined preview at their insertion point. Focus
changes clear the preview. Invalid scalar values and mismatched owners are
ignored. Clause styles, selected conversion ranges and surrounding-text
replacement requests are not implemented yet.

## Platform paths

- **X11:** initializes LC_CTYPE from the environment, opens XIM, filters native
  input events and uses `Xutf8LookupString`, including buffer-overflow retry.
  XIM owns its candidate/preedit window using PreeditNothing/StatusNothing;
  the W preview snapshot is not populated on this backend. Window focus calls
  XSetICFocus/XUnsetICFocus; widget focus changes reset pending composition.
  When XIM is unavailable, Latin-1 and Unicode-encoded X keysyms still commit.
- **Win64:** registers a Unicode window class, converts UTF-8 titles to UTF-16,
  decodes WM_CHAR surrogate pairs, and accepts WM_UNICHAR. IMM composition
  updates publish W preedit snapshots. The default Unicode window procedure
  owns committed results through WM_CHAR, avoiding a second result-string
  insertion path. Focus changes cancel pending IMM composition; the declared
  edit rectangle positions the native composition/candidate UI. The current
  host API supplies the field rectangle, not exact native caret geometry.
- **Web mobile adapter:** compositionupdate publishes a replacement snapshot,
  compositionend clears it and commits once, and blur cancels old-field
  previews and suppresses late commits. Hosts using this adapter inherit the
  behavior; other embedding hosts must implement the event contract themselves.
- **Cocoa:** by default the window decodes `[event characters]`, so dead keys
  and input methods do not compose. `graphics.ime_cocoa` is the opt-in
  `NSTextInputClient` bridge: build `bin/libwtextinput.dylib` with
  `tools/mac/build_text_input.sh` (from `graphics/ui/native/text_input.m`),
  ship it beside the executable, and call `gfx_cocoa_text_input_enable(win)`
  after `gfx_window_open`. While a field is focused, key-downs go through
  `interpretKeyEvents:`; `insertText:` commits arrive as CHAR (one per scalar),
  `setMarkedText:` publishes W preedit snapshots with the selection start in
  scalars, `unmarkText` commits the marked text, and keys the input system
  returns through `doCommandBySelector:` (arrows, Return, Backspace, Control
  chords) keep the window's own CHAR/NAV translation. Command chords bypass the
  bridge. A focus change discards composition without committing it, and
  `firstRectForCharacterRange:` places the candidate window under the field
  rectangle from `gfx_text_input`. The native contract test
  (`text_input_test.m`, run by the build script) and
  `graphics_ime_cocoa_darwin` (cross-compiled in Linux CI) run on a Mac; the
  bridge has not yet been qualified with installed input methods there.

Native X11/Win64/Cocoa input uses `graphics.input_queue`, which grows to preserve
long IME commits and drains at the UI's 32-character/8-navigation-event frame
budgets. Later pointer or navigation changes wait until preceding committed
text was consumed, preserving the insertion target. The web queue follows the
same ordering rule. Call `gfx_window_poll` each frame to reset native budgets.
Raw consumers can call `gfx_input_queue_begin` at their own drain boundaries.
The older fixed ring remains available for other backends and its unit tests.

## Qualification and remaining work

Headless tests cover Unicode conversion, 1000-scalar commits across frames,
queue compaction, focus-order barriers, grapheme editing and truncation,
preedit replacement/cancellation, and committed-buffer isolation. Web tests
exercise composition updates, single commits and late blur events. Cross-target
checks compile the shared widgets for wasm, Darwin and Win64. Native XIM/IMM
candidate windows still require interactive qualification with installed input
methods; a successful structural check is not a CJK desktop smoke test.

Shaping is a separate layer: grapheme movement and native Unicode input do not
provide bidi paragraph layout or font coverage (see
[shaping](text_shaping.md)). The default embedded faces cover Latin, Greek and
Cyrillic. A browser host should load suitable licensed TrueType or CFF
CJK/script faces with `ui_font_face_load_ttf` and register them through
`ui_font_add_fallback`; no larger fallback font is bundled. Hinting remains
outside the rasterizer.

Native contracts follow the [Xlib internationalized text input specification](https://www.x.org/releases/X11R7.6/doc/libX11/specs/libX11/libX11.pdf),
[WM_CHAR Unicode semantics](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-char),
and [WM_IME_COMPOSITION handling](https://learn.microsoft.com/en-us/windows/win32/intl/wm-ime-composition).
