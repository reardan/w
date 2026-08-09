/*
graphics.ui.widgets.basic: the text and button widgets — label, title,
button (docs/projects/ui_widgets.md §3).
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context


# Static text on the background; occupies one layout row.
void ui_label(ui_context* ctx, char* text):
	int scale = ctx.theme.text_scale
	ui_rect r = ui_layout_next(ctx, cast(float32, ui_text_width(text, scale)), cast(float32, ctx.theme.widget_height))
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x, ty, text, scale, ui_text_color(ctx))


# Title text: the bold title strike (scale 3) on the background.
void ui_title(ui_context* ctx, char* text):
	int scale = 3
	ui_rect r = ui_layout_next(ctx, cast(float32, ui_text_width(text, scale)), cast(float32, ctx.theme.widget_height))
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x, ty, text, scale, ui_text_color(ctx))


# Returns 1 on the frame the button is clicked. A filled accent pill:
# on_accent label ink, the hover shade while hot or pressed.
int ui_button(ui_context* ctx, char* label):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	float32 w = cast(float32, ui_text_width(label, scale) + ctx.theme.pad * 3)
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	int clicked = ui_click_behavior(ctx, id, r)
	ui_color fill = ctx.theme.accent
	ui_color ink = ctx.theme.on_accent
	if (ctx.disabled):
		fill = ctx.theme.disabled_widget
		ink = ctx.theme.disabled_text
	else if ((ctx.active == id) || (ctx.hot == id)):
		fill = ctx.theme.accent_hot
	ui_draw_rrect(ctx.rndr, r, r.h * 0.5, fill)
	ui_draw_text_centered(ctx.rndr, r, label, scale, ink)
	return clicked
