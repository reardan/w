/*
graphics.ui.widgets.context: frame lifecycle and shared interaction —
context init, event folding, ui_begin/ui_end, the disabled scope, and
the press/release logic plus token pickers every widget calls
(docs/projects/ui_widgets.md §3).
*/
import lib.lib
import graphics.gl
import graphics.window
import graphics.event
import graphics.__arch__.text_input
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import lib.utf8
import graphics.ui.text


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
	ctx.input.mouse_right_pressed = 0
	ctx.input.right_x = 0
	ctx.input.right_y = 0
	ctx.input.scroll_x = 0
	ctx.input.scroll_y = 0
	ctx.input.scroll_pixels_y = 0
	ctx.input.scroll_at_x = 0
	ctx.input.scroll_at_y = 0
	ctx.input.mods = 0
	ctx.hot = 0
	ctx.active = 0
	ctx.focus = 0
	ctx.disabled = 0
	ctx.next_id = 1
	ctx.char_count = 0
	ctx.nav_count = 0
	ctx.preedit[0] = 0
	ctx.preedit_length = 0
	ctx.preedit_focus = 0
	ctx.preedit_active = 0
	ctx.preedit_selection = 0
	ctx.popup_depth = 0
	ctx.scope = 0
	ctx.bracket_depth = 0
	ctx.text_input_id = 0
	ctx.text_input_scope = 0
	ctx.text_input_multiline = 0
	ctx.text_input_rect = ui_rect_new(0.0, 0.0, 0.0, 0.0)
	ctx.text_input_clip = ctx.text_input_rect
	ctx.pointer_mode = 0
	ui_layout_reset(&ctx.layout_stack[0], ui_rect_new(0.0, 0.0, 0.0, 0.0))
	ctx.layout_depth = 1
	ctx.focus_count = 0
	ctx.focus_visible = 0
	ctx.focus_tab_widget = 0
	ctx.focus_before_modal = 0
	ctx.access = 0
	ctx.access_parent = 0
	ctx.access_next_aux = 0
	ctx.access_label = 0
	ctx.access_activation_count = 0
	ctx.access_value_id = 0
	ctx.access_value_length = 0
	ctx.access_selection_id = 0


# Fold one queued event into the per-frame input edges. Only button 1
# drives pointer interaction — button 3 is a bare edge for context
# menus; CHAR/NAV queue up for the focused widget.
void ui_feed_event(ui_context* ctx, gfx_event* e):
	if ((e.kind == GFX_EVENT_MOUSE_DOWN) && (e.code == 1)):
		# Pointer use hides the keyboard focus ring until the next Tab.
		ctx.focus_visible = 0
		ctx.input.mouse_down = 1
		ctx.input.mouse_pressed = 1
		ctx.input.press_x = e.x
		ctx.input.press_y = e.y
		ctx.input.mouse_x = e.x
		ctx.input.mouse_y = e.y
	else if ((e.kind == GFX_EVENT_MOUSE_DOWN) && (e.code == 3)):
		ctx.input.mouse_right_pressed = 1
		ctx.input.right_x = e.x
		ctx.input.right_y = e.y
		ctx.input.mouse_x = e.x
		ctx.input.mouse_y = e.y
	else if ((e.kind == GFX_EVENT_MOUSE_UP) && (e.code == 1)):
		ctx.input.mouse_down = 0
		ctx.input.mouse_released = 1
		ctx.input.mouse_x = e.x
		ctx.input.mouse_y = e.y
	else if (e.kind == GFX_EVENT_SCROLL):
		# Wheel notches accumulate over the frame; the scroll region
		# under the pointer claims and zeroes them.
		ctx.input.scroll_y = ctx.input.scroll_y + e.code
		ctx.input.scroll_at_x = e.x
		ctx.input.scroll_at_y = e.y
	else if (e.kind == GFX_EVENT_SCROLL_PIXELS):
		ctx.input.scroll_pixels_y = ctx.input.scroll_pixels_y + e.code
		ctx.input.scroll_at_x = e.x
		ctx.input.scroll_at_y = e.y
	else if (e.kind == GFX_EVENT_POINTER_CANCEL):
		ctx.input.mouse_down = 0
		ctx.input.mouse_pressed = 0
		ctx.input.mouse_released = 0
		ctx.input.mouse_right_pressed = 0
		ctx.active = 0
	else if (e.kind == GFX_EVENT_PREEDIT_BEGIN):
		ctx.preedit_length = 0
		ctx.preedit[0] = 0
		ctx.preedit_focus = e.x
		if (ctx.preedit_focus == 0): ctx.preedit_focus = ctx.focus
		ctx.preedit_active = 1
		ctx.preedit_selection = e.y
	else if (e.kind == GFX_EVENT_PREEDIT_TEXT):
		if (ctx.preedit_active && ((e.x == 0) || (e.x == ctx.preedit_focus))):
			int cp = e.code
			if ((cp >= 32) && (cp <= 1114111) && ((cp < 55296) || (cp > 57343))):
				char[4] bytes
				int n = utf8_encode(&bytes[0], cp)
				if (ctx.preedit_length + n < 1024):
					for i in range(n): ctx.preedit[ctx.preedit_length + i] = bytes[i]
					ctx.preedit_length = ctx.preedit_length + n
					ctx.preedit[ctx.preedit_length] = 0
	else if (e.kind == GFX_EVENT_PREEDIT_END):
		if ((e.x == 0) || (e.x == ctx.preedit_focus)):
			ctx.preedit_active = 0
			ctx.preedit_length = 0
			ctx.preedit[0] = 0
	else if (e.kind == GFX_EVENT_CHAR):
		if (ctx.char_count < 32):
			ctx.chars[ctx.char_count] = e.code
			ctx.char_mods[ctx.char_count] = e.mods
			ctx.char_count = ctx.char_count + 1
	else if (e.kind == GFX_EVENT_NAV):
		if (ctx.nav_count < 8):
			ctx.navs[ctx.nav_count] = e.code
			ctx.nav_mods[ctx.nav_count] = e.mods
			ctx.nav_count = ctx.nav_count + 1
	ctx.input.mods = e.mods


# Move keyboard focus one stop along the previous frame's focus order,
# wrapping; with nothing focused, Tab enters at the first stop and
# Shift-Tab at the last.
void ui_focus_step(ui_context* ctx, int reverse):
	int count = ctx.focus_count
	if (count == 0): return
	int at = 0 - 1
	for i in range(count):
		if (ctx.focus_order[i] == ctx.focus): at = i
	if (at < 0):
		if (reverse): at = count - 1
		else: at = 0
	else if (reverse):
		at = at - 1
		if (at < 0): at = count - 1
	else:
		at = at + 1
		if (at >= count): at = 0
	ctx.focus = ctx.focus_order[at]
	ctx.focus_visible = 1


# 1 when focus belongs to the application rather than a widget: an id
# past the previous frame's widget ids (ctx.next_id has not been reset
# yet) that registered no focus stop, such as a custom canvas.
int ui_focus_app_owned(ui_context* ctx):
	if ((ctx.focus == 0) || (ctx.focus < ctx.next_id)): return 0
	for i in range(ctx.focus_count):
		if (ctx.focus_order[i] == ctx.focus): return 0
	return 1


# Drain this frame's Tab/Shift-Tab CHARs into focus moves. Plain Tab
# stays queued for a focused stop that consumes it (a textarea indents)
# and for application-owned focus; Ctrl+Tab always moves, the GTK
# convention for leaving such a field.
void ui_focus_route(ui_context* ctx):
	int kept = 0
	int i = 0
	while (i < ctx.char_count):
		int ch = ctx.chars[i]
		int mods = ctx.char_mods[i]
		int owner = (ctx.focus_tab_widget == ctx.focus) || ui_focus_app_owned(ctx)
		int claimed = (ctx.focus != 0) && owner && ((mods & GFX_MOD_CTRL) == 0)
		if ((ch == 9) && ((mods & (GFX_MOD_ALT | GFX_MOD_SUPER)) == 0) && (claimed == 0)):
			ui_focus_step(ctx, mods & GFX_MOD_SHIFT)
		else:
			ctx.chars[kept] = ch
			ctx.char_mods[kept] = mods
			kept = kept + 1
		i = i + 1
	ctx.char_count = kept


# Start a frame: reset ids/hot/layout, start the render batch, clear
# to the theme background (skipped headless).
void ui_begin(ui_context* ctx, int width, int height):
	# Tab routes against last frame's stops and ids before they are
	# rebuilt.
	ui_focus_route(ctx)
	ctx.hot = 0
	ctx.next_id = 1
	ctx.focus_count = 0
	ctx.focus_tab_widget = 0
	ctx.access_label = 0
	ctx.access_next_aux = 0
	ctx.access_parent = 0
	if (ctx.access != 0):
		if (ui_access_add(ctx.access, ui_access_root_id, 0, UI_ACCESS_DOCUMENT, ui_rect_new(0.0, 0.0, cast(float32, width), cast(float32, height))) != 0):
			ctx.access_parent = ui_access_root_id
	# The root region is the window inset by the theme pad, so the
	# plain vertical stack is just the depth-1 case of a region.
	float32 pad = cast(float32, ctx.theme.pad)
	ui_layout_reset(&ctx.layout_stack[0], ui_rect_new(pad, pad, cast(float32, width) - pad * 2.0, cast(float32, height) - pad * 2.0))
	ctx.layout_depth = 1
	# Scope is per-frame; the open-popup stack is not (it has to outlive
	# the frame that opened it to make earlier widgets inert).
	ctx.scope = 0
	ctx.bracket_depth = 0
	ctx.text_input_id = 0
	ctx.text_input_scope = 0
	ctx.text_input_multiline = 0
	ctx.text_input_rect = ui_rect_new(0.0, 0.0, 0.0, 0.0)
	ctx.text_input_clip = ctx.text_input_rect
	ctx.pointer_mode = 0
	ui_render_begin(ctx.rndr, width, height)
	if (ctx.rndr.gl_ready):
		glClearColor(ctx.theme.background.r, ctx.theme.background.g, ctx.theme.background.b, 1.0)
		glClear(GL_COLOR_BUFFER_BIT)


# Drain the window's event queue and refresh the pointer snapshot,
# then start the frame at the window's current size. The one function
# in this module that touches gfx_window.
void ui_begin_window(ui_context* ctx, gfx_window* win):
	gfx_event e
	while (gfx_window_next_event(win, &e)): ui_feed_event(ctx, &e)
	ctx.input.mouse_x = win.mouse_x
	ctx.input.mouse_y = win.mouse_y
	ui_render_set_pixel_scale(ctx.rndr, gfx_window_pixel_ratio(win))
	ui_begin(ctx, win.width, win.height)


# Revalidate after the whole frame: a later widget may open a popup over
# an editor that already declared itself. Popup editors retain their scope
# even after ui_popup_end restores the outer scope.
int ui_text_input_active(ui_context* ctx):
	if ((ctx.text_input_id == 0) || (ctx.text_input_id != ctx.focus)): return 0
	if (ctx.popup_depth > 0):
		if (ctx.text_input_scope != ctx.popup_stack[ctx.popup_depth - 1]): return 0
	else if (ctx.text_input_scope != 0): return 0
	return ui_rect_is_empty(ui_rect_intersect(ctx.text_input_rect, ctx.text_input_clip)) == 0


# Finish a frame: draw the batch, clear the per-frame edges, release
# the press owner once the release has been seen by every widget.
void ui_end(ui_context* ctx):
	ui_render_end(ctx.rndr)
	if (ctx.preedit_focus != ctx.focus):
		ctx.preedit_active = 0
		ctx.preedit_length = 0
		ctx.preedit[0] = 0
	# Sync only after every widget has declared itself; no transient blur
	# between ui_begin and the focused field. Headless tests have no host.
	if (ctx.rndr.gl_ready):
		ui_rect r = ui_rect_intersect(ctx.text_input_rect, ctx.text_input_clip)
		int editing = ui_text_input_active(ctx)
		gfx_text_input(editing, ctx.text_input_multiline, cast(int, r.x), cast(int, r.y), cast(int, r.w), cast(int, r.h), ctx.text_input_id)
		gfx_pointer_mode(ctx.pointer_mode)
	if (ctx.access != 0):
		ui_access_node* focused = ui_access_find(ctx.access, ctx.focus)
		ctx.access.focused_id = 0
		if ((focused != 0) && ((focused.states & UI_ACCESS_FOCUSABLE) != 0)): ctx.access.focused_id = ctx.focus
	# Assistive requests live for exactly the frame after their dispatch.
	ctx.access_activation_count = 0
	ctx.access_value_id = 0
	ctx.access_selection_id = 0
	if (ctx.input.mouse_released): ctx.active = 0
	ctx.input.mouse_pressed = 0
	ctx.input.mouse_released = 0
	ctx.input.mouse_right_pressed = 0
	ctx.input.scroll_x = 0
	ctx.input.scroll_y = 0
	ctx.input.scroll_pixels_y = 0
	ctx.char_count = 0
	ctx.nav_count = 0


# Open/close a disabled scope: widgets inside render with the
# disabled tokens and ignore all input.
void ui_disable(ui_context* ctx, int on):
	ctx.disabled = on


# 1 when the code being issued is outside the innermost open popup.
# Everything else on screen is inert while a popup is open — the popup
# handles all input itself — and that has to hold for widgets issued
# BEFORE the popup in the frame as well, which is why the open-popup
# stack persists across frames instead of being a frame-scoped bracket.
int ui_scope_blocked(ui_context* ctx):
	if (ctx.popup_depth == 0): return 0
	if (ctx.scope == ctx.popup_stack[ctx.popup_depth - 1]): return 0
	return 1


# 1 when a CHAR arriving with these gfx_mod bits is typing rather than
# a command chord. Ctrl or Super held makes it a shortcut (Ctrl+S is
# not an 's'), unless Alt is held too: AltGr arrives as Ctrl+Alt on
# Windows and types real characters.
int ui_char_is_typing(int mods):
	if (mods & GFX_MOD_ALT): return 1
	return (mods & (GFX_MOD_CTRL | GFX_MOD_SUPER)) == 0


# A clipped-away widget must not receive a touch through its viewport.
int ui_pointer_inside(ui_context* ctx, ui_rect r, float32 x, float32 y):
	return ui_rect_contains(ui_rect_intersect(r, ui_clip_current(ctx.rndr)), x, y)


# Register only the focused, enabled editor; ui_end sends the final one.
void ui_text_input_declare(ui_context* ctx, int id, ui_rect area, int multiline):
	if ((ctx.focus != id) || ctx.disabled || ui_scope_blocked(ctx)): return
	ctx.text_input_id = id
	ctx.text_input_scope = ctx.scope
	ctx.text_input_multiline = multiline
	ctx.text_input_rect = area
	ctx.text_input_clip = ui_clip_current(ctx.rndr)


# Shared press/release logic: claims hot when the pointer is over the
# rect, active when this frame's press landed inside it; returns 1 on
# the frame the release lands while still over it. Inert inside a
# ui_disable scope, or outside the innermost open popup.
int ui_click_behavior(ui_context* ctx, int id, ui_rect r):
	if (ctx.disabled): return 0
	if (ui_scope_blocked(ctx)): return 0
	int over = ui_pointer_inside(ctx, r, cast(float32, ctx.input.mouse_x), cast(float32, ctx.input.mouse_y))
	if (over): ctx.hot = id
	if (ctx.input.mouse_pressed):
		if (ui_pointer_inside(ctx, r, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
			ctx.active = id
	if (ctx.input.mouse_released && (ctx.active == id) && over): return 1
	return 0


# Consume a pending activate/toggle request for id: 1 when there was
# one. Widgets call it only where a click would also be accepted.
int ui_access_take_activation(ui_context* ctx, int id):
	for i in range(ctx.access_activation_count):
		if (ctx.access_activations[i] == id):
			ctx.access_activation_count = ctx.access_activation_count - 1
			ctx.access_activations[i] = ctx.access_activations[ctx.access_activation_count]
			return 1
	return 0


# Take one Space or Return keypress (no command modifiers) from the
# frame's CHAR queue: the focused control's activation key.
int ui_focus_take_activation(ui_context* ctx):
	int i = 0
	while (i < ctx.char_count):
		int ch = ctx.chars[i]
		if (((ch == 32) || (ch == 13)) && ((ctx.char_mods[i] & (GFX_MOD_CTRL | GFX_MOD_ALT | GFX_MOD_SUPER)) == 0)):
			# 0 is no character at all: every consumer skips it.
			ctx.chars[i] = 0
			return 1
		i = i + 1
	return 0


# ui_click_behavior plus the non-pointer paths a focusable control
# needs: Space or Return while it holds focus, and an activate/toggle
# request from an accessibility bridge (ui_access_capture). Editors keep
# calling ui_click_behavior so typed spaces stay text.
int ui_activate_behavior(ui_context* ctx, int id, ui_rect r):
	int clicked = ui_click_behavior(ctx, id, r)
	if (ctx.disabled || ui_scope_blocked(ctx)): return clicked
	if (ui_access_take_activation(ctx, id)):
		clicked = 1
	if ((ctx.focus == id) && ui_focus_take_activation(ctx)): clicked = 1
	return clicked


# A rectangle outline t pixels thick, drawn inside o.
void ui_outline(ui_context* ctx, ui_rect o, float32 t, ui_color c):
	ui_render_rect(ctx.rndr, ui_rect_new(o.x, o.y, o.w, t), c)
	ui_render_rect(ctx.rndr, ui_rect_new(o.x, o.y + o.h - t, o.w, t), c)
	ui_render_rect(ctx.rndr, ui_rect_new(o.x, o.y + t, t, o.h - t * 2.0), c)
	ui_render_rect(ctx.rndr, ui_rect_new(o.x + o.w - t, o.y + t, t, o.h - t * 2.0), c)


# A 2px ring in the theme's focus token, 2px outside r so the control's
# own fill never covers it.
void ui_focus_ring(ui_context* ctx, ui_rect r):
	ui_outline(ctx, ui_rect_inset(r, 0.0 - 4.0), 2.0, ctx.theme.focus)


# The accent bar at the left edge of a selected row (tables, trees, the
# dropdown list). The row's tonal fill alone is under 3:1 against the
# surface, so the bar is what carries the selected state (WCAG 1.4.11).
void ui_selection_marker(ui_context* ctx, ui_rect row):
	ui_draw_rrect(ctx.rndr, ui_rect_new(row.x + 3.0, row.y + 7.0, 4.0, row.h - 14.0), 2.0, ctx.theme.accent)


# Register id as this frame's next keyboard focus stop. A press inside r
# focuses it; while focused after keyboard navigation it draws the focus
# ring. claims_tab marks a control that consumes plain Tab itself.
# Disabled and popup-blocked controls are skipped. Returns 1 while id
# holds focus.
int ui_focus_stop(ui_context* ctx, int id, ui_rect r, int claims_tab):
	if (ctx.disabled || ui_scope_blocked(ctx)): return 0
	if (ctx.focus_count < ui_focus_max_stops):
		ctx.focus_order[ctx.focus_count] = id
		ctx.focus_count = ctx.focus_count + 1
	if (ctx.input.mouse_pressed && ui_pointer_inside(ctx, r, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
		ctx.focus = id
	ui_access_node* n = ui_access_find(ctx.access, id)
	if (n != 0):
		n.states = n.states | UI_ACCESS_FOCUSABLE
		n.actions = n.actions | UI_ACCESS_FOCUS
	if (ctx.focus != id): return 0
	if (claims_tab): ctx.focus_tab_widget = id
	if (ctx.focus_visible): ui_focus_ring(ctx, r)
	return 1


# The next id for a semantic node no widget id names (labels, groups).
int ui_access_aux_id(ui_context* ctx):
	ctx.access_next_aux = ctx.access_next_aux + 1
	return ui_access_root_id + ctx.access_next_aux


# Add a semantic node for the widget being issued, under the current
# semantic parent, when a capture is active; 0 otherwise. A null name
# takes the pending form-row label. Disabled scope is reflected; the
# caller sets role-specific states, value and actions on the result.
ui_access_node* ui_access_widget(ui_context* ctx, int id, int role, ui_rect r, char* name):
	if (ctx.access == 0): return 0
	if (name == 0): name = ctx.access_label
	ctx.access_label = 0
	ui_access_node* n = ui_access_add(ctx.access, id, ctx.access_parent, role, r)
	if (n == 0): return 0
	if (name != 0): ui_access_set_text(ctx.access, id, UI_ACCESS_NAME, name, strlen(name))
	if (ctx.disabled): n.states = n.states | UI_ACCESS_DISABLED
	return n


void ui_access_set_value(ui_context* ctx, ui_access_node* n, char* value, int length):
	if (n != 0): ui_access_set_text(ctx.access, n.id, UI_ACCESS_VALUE, value, length)


# A pending set-value request for id this frame, or 0. The bytes are
# valid UTF-8, NUL-terminated at access_value_length.
char* ui_access_value_request(ui_context* ctx, int id):
	if ((ctx.access_value_id != id) || (id == 0) || ctx.disabled || ui_scope_blocked(ctx)): return 0
	ctx.access_value_id = 0
	return &ctx.access_value[0]


# A pending caret/selection request for id this frame: 1 with the
# anchor and active ends (characters of the value the requester saw),
# else 0. Apply it after any value request.
int ui_access_selection_request(ui_context* ctx, int id, int* anchor, int* active):
	if ((ctx.access_selection_id != id) || (id == 0) || ctx.disabled || ui_scope_blocked(ctx)): return 0
	ctx.access_selection_id = 0
	anchor[0] = ctx.access_selection_anchor
	active[0] = ctx.access_selection_active
	return 1


# Record a text widget's caret and selection on its node, given as byte
# offsets into the value it set (ui_access_set_value first).
void ui_access_set_caret(ui_context* ctx, ui_access_node* n, int anchor_byte, int caret_byte):
	if (n == 0): return
	int anchor = ui_access_byte_char(n.value.data, n.value.length, anchor_byte)
	int caret = ui_access_byte_char(n.value.data, n.value.length, caret_byte)
	ui_access_set_selection(ctx.access, n.id, anchor, caret)


# The tree action callback ui_access_capture installs: focus applies at
# once, activation and values are held for the named widget to apply
# (and revalidate) on the next frame.
int ui_access_widget_action(void* context, int id, int action, char* data, int length):
	ui_context* ctx = cast(ui_context*, context)
	if (action == UI_ACCESS_FOCUS):
		ctx.focus = id
		ctx.focus_visible = 1
		return 1
	if ((action == UI_ACCESS_ACTIVATE) || (action == UI_ACCESS_TOGGLE)):
		if (ctx.access_activation_count >= 16): return 0
		ctx.access_activations[ctx.access_activation_count] = id
		ctx.access_activation_count = ctx.access_activation_count + 1
		return 1
	if (action == UI_ACCESS_SET_VALUE):
		if (length > 1023): return 0
		for i in range(length): ctx.access_value[i] = data[i]
		ctx.access_value[length] = 0
		ctx.access_value_length = length
		ctx.access_value_id = id
		return 1
	if (action == UI_ACCESS_SET_SELECTION):
		int anchor = 0
		int active = 0
		if (!ui_access_selection_parse(data, length, &anchor, &active)): return 0
		ctx.access_selection_anchor = anchor
		ctx.access_selection_active = active
		ctx.access_selection_id = id
		return 1
	return 0


# Capture the next frame's widget semantics into tree, a fresh snapshot
# (ui_access_tree_new); 0 stops capturing. ui_begin adds the document
# root; publish the tree after ui_end. Bridge actions dispatched against
# it reach the widgets on the following frame.
void ui_access_capture(ui_context* ctx, ui_access_tree* tree):
	ctx.access = tree
	if (tree != 0):
		tree.action = ui_access_widget_action
		tree.context = cast(void*, ctx)


ui_color ui_widget_fill(ui_context* ctx, int id):
	if (ctx.disabled): return ctx.theme.disabled_widget
	if (ctx.active == id): return ctx.theme.widget_active
	if (ctx.hot == id): return ctx.theme.widget_hot
	return ctx.theme.widget


ui_color ui_text_color(ui_context* ctx):
	if (ctx.disabled): return ctx.theme.disabled_text
	return ctx.theme.text


# Whether field id is showing an IME preview this frame. Callers draw
# their own caret only when it is not: the preview carries the caret.
int ui_text_preedit_showing(ui_context* ctx, int id):
	if ((ctx.focus != id) || (ctx.preedit_focus != id) || (ctx.preedit_active == 0)): return 0
	if (ctx.disabled || ui_scope_blocked(ctx)): return 0
	return 1


# Draw a clipped, underlined IME preview at the insertion point, with the
# caret after it as native fields show a composing word. The caller's
# buffer/selection remains untouched until committed CHARs arrive.
void ui_text_preedit(ui_context* ctx, int id, ui_rect clip, float32 x, float32 y):
	if (ui_text_preedit_showing(ctx, id) == 0): return
	ui_clip_push(ctx.rndr, clip)
	int scale = ctx.theme.text_scale
	int width = ui_text_width(&ctx.preedit[0], scale)
	int height = ui_text_height(scale)
	ui_render_rect(ctx.rndr, ui_rect_new(x, y, cast(float32, width), cast(float32, height)), ctx.theme.widget)
	ui_draw_text(ctx.rndr, x, y, &ctx.preedit[0], scale, ctx.theme.text)
	ui_render_rect(ctx.rndr, ui_rect_new(x, y + cast(float32, height - 1), cast(float32, width), 1.0), ctx.theme.focus)
	ui_render_rect(ctx.rndr, ui_rect_new(x + cast(float32, width), y, 2.0, cast(float32, height)), ctx.theme.text)
	ui_clip_pop(ctx.rndr)
