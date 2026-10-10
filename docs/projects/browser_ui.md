# Browser text, input, and accessibility dependencies

Win can keep using the existing `graphics.ui` TrueType rasterization, UTF-8
text, pair kerning, clipping, and font fallback APIs. This foundation work does
not replace them. Complex shaping, bidirectional ordering, grapheme-aware caret
movement, and IME composition remain tracked by
[#459](https://github.com/reardan/w/issues/459). Semantic metadata and native
assistive-technology bridges remain tracked by
[#465](https://github.com/reardan/w/issues/465).

## Reusable semantic snapshots

`import graphics.ui.accessibility` exposes a renderer-independent, owned
semantic tree usable for browser controls **and** rendered page content:

- `ui_access_tree_new(max_nodes, max_text_bytes)` creates a bounded snapshot.
- `ui_access_add(tree, id, parent_id, role, bounds)` inserts a node, or returns
  zero without changing the snapshot. IDs are positive and unique. A parent
  must already exist; parent zero creates the single root. Stable IDs are
  supplied by the application, allowing a future bridge to compare snapshots.
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

This is an interface boundary, not a working screen reader integration. Existing
immediate-mode widgets do not automatically populate snapshots yet. A web
ARIA/DOM mirror, macOS NSAccessibility, Linux AT-SPI, Windows UI Automation,
widget-wide Tab/Shift-Tab routing, and contrast review remain #465. Do not claim
platform accessibility solely because a snapshot exists. Headless x86/x64 tests
cover ownership, bounds, invalid identities/parents, budget failure, UTF-8 and
embedded-NUL values, focus proposals, and host action validation.

## Current backend qualification

The #459 issue description records an older baseline. Current Cocoa character
input decodes Unicode from `[event characters]`; its source explicitly notes
that `NSTextInputClient`, dead-key composition and IME are still absent. X11's
key path maps Latin-1 keysyms and has no `Xutf8LookupString` integration. Win32's
current `WM_CHAR` handler masks to eight bits; full Unicode/UTF-16 surrogate and
IME integration remains necessary. The web mobile adapter (`tools/web/mobile_input.mjs`) already commits Unicode
codepoints through a hidden editor and handles composition commit suppression.
It does not expose a native preedit range through the W UI event API. This
capability belongs to that adapter and should not be assumed for every web host.

Codepoint glyph lookup plus pair kerning is not shaping or bidi. Native text
input capability also does not imply grapheme-aware selection or preedit support.
Keep platform-specific smoke tests and the broader shaping/input dependency open
as those paths evolve. Page layout, text selection, DOM focus, and the embedding
browser's event policy stay in Win.
