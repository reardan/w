# Accessibility for custom-rendered applications

`graphics.ui.accessibility` supplies owned semantic snapshots; applications
populate them from their controls and document model. `graphics.ui.accessibility_cocoa`
now publishes those snapshots to macOS NSAccessibility through an opt-in native
companion. The existing GL window content view becomes the parent of real
`NSAccessibilityElement` objects. This is useful for a third party browser's
chrome and document content without coupling the bridge to HTML or layout. The opt-in
`graphics.ui.accessibility_web` adapter exposes snapshots through browser ARIA, and
`graphics.ui.accessibility_atspi` publishes them to Linux AT-SPI 2 (Orca) over a
pure-W D-Bus client, and `graphics.ui.accessibility_uia` to Windows UI
Automation (Narrator, NVDA, JAWS) as COM providers written in W. The immediate-mode widgets produce snapshots automatically
and route Tab/Shift-Tab, Space/Return and assistive actions themselves.

## macOS setup and lifecycle

On an Apple Silicon Mac with the Xcode command line tools, run:

```
tools/mac/build_accessibility.sh
./wbuild graphics_ui_accessibility_darwin
tools/mac/run_darwin_tests.sh bin/graphics_ui_accessibility_darwin
```

The build script compiles `graphics/ui/native/accessibility.m` as an ARC-enabled
AppKit dylib and executes its native contract tests. The W smoke target is also
cross-compilable from Linux; executing it and the native helper requires macOS.
Ship `libwaccessibility.dylib` beside the executable. Importing the Cocoa bridge
adds `@executable_path/libwaccessibility.dylib` to the executable's load commands;
a missing companion is a dyld startup error. Applications that do not import the
bridge have no new native library dependency.

1. Import `graphics.ui.accessibility_cocoa` and `graphics.cocoa`.
2. Obtain the GL window's content view with
   `objc_msg0(win.window, sel_registerName(c"contentView"))`.
3. Call `w_access_open(view, max_action_bytes)` once. A zero handle means
   invalid input or a call outside the main thread. Do not install two bridges
   on the same view. The byte limit should match the snapshots' text budget.
4. Populate a bounded W semantic tree and call
   `ui_access_cocoa_publish(bridge, tree)` whenever semantics or focus change.
   A successful publication copies all text and geometry into AppKit objects.
5. After pumping AppKit events, call `ui_access_cocoa_dispatch(bridge, tree)`
   against the same snapshot, before replacing it. Its action callback updates
   the application model; publish a new snapshot afterward. The callback must
   not free the tree or recursively publish during dispatch.
6. Call `w_access_close(bridge)` before destroying the window. Free W snapshots
   independently. Close restores the content view's previous accessibility
   children and element flag.

All bridge operations run on the AppKit main thread. One publication replaces
the complete native tree; publish only on semantic changes, not every frame.
Native actions are bounded to 64 queued requests and the configured value byte
limit. Old queued requests are discarded on publication. Objects retained by
assistive clients from an old tree lose their bridge reference, so their actions
cannot accidentally target a reused ID. A failed staged publication leaves the
previous native tree installed. IDs should remain stable in the application,
but native object identity is replaced in this initial adapter.

Roles, labels, help, values (including embedded NUL), heading levels, selected,
expanded, checked, enabled and focused state reach AppKit. Disabled and hidden
ancestors affect descendants. Geometry uses the snapshot's top-left logical
coordinates relative to the content view, converted to screen coordinates at
query time; moving the window does not require republishing bounds. Press,
toggle, focus and value requests enter the queue and are revalidated by
`ui_access_dispatch`. Layout and focus changes emit native notifications.
Text range navigation, selection APIs, table cell relations, incremental updates,
and native object identity preservation remain follow-ups. Document and list
item roles currently map to AppKit groups. Readonly text remains queryable while
value writes are rejected.

Native contract tests cover exposure, roles/names, UTF-8 and embedded NUL,
press/focus/value actions, buffer sizing, bounded queues, disabled ancestry,
readonly values, atomic publication failure and stale objects after replacement
or teardown. The W smoke test checks the actual W-to-C ABI and the Cocoa view's
installed tree. VoiceOver and Accessibility Inspector should additionally be
used to qualify an application's reading order, spoken names and geometry.
Linux development can cross-compile the smoke executable; it cannot establish
VoiceOver behavior or run AppKit tests.

## Browser ARIA mirror (wasm)

`graphics.ui.accessibility_web` publishes the same semantic snapshots through
`tools/web/webgl_env.mjs` into an opt-in DOM mirror. The standard
`tools/web/index.html` host supplies the adapter; an application activates it by
publishing. Custom hosts pass
`accessibility: createAccessibility({document, container, canvas})` to `makeEnv`.
Use a dedicated empty container and at most one adapter per canvas. Hosts without
this optional capability return zero from publication and otherwise keep working.

1. Import `graphics.ui.accessibility_web` in a wasm application. Build the
   document, button, textbox and other nodes with `ui_access_add`, then set their
   names, values, descriptions, supported actions and focusability explicitly.
2. Install the tree's action callback and call `ui_access_web_publish(tree)`.
   A zero result leaves the previous DOM publication installed. Parents must
   precede children; headings require levels 1–6, and textboxes must be leaves.
3. In the frame/event loop call `ui_access_web_dispatch(tree)` against the same
   live snapshot **before** replacing it. The callback changes the application
   model and accepts or rejects each action. Accepted focus requests also update
   `tree.focused_id`; paint the corresponding focus bounds in the application.
   A dispatch return value counts consumed requests, including rejected ones.
4. Republish after semantic changes and after processing requests, including
   rejected edits/focus requests, to restore the DOM to the authoritative model.
   Publishing copies text, drops pending old requests, and invalidates every old
   DOM listener. Do not publish every render frame: replacement resets DOM node
   identity, text selection and browser composition.
5. Call `gfx_access_close()` before freeing the final snapshot or removing the
   canvas. It removes the mirror, clears requests and restores the canvas's
   previous `aria-hidden` and `tabindex` attributes. Callbacks must not free the
   tree, recursively dispatch, or publish during dispatch.

The mirror preserves hierarchy and DOM reading order. Document, group, heading,
link, button, checkbox, image, list, list item, table, row and cell roles map to
ARIA; plain text uses text content, and textboxes use native multiline textareas.
Names and descriptions use text/attribute assignment, never HTML parsing. Text
crosses the ABI as strict, explicit-length UTF-8 (including NUL and leading BOM).
Disabled/hidden ancestors suppress descendant actions and tab stops; readonly
textboxes reject value changes. Checkbox checked state, heading level, row/cell
selection and expanded state on supported actionable roles are exposed. Snapshot
state has no separate "expandable but collapsed" flag; collapsed capability,
non-textbox values, table relations and single-line editor distinctions remain
future extensions rather than invented ARIA semantics.

DOM Tab traversal, focus, button/link activation, checkbox toggling and committed
textarea edits enter a bounded queue. Composition updates are not committed until
an input event outside composition. There are at most 64 queued requests, and
their combined UTF-8 value bytes cannot exceed the snapshot's text budget. Nodes
and stored text retain the snapshot budgets, with host ceilings of 100,000 nodes
and 16 MiB. Queue overflow drops the new request. Dispatch revalidates actions
against current W state, so a control disabled after publication cannot act.
A different W tree cannot drain the publication's queue. Calls validate wasm
memory bounds and nonoverlapping output buffers, and refresh views after memory
growth. Invalid UTF-8 or a failed staging operation aborts the entire publication.

The semantic DOM is visually clipped; it does not intercept canvas pointer
input. While installed, it replaces the canvas's accessibility exposure and tab
stop. Programmatic snapshot focus does not echo a request. DOM keyboard events
stay separate from the existing canvas keyboard event queue. The application
must paint visible focus and coordinate its canvas editor model with semantic
focus/value callbacks. Geometry, spatial touch exploration, selection/range
round trips, incremental updates and automatic widget semantics are not provided
by this adapter.

`graphics_ui_accessibility_web_test` (in `tests_wasm`) runs portable DOM contract
tests and a real
compiled W wasm instance through the existing `makeEnv` host, checking the full
publish/action/focus/value round trip, disabled-state revalidation and teardown.
The Node fixture is not a browser accessibility implementation. A separate real
Chromium development probe confirmed accessible button/textbox names and values,
Unicode static text, input dispatch, stale listener rejection and canvas state
restoration. Browser/screen-reader combinations still need interactive
qualification; none of these tests establish VoiceOver, NVDA or Orca behavior.
The role/state and keyboard mappings follow
[WAI-ARIA 1.2](https://www.w3.org/TR/wai-aria-1.2/) and the
[ARIA button pattern](https://www.w3.org/WAI/ARIA/apg/patterns/button/).

## Immediate-mode widgets: keyboard focus and semantics

Every interactive widget in `graphics/ui/widgets` registers a *focus stop*
(`ui_focus_stop`) each frame. `ui_begin` routes Tab and Shift-Tab through the
previous frame's stops in issue order, wrapping at the ends; disabled controls
and controls behind an open popup or modal are skipped. A text area keeps plain
Tab for indentation, and Ctrl+Tab always moves focus. Pressing a control with
the mouse focuses it too. After keyboard navigation the focused control draws a
2px ring in the theme's `focus` colour just outside its bounds; the next mouse
press hides the ring again, so pointer users do not see it.

A focused button, checkbox, radio, toggle, tab, chip or menu entry activates on
Space or Return (`ui_activate_behavior`); text editors keep those keys as text.
Composite widgets add their own keys: dropdowns open on Space/Return and move
with Up/Down/Home/End, tables select rows with the arrows, tabs and chips close
on Delete, splitters move with the arrows, and the calendar and time picker
expose their buttons as stops. A modal takes focus while open and returns it to
the control that had it; dropdowns, popovers and pickers return focus to their
trigger when they close.

`ui_access_capture(ctx, tree)` makes the next frame build a semantic snapshot
into a fresh `ui_access_tree_new` tree: `ui_begin` adds the document root, each
widget adds its node with role, name (form-row labels are used for unnamed
fields), value, description, states and supported actions, and `ui_end` records
the focused control. Labels and progress bars without widget ids get auxiliary
ids above `ui_access_root_id`. Widget ids are issue-order positions, so they are
stable while the layout is. The capture installs the tree's action callback:
focus requests move widget focus at once, while activate, toggle and value
requests are queued and consumed by the target widget on the next frame, which
then behaves exactly as for a click or an edit. The roles cover document, group,
text, heading, button, checkbox, textbox, list/list item, table/row/cell, radio,
switch, combobox, tab list/tab, progress and dialog.

```
ui_access_tree* fresh = ui_access_tree_new(4096, 65536)
ui_access_capture(ctx, fresh)
ui_begin(ctx, ...)  ... widgets ...  ui_end(ctx)
if (!ui_access_tree_same(fresh, published)): publish fresh, keep it as published
bridge dispatch against published (actions reach the widgets next frame)
```

`ui_access_tree_same` compares two snapshots so a frame loop republishes only
when semantics changed; `ui_access_tree_clone` copies one. `graphics_ui_focus_test`
covers tab order and wrap, disabled skipping, the focus ring, keyboard
activation, text-area Tab, modal hand-off, dropdown/table/tab keys, captured
semantics and assistive actions reaching the widgets.

## Linux AT-SPI 2

`graphics.ui.accessibility_atspi` speaks AT-SPI 2, the D-Bus protocol Orca and
other Linux assistive technology use, directly over `lib/dbus.w` (a pure-W
D-Bus client: SASL EXTERNAL, unix path and abstract sockets, the full wire
format). It needs no libatspi, ATK, GLib or libdbus.

1. `ui_atspi_bridge* b = ui_access_atspi_open(c"App name")` connects to the
   accessibility bus (`$AT_SPI_BUS_ADDRESS`, else the address the session bus's
   `org.a11y.Bus` reports) and embeds the application in the registry's
   desktop. It returns 0 when no accessibility bus is running; treat that as
   "no screen reader" and carry on. `ui_access_atspi_open_at(address, name)`
   takes an explicit bus address.
2. `ui_access_atspi_publish(b, tree)` copies the snapshot and announces what
   changed since the last publication: cache additions and removals,
   children added and removed, defunct nodes, every changed state (focus
   last), selection changes on lists, tab lists and tables, names,
   descriptions, progress values and text changes.
3. Once per frame call `ui_access_atspi_dispatch(b, tree)` with the snapshot the
   application dispatches against. It answers every pending query from the
   published copy and applies queued actions through `ui_access_dispatch`; it
   returns -1 once the bus connection is lost. The socket is non-blocking, so
   dispatch never stalls a frame.
4. `ui_access_atspi_set_origin(b, x, y)` gives the window's screen position for
   screen-coordinate geometry queries; `ui_access_atspi_close(b)` detaches.

Each node is an object at `/org/a11y/atspi/accessible/<id>` under the
application root. Objects implement Accessible, Component (extents, hit
testing, GrabFocus), Action (activate/toggle/focus by name), Text (character
offsets over UTF-8), EditableText (set, insert, delete; applied as a whole-value
`SET_VALUE`) and Value (progress percentages) as the role allows. Switches are
published as toggle buttons with checked and pressed states, since AT-SPI 2.52
has no switch role. Actions are queued (64 at most) and revalidated against the
application's tree, as in the other bridges; publishing drops queued actions
for the old snapshot.

Tables implement Table and their data cells TableCell. The snapshot has no
header flag, so the bridge treats a TABLE's first ROW as its column header
row when that row has no actions and is not selected while a later row has
actions or is selected; its cells publish as table column headers and answer
`GetColumnHeader`, `GetColumnDescription` and `GetColumnHeaderCells`. Row
indices count data rows only, every span is 1 and a cell's index is
`row * columns + column`. A row without a name of its own is named from its
cells' names (as ARIA rows are), since Orca announces a focused row by name.
Lists, tab lists and tables implement Selection: `SelectChild` and
`AddRowSelection` queue `ACTIVATE` on the child, as a click would (and
return true without a call when it is already selected); deselection,
`SelectAll` and `ClearSelection` return false, since a single-selection
host owns that policy.

`Cache.GetItems` returns the full preload, `a((so)(so)(so)iiassusau)`: the
application root and then every node in tree order with its parent, index,
child count, interfaces, name, role, description and states. Each
publication emits `Cache.AddAccessible` for new objects (parents first,
before the `ChildrenChanged` that announces them) and `RemoveAccessible`
for gone ones, as the ATK bridge does, so a caching libatspi stays coherent.

`graphics_ui_accessibility_atspi_test` runs the bridge against a private
`dbus-daemon` with a client that plays both the registry and a screen reader:
registration, tree walking, roles, states, geometry, text offsets, actions,
edits, tables, selection, the cache preload and the events a republication
emits, in order (it skips when `dbus-daemon` is not installed). The bridge
was also qualified against the real at-spi2-core 2.52 registry with a
libatspi (pyatspi) client: the application appears on the desktop, the tree,
names, states, interfaces, text and progress value read correctly,
`do_action`, `set_text_contents` and `grab_focus` reach the application
callback, and checked-state and text-changed events arrive. Table row and
column counts, `get_accessible_at`, column headers and descriptions,
`TableCell` positions and header cells, `Selection` and `add_row_selection`
read and act correctly; after a republish that adds a row the cached child
count is right (no double insertion), and libatspi logs no cache errors.

Orca 46.1 was run headless (Xvfb, a private session bus, at-spi-bus-launcher,
speech-dispatcher's dummy module, `orca --debug-file`) against a window with
a table and a tab list while a libatspi client moved focus and selection.
Its speech log: "Files frame." on window activation, "Starred page tab." on
the tab list's selection change, and "Downloads. table with 3 rows 2 columns.
b.png 9 KB." when the selected, focused row changed. Keyboard navigation
inside Orca (its own table commands, flat review) and braille were not
exercised. Not yet provided: text attributes and text selection, row
headers, multi-selection policy, and a peer-to-peer application bus.

## Windows UI Automation

`graphics.ui.accessibility_uia` (win64 only) publishes snapshots as server-side
UI Automation providers. The COM objects are written in W: each interface is a
two-word `{vtable, element}` object whose vtable holds `win_callback` thunks,
so there is no C helper, ATL or type library. It links `uiautomationcore`,
`oleaut32`, `ole32` and `user32`, all part of Windows.

1. `ui_uia_bridge* b = ui_access_uia_open(win.hwnd)` initialises COM on the
   calling thread as a single-threaded apartment. Pass 0 for a tree hosted by
   no window (tests and embedding), and give its screen position with
   `ui_access_uia_set_origin(b, x, y)`.
2. Set `gfx_win32_getobject = ui_access_uia_wm_getobject` (the optional
   `WM_GETOBJECT` hook in `graphics/window_win32.w`; nothing changes while it is
   unset). It answers `UiaRootObjectId` with `UiaReturnRawElementProvider` and
   leaves every other object id, MSAA's included, to `DefWindowProcW`.
   `ui_access_uia_getobject(b, hwnd, wparam, lparam)` is the same for an
   explicit bridge.
3. `ui_access_uia_publish(b, tree)` copies the snapshot and, when
   `UiaClientsAreListening`, raises what changed for elements a client has
   already seen: Name, Value, ToggleState, IsSelected, ExpandCollapseState and
   IsEnabled property changes, `StructureChanged` (ChildrenInvalidated) when a
   node's children differ, and `AutomationFocusChanged` for a new focus.
4. Once per frame, after pumping messages, call
   `ui_access_uia_dispatch(b, tree)`. It applies queued actions through
   `ui_access_dispatch`. Accepted focus requests also move `tree.focused_id`.
   `ui_access_uia_close(b)` releases the window's providers.

UI Automation calls the providers on the thread that opened the bridge while it
pumps messages (`ProviderOptions_UseComThreading`). Queries are answered from
the published copy. Invoke, Toggle, SetValue, Select, Expand/Collapse and
SetFocus are queued (64 at most), as in the other bridges, and publishing drops
the queue. Each node id keeps one COM object across publications, so client
identity is stable. Once a node is gone, its object answers
`UIA_E_ELEMENTNOTAVAILABLE` from every method and is disconnected
(`UiaDisconnectProvider`). It is freed with its last reference.

What is mapped:

- Every node implements IUnknown (identity: the Simple interface),
  IRawElementProviderSimple and IRawElementProviderFragment. The root adds
  IRawElementProviderFragmentRoot (hit testing with
  ElementProviderFromPoint, and GetFocus) and is hosted by the window
  (`UiaHostProviderFromHwnd`).
- Roles map to control types:
  - document → Document (the root → Pane)
  - group → Group
  - text, heading and cell → Text (headings report HeadingLevel)
  - link → Hyperlink
  - button → Button
  - switch → Button with Toggle, localized type "toggle switch"
  - checkbox → CheckBox
  - textbox → Edit
  - image → Image
  - list → List, list item → ListItem
  - table → Table, row → DataItem
  - radio → RadioButton
  - combobox → ComboBox
  - tab list → Tab, tab → TabItem
  - progress → ProgressBar
  - dialog → Window with IsDialog
- Patterns:
  - Invoke: activatable nodes with no other pattern.
  - Toggle: checkboxes and switches.
  - Value: textboxes; comboboxes, read-only unless they accept SET_VALUE.
  - SelectionItem: tabs, list items, rows and radio buttons, single
    selection. Select activates.
  - ExpandCollapse: comboboxes, and activatable nodes with the expanded
    state.
  - RangeValue: progress, read-only 0..100, from the value's leading number.
- Properties: Name, HelpText and FullDescription, AutomationId (the node id),
  FrameworkId `W`, IsEnabled, IsKeyboardFocusable, HasKeyboardFocus,
  IsOffscreen (hidden), IsDialog, HeadingLevel, plus the patterns' own state
  properties.
- Runtime ids are `[UiaAppendRuntimeId, id]` under a window. An unhosted tree
  uses `[process id, id]`, because UIA cannot append to a window that does not
  exist.

`graphics_ui_accessibility_uia_test` (win64, run under wine by the CI win64 leg,
never skipped) drives the bridge in-process with wine 9's `uiautomationcore`
as the client:

- **Through wine's client API:**
  - `UiaNodeFromProvider`.
  - `UiaGetPropertyValue`: control type, name, framework, enabled, focus,
    focusable, help text.
  - `UiaGetRuntimeId`.
  - `UiaNavigate`, with a true condition and a cache request, to the first
    child.
  - `UiaAddEvent`, which receives the focus-changed event a republication
    raises.
- **Through the provider vtables, where wine cannot help:**
  - Navigation in every direction, and QueryInterface identity.
  - Pattern discovery by role, and every pattern read.
  - Screen bounds, and ElementProviderFromPoint with real double arguments.
  - GetFocus and FragmentRoot.
  - The actions, which arrive at the application callback with UTF-16 →
    UTF-8 values.
  - Retained providers of removed nodes failing with
    `UIA_E_ELEMENTNOTAVAILABLE`.
  - `WM_GETOBJECT` declining non-UIA object ids.

Wine could not exercise the following:

- Its flat pattern functions (`InvokePattern_Invoke`, `TogglePattern_Toggle`,
  `ValuePattern_SetValue`, ...) are stubs, so patterns are driven through the
  vtables instead.
- Property-changed event registration is unimplemented, and
  `UiaRaiseAutomationPropertyChangedEvent` and
  `UiaRaiseStructureChangedEvent` are stubs. Its FIXME trace shows the bridge
  raising them with the right payload (for example Name `"A"` → `"B"`), but
  delivery is untested.
- Wine maps a provider's failure HRESULT to the reserved not-supported value,
  rather than propagating `UIA_E_ELEMENTNOTAVAILABLE` to the client.
- CI's wine has no display driver. So `WM_GETOBJECT` →
  `UiaReturnRawElementProvider`, the hosted root (`UiaHostProviderFromHwnd`,
  the window-based runtime id, `ClientToScreen` bounds) and cross-process
  clients are only built, not run.

Narrator, NVDA, JAWS, Accessibility Insights and Inspect on real Windows have
not been run against the bridge. That is the qualification still owed.

Not yet provided:

- The Text pattern (caret, selection, text ranges).
- Selection, Grid and Table container patterns.
- LiveSetting and notification events.
- MSAA (`IAccessible`) for legacy clients. `WM_GETOBJECT` for OBJID_CLIENT
  falls through to the default proxy.
- Embedded fragment roots.

## One bridge per target, and custom canvases

`graphics.__arch__.access_platform` picks the bridge for the compile target
behind five calls: `ui_access_platform_open(win, name)` (a handle, 0 when no
assistive technology is reachable), `_origin(handle, win)` (screen position,
cheap per frame), `_publish(handle, tree)`, `_dispatch(handle, tree)` (-1 once
the bus is gone) and `_close(handle)`. Linux targets use AT-SPI, win64 UI
Automation (installing the `WM_GETOBJECT` hook), wasm the ARIA mirror, and
macOS nothing by default: the NSAccessibility bridge needs its companion dylib
at load time, so it is opted into by compiling with
`--import-root tools/mac/access_cocoa`, which supplies a replacement
`graphics/__arch__/arm64_darwin/access_platform.w`.

An application canvas adds its own nodes after `ui_end` (which fixes the
widgets' focused id) and before publishing, then sets `tree.focused_id` while
it owns keyboard focus. Its items use ids outside widget issue order and below
`ui_access_root_id`. Focus requests for them arrive as `ctx.focus = id`
(the widget callback) and activations in the context's activation queue; the
application maps both back to its own selection on the next frame.
`graphics/mermaid_access.w` and `tools/wmermaid_editor.w` are the worked
example, qualified with Orca ([mermaid.md](mermaid.md), "Screen readers").
Running it found two toolkit bugs, both fixed: the AT-SPI bridge rejected
object paths above 10^8, so the widgets' document root (2^30) answered no
queries; and X11 reported Shift+Tab (ISO_Left_Tab) as no character, so reverse
focus traversal never reached the widgets.

## Focus and contrast

`ui_access_move_focus(tree, reverse)` proposes insertion-order traversal,
dispatches `UI_ACCESS_FOCUS`, and updates `focused_id` only after the host accepts.
An application that builds its own snapshot routes Tab/Shift-Tab through this
helper, changes widget/DOM focus in its callback and paints the focused node's
bounds using its focus theme token. Disabled/hidden ancestors are excluded.
Applications built from `graphics/ui/widgets` get all of this automatically,
as described in the next section.

`graphics.ui.contrast` provides sRGB relative luminance and contrast ratios
using the [WCAG formula](https://www.w3.org/WAI/WCAG21/Understanding/relative-luminance.html).
`graphics_ui_contrast_test` and its x64 twin enforce 4.5:1 for the default light
and dark themes' body, muted, button and error text, and 3:1 for focus against
background/surface. Alpha colors must be composited by the caller first.
Disabled controls, arbitrary application backgrounds, and the illustrative ocean
theme are outside this default-theme assertion. These checks do not substitute
for testing a rendered application's complete contrast and focus appearance.

Every platform bridge of #465 now exists. The web ARIA mirror and the AT-SPI
and UI Automation bridges are initial adapters, with screen-reader
qualification on real Windows, VoiceOver and NVDA, and richer semantics (text
ranges and selection, UIA table/grid and text patterns, incremental updates)
still open; AT-SPI tables and selection are covered and Orca was run headless. A semantic snapshot or a cross-compiled Cocoa binary is not
evidence that a platform has assistive technology integration.

The native implementation follows Apple's
[NSAccessibilityElement geometry contract](https://developer.apple.com/documentation/appkit/nsaccessibilityelement-swift.class/accessibilityframeinparentspace)
and [accessibility notification API](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/notification/focuseduielementchanged).
