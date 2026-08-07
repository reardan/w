/*
graphics.ui.widgets: the immediate-mode widget set over the batching
renderer (docs/projects/ui_framework.md §3-4, stage 1: label, button,
checkbox). Widgets are function calls made every frame; persistent
state (a checkbox's value) is caller-owned, exactly like gfx_window.

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
import lib.lib
import graphics.gl
import graphics.window
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text


struct ui_input:
	int32 mouse_x
	int32 mouse_y
	int32 mouse_down       # button 1 currently held
	int32 mouse_pressed    # a button-1 MOUSE_DOWN arrived this frame
	int32 mouse_released   # a button-1 MOUSE_UP arrived this frame
	int32 press_x          # where this frame's press landed
	int32 press_y


struct ui_context:
	ui_renderer* rndr
	ui_theme* theme
	ui_input input
	int32 hot              # widget under the pointer this frame (0 = none)
	int32 active           # widget owning the current press (0 = none)
	int32 next_id          # per-frame sequential id counter
	float32 cursor_x
	float32 cursor_y
	float32 origin_x
	float32 last_right     # previous widget's right edge (for same_line)
	float32 last_top       # previous widget's top edge
	int32 pending_same_line


void ui_context_init(ui_context* ctx, ui_renderer* rndr, ui_theme* theme):
	ctx.rndr = rndr
	ctx.theme = theme
	ctx.input.mouse_x = 0
	ctx.input.mouse_y = 0
	ctx.input.mouse_down = 0
	ctx.input.mouse_pressed = 0
	ctx.input.mouse_released = 0
	ctx.input.press_x = 0
	ctx.input.press_y = 0
	ctx.hot = 0
	ctx.active = 0
	ctx.next_id = 1
	ctx.cursor_x = 0.0
	ctx.cursor_y = 0.0
	ctx.origin_x = 0.0
	ctx.last_right = 0.0
	ctx.last_top = 0.0
	ctx.pending_same_line = 0


# Fold one queued event into the per-frame input edges. Only button 1
# drives widget interaction in stage 1.
void ui_feed_event(ui_context* ctx, gfx_event* e):
	if ((e.kind == GFX_EVENT_MOUSE_DOWN) && (e.code == 1)):
		ctx.input.mouse_down = 1
		ctx.input.mouse_pressed = 1
		ctx.input.press_x = e.x
		ctx.input.press_y = e.y
		ctx.input.mouse_x = e.x
		ctx.input.mouse_y = e.y
	else if ((e.kind == GFX_EVENT_MOUSE_UP) && (e.code == 1)):
		ctx.input.mouse_down = 0
		ctx.input.mouse_released = 1
		ctx.input.mouse_x = e.x
		ctx.input.mouse_y = e.y


# Start a frame: reset ids/hot/layout, start the render batch, clear
# to the theme background (skipped headless).
void ui_begin(ui_context* ctx, int width, int height):
	ctx.hot = 0
	ctx.next_id = 1
	ctx.cursor_x = cast(float32, ctx.theme.pad)
	ctx.cursor_y = cast(float32, ctx.theme.pad)
	ctx.origin_x = ctx.cursor_x
	ctx.last_right = ctx.cursor_x
	ctx.last_top = ctx.cursor_y
	ctx.pending_same_line = 0
	ui_render_begin(ctx.rndr, width, height)
	if (ctx.rndr.gl_ready):
		glClearColor(ctx.theme.background.r, ctx.theme.background.g, ctx.theme.background.b, 1.0)
		glClear(GL_COLOR_BUFFER_BIT)


# Drain the window's event queue and refresh the pointer snapshot,
# then start the frame at the window's current size. The one function
# in this module that touches gfx_window.
void ui_begin_window(ui_context* ctx, gfx_window* win):
	gfx_event e
	while (gfx_window_next_event(win, &e)):
		ui_feed_event(ctx, &e)
	ctx.input.mouse_x = win.mouse_x
	ctx.input.mouse_y = win.mouse_y
	ui_begin(ctx, win.width, win.height)


# Finish a frame: draw the batch, clear the per-frame edges, release
# the press owner once the release has been seen by every widget.
void ui_end(ui_context* ctx):
	ui_render_end(ctx.rndr)
	if (ctx.input.mouse_released):
		ctx.active = 0
	ctx.input.mouse_pressed = 0
	ctx.input.mouse_released = 0


# Place the next widget on the same row as the previous one.
void ui_same_line(ui_context* ctx):
	ctx.pending_same_line = 1


# Claim the next layout rect: the stack cursor position, or to the
# right of the previous widget after ui_same_line.
ui_rect ui_layout_next(ui_context* ctx, float32 w, float32 h):
	float32 x = ctx.cursor_x
	float32 y = ctx.cursor_y
	if (ctx.pending_same_line):
		ctx.pending_same_line = 0
		x = ctx.last_right + cast(float32, ctx.theme.gap)
		y = ctx.last_top
	ui_rect r = ui_rect_new(x, y, w, h)
	ctx.last_right = r.x + r.w
	ctx.last_top = r.y
	ctx.cursor_x = ctx.origin_x
	ctx.cursor_y = r.y + r.h + cast(float32, ctx.theme.gap)
	return r


# Shared press/release logic: claims hot when the pointer is over the
# rect, active when this frame's press landed inside it; returns 1 on
# the frame the release lands while still over it.
int ui_click_behavior(ui_context* ctx, int id, ui_rect r):
	int over = ui_rect_contains(r, cast(float32, ctx.input.mouse_x), cast(float32, ctx.input.mouse_y))
	if (over):
		ctx.hot = id
	if (ctx.input.mouse_pressed):
		if (ui_rect_contains(r, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
			ctx.active = id
	if (ctx.input.mouse_released && (ctx.active == id) && over):
		return 1
	return 0


ui_color ui_widget_fill(ui_context* ctx, int id):
	if (ctx.active == id):
		return ctx.theme.widget_active
	if (ctx.hot == id):
		return ctx.theme.widget_hot
	return ctx.theme.widget


# Static text on the background; occupies one layout row.
void ui_label(ui_context* ctx, char* text):
	int scale = ctx.theme.text_scale
	ui_rect r = ui_layout_next(ctx, cast(float32, ui_text_width(text, scale)), cast(float32, ctx.theme.widget_height))
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x, ty, text, scale, ctx.theme.text)


# Returns 1 on the frame the button is clicked.
int ui_button(ui_context* ctx, char* label):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	float32 w = cast(float32, ui_text_width(label, scale) + ctx.theme.pad * 2)
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	int clicked = ui_click_behavior(ctx, id, r)
	ui_render_rect(ctx.rndr, r, ui_widget_fill(ctx, id))
	ui_draw_text_centered(ctx.rndr, r, label, scale, ctx.theme.text)
	return clicked


# Toggles *checked and returns 1 on the frame it flips. The whole
# box-plus-label row is clickable.
int ui_checkbox(ui_context* ctx, char* label, int32* checked):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	int box = ctx.theme.unit * 2
	float32 w = cast(float32, box + ctx.theme.gap + ui_text_width(label, scale))
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	int toggled = ui_click_behavior(ctx, id, r)
	if (toggled):
		checked[0] = 1 - checked[0]

	ui_rect box_rect = ui_rect_new(r.x, r.y + (r.h - cast(float32, box)) * 0.5, cast(float32, box), cast(float32, box))
	ui_render_rect(ctx.rndr, box_rect, ui_widget_fill(ctx, id))
	if (checked[0]):
		ui_render_rect(ctx.rndr, ui_rect_inset(box_rect, 3.0), ctx.theme.accent)
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x + cast(float32, box + ctx.theme.gap), ty, label, scale, ctx.theme.text)
	return toggled
