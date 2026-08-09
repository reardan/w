/*
graphics.ui.widgets: the immediate-mode widget set over the batching
renderer (docs/projects/ui_framework.md §3-4; stage 1: label, button,
checkbox; stage 2: textbox, radio, toggle, progress, dropdown).
Widgets are function calls made every frame; persistent state (a
checkbox's value, a textbox's buffer) is caller-owned, exactly like
gfx_window.

Keyboard input is context-routed: ui_feed_event queues the frame's
CHAR/NAV events on the context, and the widget holding ctx.focus
(claimed by clicking a textbox) consumes them. An open dropdown claims
ctx.modal, which makes every other widget inert until it closes — its
list draws through the renderer's overlay batch so it paints above
widgets issued later in the frame.

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

Layout is a vertical stack cursor: each widget takes the next row
(theme.widget_height tall, theme.gap between rows) starting at
theme.pad; ui_same_line places the next widget to the right of the
previous one instead.
*/
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context
import graphics.ui.widgets.basic
import graphics.ui.widgets.choice
import graphics.ui.widgets.progress
import graphics.ui.widgets.textbox
import graphics.ui.widgets.dropdown
