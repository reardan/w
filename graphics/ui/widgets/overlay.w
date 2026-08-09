/*
graphics.ui.widgets.overlay: the popup scope — the one mechanism every
widget that floats above the page shares (docs/projects/ui_widgets.md
§4). A dropdown's list, a modal's dialog, a tooltip and a toast differ
in what they draw, not in how they stack.

Entering a popup switches four things together, because getting any one
of them wrong is a bug the others hide: the input scope (only the
innermost open popup takes input), the draw layer (so its geometry
paints over widgets issued later in the frame), the clip (per layer, so
a dropdown opened inside a scrolled region is not trimmed by that
region's viewport), and the layout region (so widgets inside it place
themselves in the popup's area).

Open-ness and scope are deliberately separate lifetimes.
ui_popup_begin/ui_popup_end bracket the issuing of one popup within a
frame. ui_popup_open/ui_popup_dismiss register it as open, and that
outlives the frame: a popup opened on frame N must make the widgets
issued BEFORE it on frame N+1 inert too, which a bracket alone cannot
express.
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context


# 1 when this id is the innermost open popup.
int ui_popup_is_top(ui_context* ctx, int id):
	if (ctx.popup_depth == 0):
		return 0
	if (ctx.popup_stack[ctx.popup_depth - 1] == id):
		return 1
	return 0


# Register a popup as open, making everything outside it inert until it
# is dismissed. Idempotent: a widget calls this every frame it is open
# without stacking duplicates. A push past ui_popup_max_depth is
# dropped, so the innermost popup that fits keeps input.
void ui_popup_open(ui_context* ctx, int id):
	if (ui_popup_is_top(ctx, id)):
		return
	if (ctx.popup_depth >= ui_popup_max_depth()):
		return
	ctx.popup_stack[ctx.popup_depth] = id
	ctx.popup_depth = ctx.popup_depth + 1


# Close a popup and anything that opened on top of it — a dropdown
# inside a dismissed modal goes with it rather than being left holding
# input that nothing can reach.
void ui_popup_dismiss(ui_context* ctx, int id):
	int i = 0
	while (i < ctx.popup_depth):
		if (ctx.popup_stack[i] == id):
			ctx.popup_depth = i
			return
		i = i + 1


# Enter a popup's scope: its input scope, draw layer, clip and layout
# region. Every call must be matched by ui_popup_end.
void ui_popup_begin(ui_context* ctx, int id, ui_rect area, int layer):
	if (ctx.bracket_depth < ui_popup_max_depth()):
		ctx.scope_saved[ctx.bracket_depth] = ctx.scope
		ctx.layer_saved[ctx.bracket_depth] = ctx.rndr.layer
	ctx.bracket_depth = ctx.bracket_depth + 1
	ctx.scope = id
	ui_render_layer(ctx.rndr, layer)
	# The clip includes the elevation margin: a popup's shadow draws
	# outside its own surface, and clipping it off would be worse than
	# not clipping at all.
	ui_clip_push(ctx.rndr, ui_rect_inset(area, 0.0 - ui_shadow_margin()))
	ui_region_push(ctx, area)


# Leave a popup's scope, restoring all four.
void ui_popup_end(ui_context* ctx):
	if (ctx.bracket_depth == 0):
		return
	ctx.bracket_depth = ctx.bracket_depth - 1
	ui_region_pop(ctx)
	ui_clip_pop(ctx.rndr)
	if (ctx.bracket_depth < ui_popup_max_depth()):
		ui_render_layer(ctx.rndr, ctx.layer_saved[ctx.bracket_depth])
		ctx.scope = ctx.scope_saved[ctx.bracket_depth]
	else:
		# Past the save array: the enclosing scope is unrecoverable, so
		# fall back to the base rather than leaving a stale scope in
		# force.
		ui_render_layer(ctx.rndr, UI_LAYER_BASE)
		ctx.scope = 0
