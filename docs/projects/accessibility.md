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
Automation (Narrator, NVDA, JAWS) as COM providers written in W, which
also answer MSAA (`IAccessible`) for older clients. The immediate-mode widgets produce snapshots automatically
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
Text range navigation, the snapshot's caret and selection (published by the
other bridges), table cell relations, incremental updates, and native object
identity preservation remain follow-ups. Document and list
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
   Publishing copies text and drops pending old requests. The mirror keeps one
   DOM element per node id and updates it in place: only changed attributes and
   text are written, only children whose position changed move, a textarea's
   value is assigned only when it differs, and never during an IME
   composition. Focus, text selection and a composition in progress therefore
   survive a republish. A node that leaves the snapshot loses its element, and
   that element's listeners stop queueing requests; a node whose role changes
   between a textarea and anything else gets a new element.
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
`compositionend` (or an input event outside composition). There are at most 64 queued requests, and
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
focus/value callbacks. Geometry, spatial touch exploration and automatic
widget semantics are not provided by this adapter.

Text selection round-trips. `ui_access_web_publish` passes each text node's
caret and selection (`gfx_access_selection`, after its text); the mirror's
textarea gets them with `setSelectionRange`, converted from code points to
UTF-16 units, backward when the caret is at the start. It is written only when
the textarea's own selection differs and never during an IME composition, and
that programmatic selection is not echoed. A user's selection or caret move on
a textarea whose node offers `UI_ACCESS_SET_SELECTION` (`select`,
`selectionchange`, `keyup` and `mouseup`, and after each committed edit,
following its value request) queues a `SET_SELECTION` request with the anchor
and active ends in code points, once per distinct selection. Read-only
textareas can still be selected. A real headless Chromium probe confirmed the
published range and direction, no echo, and that its asynchronous
`select`/`selectionchange` events queue the user's range and a collapsed caret.

Live nodes (see "Live regions and announcements" below) carry `aria-live` and
`aria-atomic="true"`. Two visually hidden live regions, one polite and one
assertive, are created with the mirror and receive the snapshot's
announcement, the text of a live region that appeared after the first
publication (browsers do not announce a region inserted with its content) and
live names or values held in attributes. Text-content changes inside a region
the browser already knows are left to the browser, so nothing is spoken twice.
Repeating an announcement alternates a trailing no-break space so that it is
still a change. An announcement made with the very first publication may be
missed, because the hidden regions only enter the page with it.

`graphics_ui_accessibility_web_test` (in `tests_wasm`) runs portable DOM contract
tests and a real
compiled W wasm instance through the existing `makeEnv` host, checking the full
publish/action/focus/value round trip, disabled-state revalidation and teardown,
element identity across publications, live attributes and announcements. The
Node fixture is not a browser accessibility implementation, so the target also
drives the mirror in real headless Chromium (`tools/web/run_accessibility_chromium.mjs`,
required on the CI wasm job, a SKIP line elsewhere without a browser). Under
Chromium 155 a republish keeps the textarea element, its focus and its
`setSelectionRange` selection; an IME composition started through the DevTools
`Input.imeSetComposition` command keeps its text across a republish and its
commit is queued once; and `Accessibility.getFullAXTree` shows the status line
as a polite atomic live region, a toast as an assertive one, and the
announcement in the hidden polite region. Chromium was not observed speaking:
no screen reader ran against it. An earlier development probe confirmed
accessible button/textbox names and values, Unicode static text, input
dispatch, stale listener rejection and canvas state restoration. Browser/screen-reader combinations still need interactive
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

Text nodes also carry a caret and a selection (`caret`, `selection_start`,
`selection_end`), in characters (code points) of the value, set with
`ui_access_set_selection(tree, id, anchor, active)` after the value; `caret`
is -1 on nodes without one and an empty selection has equal ends. Bridges move
them with `UI_ACCESS_SET_SELECTION`, whose payload is the ASCII pair
`"anchor active"` (`ui_access_dispatch_selection` builds and dispatches it,
`ui_access_selection_parse` reads it); a caret move has equal ends, and active
before anchor is a backward selection. `ui_access_dispatch` checks the payload's
form but not its range, since a request can follow an edit queued just before
it; each bridge checks the range against the text it published, and widgets
clamp. `ui_textarea` publishes its caret and selection and `ui_textbox`
(single-line, no selection) its caret; both apply a request on the next frame,
snapped to grapheme boundaries, the textbox moving its caret to the active end.

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

## Live regions and announcements

Text that changes away from the focus (a status line, a toast, a search
result count) reaches screen readers through live regions. A node with
`live` set to `UI_ACCESS_LIVE_POLITE` or `UI_ACCESS_LIVE_ASSERTIVE` is a live
region for itself and its subtree (`ui_access_live_root`). When a later
publication adds a node to a region, or changes a node's name (or a
non-textbox value), every bridge announces the new text at the region's
politeness (`ui_access_live_change`): polite waits for current speech,
assertive interrupts it. Content present at the first publication and hidden
nodes are not announced; unchanged republications announce nothing.

`ui_access_announce(tree, text, length, live)` queues a one-shot
announcement on a snapshot, for results with no on-screen text of their own.
The next publication speaks it and clears it from the application's tree (a
later call before publishing replaces it); `ui_access_tree_same` sees a
pending announcement, so a frame loop that republishes only on change still
publishes it. Bridges: AT-SPI `Object:Announcement`, UIA
`UiaRaiseNotificationEvent`, and the web mirror's hidden live regions
(details in each bridge's section). The Cocoa bridge does not publish live
regions yet.

Widgets: `ui_toast_show` marks the toast's node polite and `ui_toast_alert`
(for errors) assertive, so a toast is announced when it appears;
`ui_status(ctx, text)` is a muted label that is a polite live region. The
Mermaid editor's status line is one too (see [mermaid.md](mermaid.md),
"Screen readers"). `graphics_ui_accessibility_test` covers the model,
`graphics_ui_toast_test` the widgets, and each bridge's test the events.

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
   descriptions, progress values, text changes and live-region
   announcements.
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
offsets over UTF-8, the caret and one selection), EditableText (set, insert, delete; applied as a whole-value
`SET_VALUE`) and Value (progress percentages) as the role allows. Switches are
published as toggle buttons with checked and pressed states, since AT-SPI 2.52
has no switch role. Actions are queued (64 at most) and revalidated against the
application's tree, as in the other bridges; publishing drops queued actions
for the old snapshot.

Text reports `CaretOffset` and `GetNSelections`/`GetSelection` from the
snapshot (one selection at most). `SetCaretOffset`, `SetSelection(0, ...)`,
`AddSelection` (only while nothing is selected, and never empty) and
`RemoveSelection(0)` (which keeps the caret) queue `UI_ACCESS_SET_SELECTION`
for nodes offering it, range-checked against the published text; those nodes
also carry the selectable-text state. A republication emits
`TextSelectionChanged` when a non-empty selection appears, changes or goes,
then `TextCaretMoved` with the new offset. The bridge knows no fonts or
colours, so `GetAttributes`, `GetAttributeRun`, `GetDefaultAttributes` and
`GetDefaultAttributeSet` return empty sets, the runs spanning the whole text,
and `GetAttributeValue` an empty string.

Tables implement Table and their data cells TableCell. The snapshot has no
header flag, so the bridge treats a TABLE's first ROW as its column header
row when that row has no actions and is not selected while a later row has
actions or is selected; its cells publish as table column headers and answer
`GetColumnHeader`, `GetColumnDescription` and `GetColumnHeaderCells`. Row
indices count data rows only, every span is 1 and a cell's index is
`row * columns + column`. A row without a name of its own is named from its
cells' names (as ARIA rows are), since Orca announces a focused row by name.
That derived name (`ui_access_effective_name`) is what changes are compared
on, so a row whose cell is renamed emits `accessible-name` itself.
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
edits, text caret, selection and attributes, tables, selection, the cache
preload and the events a republication
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
exercised.

Live regions: `GetAttributes` reports `live` (`polite` or `assertive`) on a
live node and `container-live` on it and its descendants, the attribute names
Gecko and Chromium use. Orca's default script ignores name and text changes
of objects that do not have focus, so the bridge also emits
`Object:Announcement` (at-spi2-core 2.46+, what ATK's `notification` signal
becomes: detail1 is the politeness, 1 polite and 2 assertive, the variant the
text) for each live change and for the snapshot's announcement, which is sent
from the snapshot root. The Mermaid editor's qualification run
(`mermaid_editor_orca_test`, Orca 46.1, at-spi2-core 2.52) shows Orca
speaking its status line's edit results through these events: "Saved." after
the Save button is activated through AT-SPI, and "The file changed on disk.
Reload from disk discards your edits; Keep mine overwrites it on the next
save." when another program writes the file.

Text was qualified the same way (at-spi2-core 2.52, libatspi through
python `gi` Atspi) against a two-line editor: the caret offset, selectable-text
state, `get_selection`, the empty attribute run over the whole text and the
default attributes read correctly; `set_caret_offset`, `set_selection`,
`remove_selection` and `add_selection` reached the application callback as
`"5 5"`, `"8 13"`, `"13 13"` and `"0 3"`, and the republished caret and selection
read back with matching `text-caret-moved` and `text-selection-changed` events.
Orca 46.1, run headless against the same editor while it moved its own caret and
selection, said "Notes entry one two thrée." on focus, "two selected" when a word
was selected and "Text unselected." when the selection collapsed; a caret move
without keyboard input was processed silently, as Orca does for any
application. Not yet provided: real text attributes (fonts, colours,
spelling), multiple selections, row headers, multi-selection policy, and a
peer-to-peer application bus.

## Windows UI Automation and MSAA

`graphics.ui.accessibility_uia` (win64 only) publishes snapshots as server-side
UI Automation providers, and the same objects as MSAA `IAccessible` objects for
legacy clients. The COM objects are written in W: each interface is a two-word
`{vtable, element}` object whose vtable holds `win_callback` thunks, so there
is no C helper, ATL or type library. It links `uiautomationcore`, `oleacc`,
`oleaut32`, `ole32` and `user32`, all part of Windows.

1. `ui_uia_bridge* b = ui_access_uia_open(win.hwnd)` initialises COM on the
   calling thread as a single-threaded apartment. Pass 0 for a tree hosted by
   no window (tests and embedding), and give its screen position with
   `ui_access_uia_set_origin(b, x, y)`.
   Snapshot bounds are logical pixels. `ui_access_uia_set_scale(b, ratio)`
   gives the window's DPI scale (`gfx_window_pixel_ratio`; the platform
   layer sets it every frame), and bounding rectangles and
   ElementProviderFromPoint use device pixels, as UIA clients expect.
2. Set `gfx_win32_getobject = ui_access_uia_wm_getobject` (the optional
   `WM_GETOBJECT` hook in `graphics/window_win32.w`; nothing changes while it is
   unset). It answers `UiaRootObjectId` with `UiaReturnRawElementProvider`,
   `OBJID_CLIENT` with the root's `IAccessible` through `LresultFromObject`, and
   leaves every other object id (`OBJID_WINDOW`, the non-client parts) to
   `DefWindowProcW`. `ui_access_uia_getobject(b, hwnd, wparam, lparam)` is the
   same for an explicit bridge. `ui_access_platform_open` on win64 installs the
   hook.
3. `ui_access_uia_publish(b, tree)` copies the snapshot and announces what
   changed. When `UiaClientsAreListening`, it raises Name, Value, ToggleState,
   IsSelected, ExpandCollapseState and IsEnabled property changes and
   `StructureChanged` (ChildrenInvalidated) for elements a client has already
   seen, `SelectionItem_ElementSelected` on an item the selection moved to, and
   `AutomationFocusChanged` for a new focus. Then `LiveRegionChanged` once per
   live region whose text was added or changed, and the snapshot's
   announcement as a notification event. For a tree hosted by a window it
   also raises the MSAA WinEvents (`NotifyWinEvent` on `OBJID_CLIENT`, child id
   `-id`): `EVENT_OBJECT_NAMECHANGE`, `VALUECHANGE`, `STATECHANGE`, `REORDER`,
   `SELECTION` and `FOCUS`.
4. Once per frame, after pumping messages, call
   `ui_access_uia_dispatch(b, tree)`. It applies queued actions through
   `ui_access_dispatch`. Accepted focus requests also move `tree.focused_id`.
   `ui_access_uia_close(b)` releases the window's providers.

UI Automation and MSAA call the objects on the thread that opened the bridge
while it pumps messages (`ProviderOptions_UseComThreading`; `IAccessible` is
marshalled to other processes by `oleacc`). Queries are answered from the
published copy. Invoke, Toggle, SetValue, Select, Expand/Collapse and SetFocus,
and MSAA's `accDoDefaultAction`, `put_accValue` and `accSelect`, are queued (64
at most), as in the other bridges, and publishing drops the queue. Each node id
keeps one COM object across publications, so client identity is stable. Once a
node is gone, its object answers `UIA_E_ELEMENTNOTAVAILABLE` (MSAA: `E_FAIL`)
from every method and is disconnected (`UiaDisconnectProvider`). It is freed
with its last reference.

Tables and selection come from `graphics.ui.accessibility_table`, which the
AT-SPI bridge uses too, so both bridges describe the same structure: a table's
first row is its column-header row when it offers no action and is not selected
while a later row does or is; grid rows count data rows only; lists, tab lists
and tables are single-selection containers over their items, tabs and data
rows.

What is mapped:

- Every node implements IUnknown (identity: the Simple interface),
  IRawElementProviderSimple, IRawElementProviderFragment and IAccessible. The
  root adds IRawElementProviderFragmentRoot (hit testing with
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
  - table → Table, row → DataItem; the column-header row → Header, its
    cells → HeaderItem
  - radio → RadioButton
  - combobox → ComboBox
  - tab list → Tab, tab → TabItem
  - progress → ProgressBar
  - dialog → Window with IsDialog
- Patterns:
  - Invoke: activatable nodes with no other pattern.
  - Toggle: checkboxes and switches.
  - Value: textboxes; comboboxes, read-only unless they accept SET_VALUE.
  - SelectionItem: tabs, list items, data rows and radio buttons, single
    selection. Select activates. SelectionContainer is the list, tab list or
    table around the item (none for a radio button).
  - Selection: lists, tab lists and tables. GetSelection returns the
    selected items, tabs or data rows; CanSelectMultiple is false;
    IsSelectionRequired is true in tab lists.
  - Grid and Table: tables. RowCount counts data rows, ColumnCount the most
    cells in a row; GetItem(row, column) is a data cell. GetColumnHeaders is
    the header row's cells, GetRowHeaders is empty, and the table is row
    major.
  - GridItem and TableItem: data cells. Row, Column, spans of 1, the
    containing table, and the column's header cell as its column header.
  - ExpandCollapse: comboboxes, and activatable nodes with the expanded
    state.
  - RangeValue: progress, read-only 0..100, from the value's leading number.
  - Text: textboxes, below.
- Properties: Name (an unnamed row's from its cells, and its Name change
  event follows that derived name), HelpText and FullDescription, LiveSetting
  (Off, Polite or Assertive), AutomationId (the node id),
  FrameworkId `W`, IsEnabled, IsKeyboardFocusable, HasKeyboardFocus,
  IsOffscreen (hidden), IsDialog, HeadingLevel, plus the patterns' own
  properties (element-valued ones as providers, the selection as an element
  array).
- Runtime ids are `[UiaAppendRuntimeId, id]` under a window, which UIA reports
  as `[42, hwnd, 4, id]`; the hosted root has the window's own `[42, hwnd]`.
  An unhosted tree uses `[process id, id]`, because UIA cannot append to a
  window that does not exist.
- MSAA: `IAccessible` on every node (its `IDispatch` part answers
  `E_NOTIMPL`: no type information). A child is named by a VARIANT holding
  `CHILDID_SELF`, a 1-based index among the object's children, or `-id` for
  any node (the form the WinEvents use); `get_accChild` hands out the child's
  own object. Roles: the root → `ROLE_SYSTEM_CLIENT` (its parent is the
  window's system object), document, grouping, static text (text, headings),
  link, push button, check button (checkboxes, switches), text, graphic, list,
  list item, table, row, cell, column header (header-row cells), radio button,
  combo box, page tab list, page tab, progress bar, dialog. States: unavailable
  (disabled), invisible and offscreen (hidden), focusable, focused, selectable
  and selected, checked, read-only, expanded or collapsed, has-popup
  (comboboxes), linked. Names, values (textboxes, comboboxes, progress),
  descriptions, default action names (Press, Check/Uncheck, Jump, Switch,
  Select, Open/Close, Expand/Collapse), `get_accFocus`, `get_accSelection`,
  `accLocation`, `accHitTest`, and logical `accNavigate` (next, previous,
  first and last child; the spatial directions answer
  `DISP_E_MEMBERNOTFOUND`). `accDoDefaultAction` toggles or activates,
  `put_accValue` sets a value, `accSelect` takes focus and single selection.
  Help, help topics and keyboard shortcuts answer `S_FALSE`; `put_accName`
  `E_NOTIMPL`.

The Text pattern (`ITextProvider`) exposes a textbox's value, caret and
selection with single selection (`SupportedTextSelection_Single`).
`GetSelection` returns the selection, or the degenerate caret range, as one
range (none when the node has no caret); `DocumentRange` and `GetVisibleRanges`
span the whole text. `RangeFromPoint` places a caret in proportion to x across
the field, since the snapshot has no glyph geometry, and `RangeFromChild` fails
(a textbox has no children). Each range (`ITextRangeProvider`) is its own COM
object with its own reference count, holding its element; its endpoints count
code points and are clamped to the current published text on every call:

- `Clone`, `Compare`, `CompareEndpoints` and `MoveEndpointByRange`.
- `ExpandToEnclosingUnit`, `Move` and `MoveEndpointByUnit` by character, word
  (a run of non-spaces and the spaces after it), line (split after `\n`;
  paragraph is line) and document (format and page too).
- `FindText`, forwards or backwards, with ASCII case folding; `FindAttribute`
  finds nothing, and `GetAttributeValue` answers `IsReadOnly` and the reserved
  not-supported value (`UiaGetReservedNotSupportedValue`) for everything else.
- `GetBoundingRectangles` (the field's screen rectangle), `GetEnclosingElement`,
  `GetText` (with a maximum length in code points) and an empty `GetChildren`.
- `Select` queues `UI_ACCESS_SET_SELECTION` for the range; `AddToSelection` and
  `RemoveFromSelection` fail with `UIA_E_INVALIDOPERATION`, and `ScrollIntoView`
  succeeds without doing anything.

Ranges outlive publications and answer `UIA_E_ELEMENTNOTAVAILABLE` once their
node is gone. A republication raises `UIA_Text_TextChangedEventId` and
`UIA_Text_TextSelectionChangedEventId` for textboxes a client has seen when
their value, or their caret or selection, changed.

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
  - `UiaAddEvent`, which receives the focus-changed and ElementSelected
    events a republication raises, and the text-changed and
    text-selection-changed events (each exactly once).
- **Through the provider vtables, where wine cannot help:**
  - Navigation in every direction, and QueryInterface identity.
  - Pattern discovery by role, and every pattern read, Selection, Grid,
    Table, GridItem and TableItem included (header row and header cells,
    element arrays, invalid grid coordinates).
  - Screen bounds, and ElementProviderFromPoint with real double arguments.
  - GetFocus and FragmentRoot.
  - The actions, which arrive at the application callback with UTF-16 →
    UTF-8 values.
  - Retained providers of removed nodes failing with
    `UIA_E_ELEMENTNOTAVAILABLE`.
  - Every `IAccessible` method: roles and states of every role, child ids in
    each form (and invalid ones), children and parents as objects, location,
    hit testing, navigation, focus, selection, the queued actions, and a
    removed node's object failing; `OBJID_CLIENT` through `ObjectFromLresult`.
  - The Text pattern: discovery on textboxes only, the document and selection
    ranges, every range method by character, word, line and document,
    `FindText`, attributes, `Select` reaching the application as
    `SET_SELECTION`, ranges re-clamping after a republication, reference
    counts, and ranges of a removed node failing.

`graphics_ui_accessibility_uia_window_test` (win64, in `tests_win64`; the CI
win64 leg runs under `xvfb-run` with `W_CI_NO_SKIP`, and without an X display
it skips) creates a real window with `graphics/window_win32.w`'s procedure and
publishes through `ui_access_platform_open`, which installs the hook:

- **In process:** the hosted root has no runtime id of its own and a host
  provider (`UiaHostProviderFromHwnd`); its bounds follow `ClientToScreen`;
  `WM_GETOBJECT` answers `OBJID_CLIENT`; `AccessibleObjectFromWindow` returns
  the root `IAccessible`, whose parent is the window's system object; a
  republication raises `EVENT_OBJECT_FOCUS` and `EVENT_OBJECT_SELECTION`
  (`SetWinEventHook`) with `OBJID_CLIENT` and child ids `-id`, which
  `AccessibleObjectFromEvent` resolves.
- **From a second process** (the test re-runs itself as a client while the
  application pumps messages): `UiaNodeFromHandle` on the window reads the
  merged root (name, framework, Pane), its `[42, hwnd]` runtime id, the
  children's `[42, hwnd, 4, id]` ids and screen bounds, and the table's
  Header row; `AccessibleObjectFromWindow` returns oleacc's cross-process
  proxy, through which names, roles, states, child counts, child objects,
  `get_accSelection`, `accLocation` and `accHitTest` answer, and
  `accDoDefaultAction` and `put_accValue` reach the application's callback.

Wine could not exercise the following:

- Its flat pattern functions (`InvokePattern_Invoke`, `TogglePattern_Toggle`,
  `ValuePattern_SetValue`, ...) are stubs, so patterns are driven through the
  vtables instead. `UiaGetPatternProvider` is not implemented at all (calling it
  aborts), so the `TextPattern_*`/`TextRange_*` functions are unreachable.
- `UiaGetPropertyValue` answers `E_NOTIMPL` for control-pattern property ids
  (Selection, Grid, GridItem, SelectionItem, Table and IsTextPatternAvailable
  among them; it was probed for the whole 30059–30083 range), so those are
  read from the provider directly; across processes only the properties wine
  knows (name, control type, runtime id, bounds, ...) were checked.
- Property-changed event registration is unimplemented, and
  `UiaRaiseAutomationPropertyChangedEvent` and
  `UiaRaiseStructureChangedEvent` are stubs. Its FIXME trace shows the bridge
  raising them with the right payload (for example Name `"A"` → `"B"`), but
  delivery is untested.
- Wine maps a provider's failure HRESULT to the reserved not-supported value,
  rather than propagating `UIA_E_ELEMENTNOTAVAILABLE` to the client.
- Its window object (`OBJID_WINDOW`) answers `E_NOTIMPL` for `get_accRole`,
  and `LresultFromObject` logs a FIXME for the `wParam` of `0xffffffff` it is
  sent with (it still works).
- A UIA client on the application's own thread deadlocks under wine (as it
  would on Windows: the providers answer on that thread), which is why the
  window test reads through a second process. Without an X display wine
  cannot create a window at all.

Live regions and notifications: a live node reports `LiveSetting`, and a
change in its region raises `UIA_LiveRegionChangedEventId` on the region's
element, after which Narrator reads the region. The snapshot's announcement
goes through `UiaRaiseNotificationEvent` from the root element
(`NotificationKind_Other`; polite is `NotificationProcessing_All`, assertive
`NotificationProcessing_ImportantAll`; activity id `W.Announcement`). That
function only exists from Windows 10 1709, so the bridge looks it up with
`GetProcAddress` on first use and skips the event where it is missing, rather
than failing to load. Under wine 9 the test reads `LiveSetting` through
`UiaGetPropertyValue` and receives both `LiveRegionChanged` events (the
status line and a new toast) through `UiaAddEvent`, and the derived row name
before and after a cell changes. Wine exports `UiaRaiseNotificationEvent` but
as a stub: it returns `S_OK` and its FIXME trace shows the payload
(`(provider, 4, 2, L"Exported", L"W.Announcement")`), while a registered
notification handler receives nothing, so delivery is untested.

Narrator, NVDA, JAWS, Accessibility Insights and Inspect on real Windows have
not been run against the bridge. That is the qualification still owed.

Not yet provided:

- Text pattern depth: glyph geometry (ranges are bounded by the whole field,
  `RangeFromPoint` is proportional), text attributes beyond IsReadOnly,
  scrolling in `GetVisibleRanges`, `ITextProvider2` (`GetCaretRange`) and
  `ITextEditProvider`, multiple selections.
- Multiple selection, row headers, cell spans, and spatial MSAA navigation;
  `get_accSelection` reports one selected child.
- The LegacyIAccessible UIA pattern, and IAccessible2 or `IEnumVARIANT`
  children enumeration (`AccessibleChildren` falls back to `get_accChild`).
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
`graphics_ui_contrast_test` and its x64 twin check every token pair the widgets
draw, in all three presets (light, dark and ocean):

- 4.5:1 for text ([1.4.3](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html)):
  `text` on background, surface and the widget, hover and active fills;
  `text_muted` (placeholders, table headers, inactive tabs) on background,
  surface and widget; `on_accent` on accent and accent_hot; `error` on
  background and surface.
- 3:1 for non-text UI ([1.4.11](https://www.w3.org/WAI/WCAG21/Understanding/non-text-contrast.html)):
  `border` (checkbox and radio edges, the off switch track, field baselines,
  scroll thumbs) on background, surface and widget; hovered edges
  (`text_muted` on widget_hot); `accent` and `accent_hot` (checked boxes, the
  on switch track, progress, tab and selected-row markers) on their
  backgrounds; `focus` on background, surface, widget and widget_hot; the
  error underline on a field; and both switch knobs on their tracks.

A failure names the theme, the pair and the measured ratio. Adding the check
found thirteen failing pairs. `border` was 1.6 to 2.9:1 in every theme and
`text_muted` was 4.0 to 4.4:1 on field fills, so both tokens were darkened
(light) or lightened (dark, ocean), and the ocean preset's `widget_active`
was darkened so its selected-row marker reaches 3:1. Three widgets drew state with colour
contrast below 3:1, and now draw it differently:
- The off switch track used the tonal `widget` fill, about 1.3:1 on the
  surface; it now uses `border`.
- Selected table and tree rows were marked only by the `widget_active` fill,
  about 1.6:1. They now get the accent marker the dropdown list already used
  (`ui_selection_marker`).
- The tree's keyboard cursor is now an outline, so it can't be mistaken for
  that marker.

Disabled controls are exempt under WCAG ("inactive user interface
components"), so `disabled_text` and `disabled_widget` are not asserted.
Alpha colours such as `shadow` must be composited by the caller first. The
test covers the presets. An application that fills its own `ui_theme` can
run the same pair check with `ui_theme_contrast_failures(name, theme)`, which
prints each failing pair and returns the count. Arbitrary application
backgrounds are not covered. It does not replace looking at a rendered
application's contrast and focus appearance.

Every platform bridge of #465 now exists. The web ARIA mirror and the AT-SPI
and UI Automation bridges are initial adapters, with screen-reader
qualification on real Windows, VoiceOver and NVDA, and richer semantics (text
attributes, incremental updates and live regions in the Cocoa bridge) still
open. AT-SPI and UIA tables and selection are covered (with MSAA for legacy
Windows clients, and the window-hosted, cross-process UIA and MSAA paths run
under wine), and Orca was run headless; the caret and text selection
round-trip through AT-SPI, UI Automation's Text pattern and the ARIA mirror,
and live regions are announced through all three. A semantic snapshot or a cross-compiled Cocoa binary is not
evidence that a platform has assistive technology integration.

The native implementation follows Apple's
[NSAccessibilityElement geometry contract](https://developer.apple.com/documentation/appkit/nsaccessibilityelement-swift.class/accessibilityframeinparentspace)
and [accessibility notification API](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/notification/focuseduielementchanged).
