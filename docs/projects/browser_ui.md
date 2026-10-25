# Browser text, input, and accessibility dependencies

Third party browser applications can use the existing TrueType rasterizer,
UTF-8 drawing, pair kerning, clipping and font fallback APIs, plus the new
[paragraph bidi and shaped-run adapters](text_shaping.md), [text/IME input](text_input.md), and
[web and macOS accessibility bridges](accessibility.md). These are reusable
library APIs; page layout, DOM focus, selection and application policy remain
with the browser.

## Reusable semantic snapshots

`import graphics.ui.accessibility` exposes a renderer-independent, owned
semantic tree usable for browser controls **and** rendered page content:

- `ui_access_tree_new(max_nodes, max_text_bytes)` creates a bounded snapshot.
- `ui_access_add(tree, id, parent_id, role, bounds)` inserts a node, or returns
  zero without changing the snapshot. IDs are positive and unique. A parent
  must already exist; parent zero creates the single root. Stable IDs are
  supplied by the application, allowing consumers to identify the same application node across snapshots.
- Nodes carry roles (document, group, text, heading, link, button, checkbox,
  textbox, image, list/item, table/row/cell), states, action bits, bounds, and
  heading level. Rectangles use the UI's logical pixel coordinates; a platform
  bridge must apply window/screen coordinate conversion.
- `ui_access_set_text(tree, id, field, data, length)` copies explicit-length
  UTF-8 name/value/description bytes. Embedded NUL survives; consumers must use
  lengths. Invalid UTF-8, missing IDs and exhausted aggregate text budgets fail
  atomically. Text budgets count payload bytes, while allocations additionally
  contain one convenience terminator per populated field. Old text is released
  on replacement. Empty unset fields have a zero data pointer and zero length.
- `ui_access_focus_next(tree, current_id, reverse)` proposes a focus ID in
  insertion order, wrapping and skipping hidden/disabled/nonfocusable nodes.
  The application applies focus and draws its existing focus ring; this helper
  does not synthesize input, mutate widget contexts, or update `focused_id`.
  `ui_access_move_focus(tree, reverse)` additionally dispatches the focus action
  and changes `focused_id` only if the application accepts it.
- `ui_access_dispatch(tree, id, action, data, length)` validates the requested
  supported action and forwards to the snapshot's host callback/context. Hidden
  and disabled nodes reject actions; readonly nodes reject value changes. The
  callback returns success/failure and owns application behavior. The caller
  publishes a later snapshot to reflect any resulting changes.
- `ui_access_tree_free(tree)` releases the entire tree iteratively, including
  text and ID lookup storage. The callback/context are borrowed, never freed.

The application populates snapshots from its existing widget/DOM state. Names,
roles, state, geometry, and reading/focus order must describe visible content,
not merely paint operations. A document and its browser controls may share a
common group root. Build/publish/free on the UI thread or serialize externally;
do not mutate/free a snapshot during bridge traversal or an action callback.
A bridge borrowing a snapshot must release its reference before the application
frees or replaces it. `focused_id` is application-managed metadata.

The opt-in `graphics.ui.accessibility_cocoa` bridge copies snapshots into real
NSAccessibility elements and queues native focus, press/toggle and value
requests for the application's UI loop. Build and ship its AppKit companion
as described in [accessibility](accessibility.md). It is not installed simply
by importing the semantic tree. The bridge's W smoke executable cross-compiles
on Linux; AppKit compilation, runtime tests and VoiceOver qualification need a
Mac. Portable tests cover ownership, limits, focus actions and default-theme
contrast.

The opt-in `graphics.ui.accessibility_web` bridge publishes snapshots through
the wasm host into an ARIA DOM mirror. It exposes document structure and
controls, queues focus/activation/value requests, and revalidates those requests
against the W snapshot. Replacing or closing a publication invalidates actions
from its old DOM elements. See [accessibility](accessibility.md) for publication,
ownership, host setup and the limits of the initial role/state mapping.

The opt-in `graphics.ui.accessibility_atspi` bridge publishes snapshots to
Linux AT-SPI 2 over a pure-W D-Bus client, and `graphics.ui.accessibility_uia`
to Windows UI Automation as COM providers written in W. Immediate-mode widgets route
Tab/Shift-Tab, draw a focus ring after keyboard navigation and populate
snapshots automatically through `ui_access_capture`; page content outside the
widgets still builds its own semantic tree and routes focus through
application callbacks. Screen-reader qualification of the Windows bridge
(Narrator, NVDA) is still open in #465.

## Current backend qualification

Textboxes and textareas now step and delete whole Unicode graphemes and share
grapheme-aware caret hit testing. Composition previews are separate from the
committed buffer, persist across frames, and clear on cancellation/focus change.

- X11 uses XIM and `Xutf8LookupString` for Unicode commits, with a Unicode keysym
  fallback when no input context is available. Preedit is managed by the input
  method; the W client does not yet expose XIM preedit callbacks.
- Win32 uses wide window APIs and decodes UTF-16 surrogate pairs. IMM
  composition messages provide preedit snapshots; committed text follows
  `WM_CHAR`. The active editor supplies composition-window geometry.
- The web mobile adapter forwards composition updates and commits through the
  W event contract. Hosts using a different web adapter must implement that
  contract themselves.
- Cocoa's existing `[event characters]` path delivers Unicode, but does not yet
  implement `NSTextInputClient`, dead-key composition or native preedit.

The [text-input contract](text_input.md) documents limits, event ownership and
platform smoke checks. Native IME interaction still needs qualification with
real input methods; headless event tests alone cannot establish that behavior.

For document rendering, `graphics.ui.shape` can shape and draw a single
font/script/direction run through HarfBuzz on Linux x64. It preserves source
clusters and positioned glyphs, including substitutions and combining marks.
`graphics.ui.bidi` additionally resolves a paragraph through FriBidi on Linux
x64, providing logical directional ranges and visual run order. Its
`ui_bidi_reorder_line` API reorders caller-selected wrapped ranges using retained
paragraph context, with independent owned output for each line and reflow.
Feed the original logical slices to the shaper; scalar reordering maps are not
glyph or caret positions. The host still selects scripts/fonts and line breaks.
Ordinary widget drawing still uses codepoint lookup and pair kerning. Portable
bidi/shaping, script/font segmentation, shaped caret
layout, CFF outlines and broader native input remain open parts of #459. See [shaping](text_shaping.md)
for font coverage, optional dependencies and explicit limits.
