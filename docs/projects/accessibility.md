# Accessibility for custom-rendered applications

`graphics.ui.accessibility` supplies owned semantic snapshots; applications
populate them from their controls and document model. `graphics.ui.accessibility_cocoa`
now publishes those snapshots to macOS NSAccessibility through an opt-in native
companion. The existing GL window content view becomes the parent of real
`NSAccessibilityElement` objects. This is useful for a third party browser's
chrome and document content without coupling the bridge to HTML or layout.

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

## Focus and contrast

`ui_access_move_focus(tree, reverse)` proposes insertion-order traversal,
dispatches `UI_ACCESS_FOCUS`, and updates `focused_id` only after the host accepts.
The application routes Tab/Shift-Tab through this helper, changes widget/DOM
focus in its callback and paints the focused node's bounds using its focus theme
token. Disabled/hidden ancestors are excluded. This is an explicit application
integration API; immediate-mode widgets do not automatically produce snapshots
or install global Tab routing.

`graphics.ui.contrast` provides sRGB relative luminance and contrast ratios
using the [WCAG formula](https://www.w3.org/WAI/WCAG21/Understanding/relative-luminance.html).
`graphics_ui_contrast_test` and its x64 twin enforce 4.5:1 for the default light
and dark themes' body, muted, button and error text, and 3:1 for focus against
background/surface. Alpha colors must be composited by the caller first.
Disabled controls, arbitrary application backgrounds, and the illustrative ocean
theme are outside this default-theme assertion. These checks do not substitute
for testing a rendered application's complete contrast and focus appearance.

Linux AT-SPI, Windows UI Automation, the web ARIA mirror, automatic widget
semantics and widget-wide keyboard routing remain open parts of #465. A semantic
snapshot or a cross-compiled Cocoa binary is not evidence that these other
platforms have assistive technology integration.

The native implementation follows Apple's
[NSAccessibilityElement geometry contract](https://developer.apple.com/documentation/appkit/nsaccessibilityelement-swift.class/accessibilityframeinparentspace)
and [accessibility notification API](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/notification/focuseduielementchanged).
