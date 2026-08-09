/*
graphics.ui.widgets: the immediate-mode widget set over the batching
renderer (docs/projects/ui_framework.md §3-4; stage 1: label, button,
checkbox; stage 2: textbox, radio, toggle, progress, dropdown).
Widgets are function calls made every frame; persistent state (a
checkbox's value, a textbox's buffer) is caller-owned, exactly like
gfx_window.

Keyboard input is context-routed: ui_feed_event queues the frame's
CHAR/NAV events on the context, and the widget holding ctx.focus
(claimed by clicking a textbox) consumes them. An open dropdown opens a
popup scope, which makes every other widget inert until it closes — its
list draws on the popup layer so it paints above widgets issued later
in the frame.

Interaction is event-queue-based (graphics.event), not snapshot-based:
ui_feed_event turns MOUSE_DOWN/MOUSE_UP into per-frame pressed/
released edges, so a press+release landing inside one poll cycle still
registers — the §7 motivation for the queue. A widget becomes `active`
when the press event landed inside it and clicks when the release
arrives while the pointer is still over it (press-drag-away-release is
not a click, matching every native toolkit).

Widget ids are sequential per frame in call order — stable for the
static forms of stage 1; hash-based ids are the flagged stage-2
refinement for dynamic layouts.

Layout is a vertical stack cursor over a stack of regions: each widget
takes the next row (theme.widget_height tall, theme.gap between rows)
in the innermost region, and ui_same_line places the next widget to the
right of the previous one instead. ui_begin seeds the root region with
the window inset by theme.pad, so the plain stack is the depth-1 case;
ui_region_push nests a sub-area for a modal body, a table cell or a
scrolled viewport.
*/
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context
import graphics.ui.widgets.overlay
import graphics.ui.widgets.basic
import graphics.ui.widgets.choice
import graphics.ui.widgets.progress
import graphics.ui.widgets.textbox
import graphics.ui.widgets.dropdown
