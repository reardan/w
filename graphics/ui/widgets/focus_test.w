# Headless tests for keyboard focus and widget semantics (#465): Tab and
# Shift-Tab order across widgets, the focus ring, Space/Return
# activation, disabled and popup scopes, Tab-consuming editors, modal
# focus hand-off, and the automatic semantic snapshot with assistive
# actions routed back into the widgets.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_focus_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.accessibility
import graphics.ui.accessibility_table
import graphics.ui.widgets
import graphics.ui.testing


struct form_model:
	int32 clicks
	int32 checked
	int32 radio
	int32 on
	int32 disabled_clicks
	int32 disable_middle
	ui_textbox_state name
	ui_form_state form


void form_model_init(form_model* m):
	m.clicks = 0
	m.checked = 0
	m.radio = 0
	m.on = 0
	m.disabled_clicks = 0
	m.disable_middle = 0
	ui_textbox_init(&m.name)


# Ids in issue order: button 1, checkbox 2, disabled-or-live button 3,
# textbox 4, radios 5 and 6, toggle 7.
void form_frame(ui_context* ctx, form_model* m):
	ui_begin(ctx, 400, 400)
	ui_title(ctx, c"Settings")
	if (ui_button(ctx, c"Save")): m.clicks = m.clicks + 1
	ui_checkbox(ctx, c"Wrap", &m.checked)
	if (m.disable_middle): ui_disable(ctx, 1)
	if (ui_button(ctx, c"Danger")): m.disabled_clicks = m.disabled_clicks + 1
	ui_disable(ctx, 0)
	ui_form_begin(ctx, &m.form, ui_region_content(ctx), 80.0)
	ui_form_row(ctx, &m.form, c"Name")
	ui_textbox(ctx, 160.0, &m.name)
	ui_form_end(ctx, &m.form)
	ui_radio(ctx, c"Small", 0, &m.radio)
	ui_radio(ctx, c"Large", 1, &m.radio)
	ui_toggle(ctx, c"Dark", &m.on)
	ui_progress(ctx, 100.0, 0.5)
	ui_end(ctx)


void tab(ui_context* ctx, int mods):
	ui_test_event(ctx, GFX_EVENT_CHAR, 9, 0, 0, mods)


void test_tab_walks_every_stop_in_order_and_wraps():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	form_model m
	form_model_init(&m)
	form_frame(ctx, &m)
	assert_equal(0, ctx.focus)
	assert_equal(7, ctx.focus_count)

	tab(ctx, 0)
	form_frame(ctx, &m)
	assert_equal(1, ctx.focus)
	assert_equal(1, ctx.focus_visible)
	int32[7] expected
	expected[0] = 2
	expected[1] = 3
	expected[2] = 4
	expected[3] = 5
	expected[4] = 6
	expected[5] = 7
	expected[6] = 1
	for i in range(7):
		tab(ctx, 0)
		form_frame(ctx, &m)
		assert_equal(expected[i], ctx.focus)

	# Shift-Tab walks back, wrapping from the first stop to the last.
	tab(ctx, GFX_MOD_SHIFT)
	form_frame(ctx, &m)
	assert_equal(7, ctx.focus)
	tab(ctx, GFX_MOD_SHIFT)
	form_frame(ctx, &m)
	assert_equal(6, ctx.focus)
	ui_render_destroy(&fx.r)


void test_disabled_controls_are_skipped():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	form_model m
	form_model_init(&m)
	m.disable_middle = 1
	form_frame(ctx, &m)
	assert_equal(6, ctx.focus_count)
	ctx.focus = 2
	tab(ctx, 0)
	form_frame(ctx, &m)
	assert_equal(4, ctx.focus)
	ui_render_destroy(&fx.r)


void test_focus_ring_draws_only_after_keyboard_navigation():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	form_model m
	form_model_init(&m)
	# Clicking focuses the button but shows no ring.
	ui_test_click(ctx, 20, 60)
	form_frame(ctx, &m)
	assert_equal(1, m.clicks)
	assert_equal(1, ctx.focus)
	assert_equal(0, ctx.focus_visible)
	form_frame(ctx, &m)
	int plain = fx.r.layer_vert_count[UI_LAYER_BASE]
	# Tab then Shift-Tab lands on the same button with the ring showing:
	# four extra quads.
	tab(ctx, 0)
	tab(ctx, GFX_MOD_SHIFT)
	form_frame(ctx, &m)
	assert_equal(1, ctx.focus)
	assert_equal(1, ctx.focus_visible)
	assert_equal(plain + 24, fx.r.layer_vert_count[UI_LAYER_BASE])
	ui_render_destroy(&fx.r)


void test_space_and_return_activate_the_focused_control():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	form_model m
	form_model_init(&m)
	form_frame(ctx, &m)
	tab(ctx, 0)
	form_frame(ctx, &m)
	ui_test_char(ctx, 32)
	form_frame(ctx, &m)
	assert_equal(1, m.clicks)
	ui_test_char(ctx, 13)
	form_frame(ctx, &m)
	assert_equal(2, m.clicks)
	# Ctrl+Return is a command chord, not an activation.
	ui_test_event(ctx, GFX_EVENT_CHAR, 13, 0, 0, GFX_MOD_CTRL)
	form_frame(ctx, &m)
	assert_equal(2, m.clicks)

	tab(ctx, 0)
	ui_test_char(ctx, 32)
	form_frame(ctx, &m)
	assert_equal(1, m.checked)

	# The textbox keeps typing spaces rather than activating anything.
	tab(ctx, 0)
	tab(ctx, 0)
	form_frame(ctx, &m)
	assert_equal(4, ctx.focus)
	ui_test_text(ctx, c"a b")
	form_frame(ctx, &m)
	assert_strings_equal(c"a b", &m.name.text[0])
	assert_equal(2, m.clicks)

	# Radio selects, toggle flips.
	tab(ctx, 0)
	tab(ctx, 0)
	ui_test_char(ctx, 32)
	form_frame(ctx, &m)
	assert_equal(6, ctx.focus)
	assert_equal(1, m.radio)
	tab(ctx, 0)
	ui_test_char(ctx, 32)
	form_frame(ctx, &m)
	assert_equal(1, m.on)
	ui_render_destroy(&fx.r)


void area_frame(ui_context* ctx, ui_textarea_state* ta, int32* clicks):
	ui_begin(ctx, 400, 400)
	ui_textarea(ctx, ui_rect_new(8.0, 8.0, 200.0, 100.0), ta)
	ui_layout_next(ctx, 10.0, 100.0)
	if (ui_button(ctx, c"After")): clicks[0] = clicks[0] + 1
	ui_end(ctx)


void test_a_textarea_keeps_tab_and_ctrl_tab_leaves():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textarea_state ta
	ui_textarea_init(&ta)
	int32 clicks = 0
	area_frame(ctx, &ta, &clicks)
	tab(ctx, 0)
	area_frame(ctx, &ta, &clicks)
	assert_equal(1, ctx.focus)
	# Plain Tab indents.
	tab(ctx, 0)
	area_frame(ctx, &ta, &clicks)
	assert_equal(1, ctx.focus)
	assert_equal(1, ta.buf.length)
	# Ctrl+Tab leaves for the button (id 3: the textarea's scroll
	# viewport takes id 2).
	tab(ctx, GFX_MOD_CTRL)
	area_frame(ctx, &ta, &clicks)
	assert_equal(3, ctx.focus)
	assert_equal(1, ta.buf.length)
	ui_textarea_free(&ta)
	ui_render_destroy(&fx.r)


# Focus an application hands to its own surface (an id past every
# widget's, like a canvas) keeps plain Tab; Ctrl+Tab still leaves.
void test_application_owned_focus_keeps_tab():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	form_model m
	form_model_init(&m)
	form_frame(ctx, &m)
	ctx.focus = 900001
	tab(ctx, 0)
	ui_begin(ctx, 400, 400)
	assert_equal(900001, ctx.focus)
	assert_equal(1, ctx.char_count)
	assert_equal(9, ctx.chars[0])
	ui_end(ctx)
	form_frame(ctx, &m)
	tab(ctx, GFX_MOD_CTRL)
	form_frame(ctx, &m)
	assert_equal(1, ctx.focus)
	ui_render_destroy(&fx.r)


void modal_frame(ui_context* ctx, int32* open, int32* opened, int32* ok):
	ui_begin(ctx, 320, 240)
	if (ui_button(ctx, c"Open")): open[0] = 1
	if (ui_modal_begin(ctx, c"Confirm", 200.0, 120.0, open)):
		if (ui_button(ctx, c"OK")):
			ok[0] = ok[0] + 1
			open[0] = 0
		ui_modal_end(ctx)
	ui_end(ctx)


void test_a_modal_takes_focus_and_gives_it_back():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	int32 open = 0
	int32 opened = 0
	int32 ok = 0
	modal_frame(ctx, &open, &opened, &ok)
	tab(ctx, 0)
	modal_frame(ctx, &open, &opened, &ok)
	ui_test_char(ctx, 32)
	modal_frame(ctx, &open, &opened, &ok)
	assert_equal(1, open)
	# The dialog (id 2) holds focus; the page behind it is not a stop.
	assert_equal(2, ctx.focus)
	modal_frame(ctx, &open, &opened, &ok)
	assert_equal(1, ctx.focus_count)
	tab(ctx, 0)
	modal_frame(ctx, &open, &opened, &ok)
	assert_equal(3, ctx.focus)
	tab(ctx, 0)
	modal_frame(ctx, &open, &opened, &ok)
	assert_equal(3, ctx.focus)
	ui_test_char(ctx, 13)
	modal_frame(ctx, &open, &opened, &ok)
	assert_equal(1, ok)
	modal_frame(ctx, &open, &opened, &ok)
	assert_equal(0, open)
	assert_equal(1, ctx.focus)
	ui_render_destroy(&fx.r)


int dropdown_frame(ui_context* ctx, int32* selected, int32* open):
	char*[3] items
	items[0] = c"Light"
	items[1] = c"Dark"
	items[2] = c"Ocean"
	ui_begin(ctx, 320, 240)
	int changed = ui_dropdown(ctx, 120.0, &items[0], 3, selected, open)
	ui_end(ctx)
	return changed


void test_dropdown_opens_moves_and_closes_from_the_keyboard():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	int32 selected = 0
	int32 open = 0
	dropdown_frame(ctx, &selected, &open)
	tab(ctx, 0)
	dropdown_frame(ctx, &selected, &open)
	ui_test_char(ctx, 32)
	dropdown_frame(ctx, &selected, &open)
	assert_equal(1, open)
	ui_test_nav(ctx, GFX_NAV_DOWN)
	ui_test_nav(ctx, GFX_NAV_DOWN)
	assert_equal(1, dropdown_frame(ctx, &selected, &open))
	assert_equal(2, selected)
	ui_test_char(ctx, 13)
	dropdown_frame(ctx, &selected, &open)
	assert_equal(0, open)
	assert_equal(0, ctx.popup_depth)
	assert_equal(1, ctx.focus)
	ui_render_destroy(&fx.r)


void table_frame(ui_context* ctx, ui_table_state* st, int* picked):
	char*[2] headers
	headers[0] = c"Name"
	headers[1] = c"Size"
	int32[2] widths
	widths[0] = 100
	widths[1] = 60
	ui_begin(ctx, 320, 240)
	ui_table_begin(ctx, ui_rect_new(8.0, 8.0, 160.0, 200.0), &headers[0], &widths[0], 2, st)
	for row in range(4):
		if (ui_table_row(ctx, st, row)):
			ui_table_cell(ctx, st, c"file")
			ui_table_cell(ctx, st, c"1k")
	picked[0] = ui_table_end(ctx, st)
	ui_end(ctx)


void test_table_rows_follow_the_arrow_keys():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_table_state st
	ui_table_init(&st)
	int picked = 0
	table_frame(ctx, &st, &picked)
	tab(ctx, 0)
	table_frame(ctx, &st, &picked)
	assert_equal(1, ctx.focus)
	ui_test_nav(ctx, GFX_NAV_DOWN)
	table_frame(ctx, &st, &picked)
	assert_equal(0, picked)
	ui_test_nav(ctx, GFX_NAV_END)
	table_frame(ctx, &st, &picked)
	assert_equal(3, picked)
	ui_test_nav(ctx, GFX_NAV_DOWN)
	table_frame(ctx, &st, &picked)
	assert_equal(0 - 1, picked)
	assert_equal(3, st.selected)
	ui_render_destroy(&fx.r)


void tabs_frame(ui_context* ctx, ui_tab_state* st, int32* active, int* closed):
	ui_begin(ctx, 400, 240)
	ui_tabs_begin(ctx, ui_rect_new(8.0, 8.0, 380.0, 32.0), st, active)
	ui_tab(ctx, st, c"one.w", 1)
	ui_tab(ctx, st, c"two.w", 1)
	closed[0] = ui_tabs_end(ctx, st)
	ui_end(ctx)


void test_tabs_select_and_close_from_the_keyboard():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_tab_state st
	ui_tab_init(&st)
	int32 active = 0
	int closed = 0
	tabs_frame(ctx, &st, &active, &closed)
	tab(ctx, 0)
	tab(ctx, 0)
	tabs_frame(ctx, &st, &active, &closed)
	# Each tab takes two ids (the tab and its close cross).
	assert_equal(3, ctx.focus)
	ui_test_char(ctx, 32)
	tabs_frame(ctx, &st, &active, &closed)
	assert_equal(1, active)
	ui_test_nav(ctx, GFX_NAV_DELETE)
	tabs_frame(ctx, &st, &active, &closed)
	assert_equal(1, closed)
	ui_render_destroy(&fx.r)


# Capture one frame into a fresh snapshot; the caller frees it.
ui_access_tree* captured_frame(ui_context* ctx, form_model* m):
	ui_access_tree* tree = ui_access_tree_new(256, 4096)
	ui_access_capture(ctx, tree)
	form_frame(ctx, m)
	ui_access_capture(ctx, 0)
	return tree


ui_access_node* child_at(ui_access_node* parent, int index):
	ui_access_node* n = parent.first_child
	for i in range(index):
		if (n != 0): n = n.next_sibling
	return n


void test_widgets_describe_themselves():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	form_model m
	form_model_init(&m)
	m.checked = 1
	m.disable_middle = 1
	ui_textbox_set(&m.name, c"Ada")
	ui_access_tree* tree = captured_frame(ctx, &m)
	ui_access_node* root = tree.root
	asserts(c"document root", root != 0)
	assert_equal(UI_ACCESS_DOCUMENT, root.role)
	assert_equal(ui_access_root_id, root.id)

	ui_access_node* title = child_at(root, 0)
	assert_equal(UI_ACCESS_HEADING, title.role)
	assert_equal(1, title.heading_level)
	assert_strings_equal(c"Settings", title.name.data)

	ui_access_node* save = child_at(root, 1)
	assert_equal(1, save.id)
	assert_equal(UI_ACCESS_BUTTON, save.role)
	assert_strings_equal(c"Save", save.name.data)
	asserts(c"button activates", (save.actions & UI_ACCESS_ACTIVATE) != 0)
	asserts(c"button focusable", (save.states & UI_ACCESS_FOCUSABLE) != 0)

	ui_access_node* wrap = ui_access_find(tree, 2)
	assert_equal(UI_ACCESS_CHECKBOX, wrap.role)
	asserts(c"checked", (wrap.states & UI_ACCESS_CHECKED) != 0)
	asserts(c"toggles", (wrap.actions & UI_ACCESS_TOGGLE) != 0)

	ui_access_node* danger = ui_access_find(tree, 3)
	asserts(c"disabled", (danger.states & UI_ACCESS_DISABLED) != 0)
	assert_equal(0, danger.states & UI_ACCESS_FOCUSABLE)

	ui_access_node* name = ui_access_find(tree, 4)
	assert_equal(UI_ACCESS_TEXTBOX, name.role)
	assert_strings_equal(c"Name", name.name.data)
	assert_strings_equal(c"Ada", name.value.data)

	assert_equal(UI_ACCESS_RADIO, ui_access_find(tree, 5).role)
	asserts(c"first radio checked", (ui_access_find(tree, 5).states & UI_ACCESS_CHECKED) != 0)
	assert_equal(0, ui_access_find(tree, 6).states & UI_ACCESS_CHECKED)
	assert_equal(UI_ACCESS_SWITCH, ui_access_find(tree, 7).role)

	ui_access_node* bar = root.last_child
	assert_equal(UI_ACCESS_PROGRESS, bar.role)
	assert_strings_equal(c"50%", bar.value.data)
	assert_equal(0, tree.focused_id)

	# An identical frame captures an identical snapshot; focus changes it.
	ui_access_tree* again = captured_frame(ctx, &m)
	assert_equal(1, ui_access_tree_same(tree, again))
	ui_access_tree_free(again)
	tab(ctx, 0)
	again = captured_frame(ctx, &m)
	assert_equal(0, ui_access_tree_same(tree, again))
	assert_equal(1, again.focused_id)
	ui_access_tree_free(again)
	ui_access_tree_free(tree)
	ui_render_destroy(&fx.r)


void test_assistive_actions_reach_the_widgets():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	form_model m
	form_model_init(&m)
	ui_access_tree* tree = captured_frame(ctx, &m)

	assert_equal(1, ui_access_dispatch(tree, 1, UI_ACCESS_ACTIVATE, 0, 0))
	assert_equal(1, ui_access_dispatch(tree, 2, UI_ACCESS_TOGGLE, 0, 0))
	assert_equal(1, ui_access_dispatch(tree, 4, UI_ACCESS_SET_VALUE, c"Grace", 5))
	# Unsupported actions never reach the widgets.
	assert_equal(0, ui_access_dispatch(tree, 1, UI_ACCESS_SET_VALUE, c"x", 1))
	form_frame(ctx, &m)
	assert_equal(1, m.clicks)
	assert_equal(1, m.checked)
	assert_strings_equal(c"Grace", &m.name.text[0])
	# Requests live for one frame only.
	form_frame(ctx, &m)
	assert_equal(1, m.clicks)

	assert_equal(1, ui_access_dispatch(tree, 7, UI_ACCESS_FOCUS, 0, 0))
	assert_equal(7, ctx.focus)
	assert_equal(1, ctx.focus_visible)
	ui_access_tree_free(tree)

	# A request for a control disabled since publication is refused by
	# the widget itself.
	tree = captured_frame(ctx, &m)
	assert_equal(1, ui_access_dispatch(tree, 3, UI_ACCESS_ACTIVATE, 0, 0))
	m.disable_middle = 1
	form_frame(ctx, &m)
	assert_equal(0, m.disabled_clicks)
	ui_access_tree_free(tree)
	ui_render_destroy(&fx.r)


ui_access_tree* captured_area(ui_context* ctx, ui_textarea_state* ta, int32* clicks):
	ui_access_tree* tree = ui_access_tree_new(64, 4096)
	ui_access_capture(ctx, tree)
	area_frame(ctx, ta, clicks)
	ui_access_capture(ctx, 0)
	return tree


# Text widgets publish their caret and selection in characters, and a
# bridge's SET_SELECTION request moves them on the next frame.
void test_text_caret_and_selection_round_trip():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textarea_state ta
	ui_textarea_init(&ta)
	# "h\xc3\xa9llo\nw": five characters on the first line (one is two
	# bytes), then a newline and a "w".
	ui_textarea_set(&ta, c"h\xc3\xa9llo\nw")
	int32 clicks = 0
	ui_access_tree* tree = captured_area(ctx, &ta, &clicks)
	ui_access_node* area = ui_access_find(tree, 1)
	assert_equal(UI_ACCESS_TEXTBOX, area.role)
	asserts(c"selection action", (area.actions & UI_ACCESS_SET_SELECTION) != 0)
	assert_equal(0, area.caret)
	assert_equal(0, ui_access_has_selection(area))

	# Select "\xc3\xa9ll" backwards: the caret lands on the anchor side.
	assert_equal(1, ui_access_dispatch_selection(tree, 1, 4, 1))
	ui_access_tree_free(tree)
	tree = captured_area(ctx, &ta, &clicks)
	area = ui_access_find(tree, 1)
	assert_equal(1, area.caret)
	assert_equal(1, area.selection_start)
	assert_equal(4, area.selection_end)
	assert_equal(1, ui_textarea_caret_offset(&ta))
	assert_equal(5, ta.sel_anchor)
	asserts(c"widget selection", ui_textarea_has_selection(&ta))

	# A bare caret drops the selection; offsets are characters, so 7 is
	# after the "w" on the second line.
	assert_equal(1, ui_access_dispatch_selection(tree, 1, 7, 7))
	ui_access_tree* again = captured_area(ctx, &ta, &clicks)
	assert_equal(0, ui_access_tree_same(tree, again))
	area = ui_access_find(again, 1)
	assert_equal(7, area.caret)
	assert_equal(0, ui_access_has_selection(area))
	assert_equal(1, ta.caret_line)
	assert_equal(1, ta.caret_col)
	asserts(c"no widget selection", ui_textarea_has_selection(&ta) == 0)
	# Offsets past the text clamp to its end.
	assert_equal(1, ui_access_dispatch_selection(again, 1, 0, 99))
	area_frame(ctx, &ta, &clicks)
	assert_equal(0, ta.sel_anchor)
	assert_equal(8, ui_textarea_caret_offset(&ta))
	ui_access_tree_free(again)
	ui_access_tree_free(tree)

	# The single-line textbox has a caret only: a range request moves
	# the caret to its active end.
	form_model m
	form_model_init(&m)
	ui_textbox_set(&m.name, c"Ad\xc3\xa1")
	tree = captured_frame(ctx, &m)
	ui_access_node* name = ui_access_find(tree, 4)
	assert_equal(3, name.caret)
	assert_equal(3, name.selection_start)
	assert_equal(3, name.selection_end)
	assert_equal(1, ui_access_dispatch_selection(tree, 4, 0, 1))
	form_frame(ctx, &m)
	assert_equal(1, m.name.caret)
	ui_access_tree_free(tree)
	ui_textarea_free(&ta)
	ui_render_destroy(&fx.r)


# The text fields publish a box per character from the layout they draw
# and the attributes they draw in (#863).
void test_text_fields_publish_glyphs_and_attributes():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textarea_state ta
	ui_textarea_init(&ta)
	ui_textarea_set(&ta, c"h\xc3\xa9llo\nw")
	int32 clicks = 0
	ui_access_tree* tree = captured_area(ctx, &ta, &clicks)
	ui_access_node* area = ui_access_find(tree, 1)
	assert_equal(7, area.char_box_count)
	asserts(c"glyph geometry", ui_access_has_glyphs(area))
	ui_rect* b = area.char_boxes
	float32 pad = cast(float32, ctx.theme.pad)
	asserts(c"first glyph at the padded edge", b[0].x == 8.0 + pad)
	asserts(c"first glyph on the first line", b[0].y == 8.0 + pad)
	asserts(c"glyphs have width", b[0].w > 0.0)
	for k in range(1, 5): asserts(c"glyphs follow each other", b[k].x == b[k - 1].x + b[k - 1].w)
	asserts(c"newline: zero width at the line end", (b[5].w == 0.0) && (b[5].x == b[4].x + b[4].w))
	float32 line_h = cast(float32, ui_textarea_line_height(ctx))
	asserts(c"second line", (b[6].x == b[0].x) && (b[6].y == b[0].y + line_h))
	assert_equal(2, ui_access_offset_at_point(area, b[2].x + 1.0, b[2].y + 1.0))
	assert_equal(6, ui_access_offset_at_point(area, b[6].x + 1.0, b[6].y + 1.0))
	ui_access_text_attrs* a = area.attrs
	asserts(c"attributes", a != 0)
	assert_bytes_equal(c"Liberation Sans", a.family.data, 15)
	assert_equal(12, a.size)
	assert_equal(400, a.weight)
	assert_equal(0, a.italic)
	assert_equal(ui_access_rgb(ctx.theme.text.r, ctx.theme.text.g, ctx.theme.text.b), a.fg)
	assert_equal(ui_access_rgb(ctx.theme.widget.r, ctx.theme.widget.g, ctx.theme.widget.b), a.bg)
	ui_access_tree_free(tree)

	# The single-line field: its characters, vertically centred.
	form_model m
	form_model_init(&m)
	ui_textbox_set(&m.name, c"Ad\xc3\xa1")
	tree = captured_frame(ctx, &m)
	ui_access_node* name = ui_access_find(tree, 4)
	assert_equal(3, name.char_box_count)
	ui_rect* nb = name.char_boxes
	asserts(c"field glyphs inside the field", (nb[0].x == name.bounds.x + pad) && (nb[0].y > name.bounds.y) && (nb[0].y + nb[0].h < name.bounds.y + name.bounds.h))
	asserts(c"field glyphs follow each other", (nb[1].x == nb[0].x + nb[0].w) && (nb[2].x == nb[1].x + nb[1].w))
	asserts(c"field attributes", (name.attrs != 0) && (name.attrs.weight == 400))
	ui_access_tree_free(tree)
	ui_textarea_free(&ta)
	ui_render_destroy(&fx.r)


# The multi-selection list box (#913): five fruit, ids 1 (the list) and
# 2..6 (the items), 32-pixel rows from y = 9.
struct fruit_model:
	ui_listbox_state st
	char[5] picked
	int32 changes
	int32 disabled


void fruit_init(fruit_model* m):
	ui_listbox_init(&m.st)
	for i in range(5): m.picked[i] = 0
	m.changes = 0
	m.disabled = 0


void fruit_frame(ui_context* ctx, fruit_model* m):
	char*[5] names
	names[0] = c"Apple"
	names[1] = c"Banana"
	names[2] = c"Cherry"
	names[3] = c"Date"
	names[4] = c"Elder"
	ui_begin(ctx, 320, 240)
	ui_disable(ctx, m.disabled)
	ui_listbox_begin(ctx, ui_rect_new(8.0, 8.0, 160.0, 200.0), &m.st, c"Fruit", &m.picked[0], 5)
	for i in range(5): ui_listbox_item(ctx, &m.st, i, names[i])
	if (ui_listbox_end(ctx, &m.st)): m.changes = m.changes + 1
	ui_disable(ctx, 0)
	ui_end(ctx)


void fruit_click(ui_context* ctx, fruit_model* m, int index, int mods):
	int y = 9 + 32 * index + 16
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, 40, y, mods)
	ui_test_event(ctx, GFX_EVENT_MOUSE_UP, 1, 40, y, mods)
	fruit_frame(ctx, m)


# The picked flags as a five-character string of 0s and 1s.
char* fruit_marks(fruit_model* m):
	char* s = cast(char*, malloc(6))
	for i in range(5): s[i] = '0' + m.picked[i]
	s[5] = 0
	return s


void assert_marks(char* expected, fruit_model* m):
	char* got = fruit_marks(m)
	assert_strings_equal(expected, got)
	free(got)


void test_listbox_pointer_selection():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	fruit_model m
	fruit_init(&m)
	fruit_frame(ctx, &m)
	fruit_click(ctx, &m, 1, 0)
	assert_marks(c"01000", &m)
	assert_equal(1, ctx.focus)
	assert_equal(1, m.changes)
	# Ctrl+click toggles one item in and out; Super does the same (Mac).
	fruit_click(ctx, &m, 3, GFX_MOD_CTRL)
	assert_marks(c"01010", &m)
	fruit_click(ctx, &m, 1, GFX_MOD_SUPER)
	assert_marks(c"00010", &m)
	# Shift+click selects the range from the anchor (the last click,
	# Banana) and only that range; the anchor stays.
	fruit_click(ctx, &m, 0, GFX_MOD_SHIFT)
	assert_marks(c"11000", &m)
	fruit_click(ctx, &m, 3, GFX_MOD_SHIFT)
	assert_marks(c"01110", &m)
	# A plain click selects one item again; Ctrl+Shift adds a range.
	fruit_click(ctx, &m, 4, 0)
	assert_marks(c"00001", &m)
	fruit_click(ctx, &m, 0, GFX_MOD_CTRL)
	fruit_click(ctx, &m, 1, GFX_MOD_CTRL | GFX_MOD_SHIFT)
	assert_marks(c"11001", &m)
	# A frame without input changes nothing.
	int before = m.changes
	fruit_frame(ctx, &m)
	assert_equal(before, m.changes)
	ui_render_destroy(&fx.r)


void test_listbox_keyboard_selection():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	fruit_model m
	fruit_init(&m)
	fruit_frame(ctx, &m)
	tab(ctx, 0)
	fruit_frame(ctx, &m)
	assert_equal(1, ctx.focus)
	assert_marks(c"00000", &m)
	ui_test_nav(ctx, GFX_NAV_DOWN)
	fruit_frame(ctx, &m)
	assert_equal(0, m.st.cursor)
	assert_marks(c"10000", &m)
	ui_test_nav(ctx, GFX_NAV_DOWN)
	fruit_frame(ctx, &m)
	assert_marks(c"01000", &m)
	# Shift+arrows grow and shrink the range from the anchor.
	ui_test_key(ctx, GFX_NAV_DOWN, GFX_MOD_SHIFT)
	ui_test_key(ctx, GFX_NAV_DOWN, GFX_MOD_SHIFT)
	fruit_frame(ctx, &m)
	assert_marks(c"01110", &m)
	assert_equal(3, m.st.cursor)
	ui_test_key(ctx, GFX_NAV_UP, GFX_MOD_SHIFT)
	fruit_frame(ctx, &m)
	assert_marks(c"01100", &m)
	ui_test_key(ctx, GFX_NAV_HOME, GFX_MOD_SHIFT)
	fruit_frame(ctx, &m)
	assert_marks(c"11000", &m)
	# Ctrl+arrows move the cursor alone; Space toggles its item.
	ui_test_key(ctx, GFX_NAV_END, GFX_MOD_CTRL)
	fruit_frame(ctx, &m)
	assert_equal(4, m.st.cursor)
	assert_marks(c"11000", &m)
	ui_test_char(ctx, 32)
	fruit_frame(ctx, &m)
	assert_marks(c"11001", &m)
	ui_test_char(ctx, 32)
	fruit_frame(ctx, &m)
	assert_marks(c"11000", &m)
	# Ctrl+A selects every item, as the letter or as its control code.
	ui_test_event(ctx, GFX_EVENT_CHAR, 'a', 0, 0, GFX_MOD_CTRL)
	fruit_frame(ctx, &m)
	assert_marks(c"11111", &m)
	ui_test_nav(ctx, GFX_NAV_UP)
	fruit_frame(ctx, &m)
	assert_marks(c"00010", &m)
	ui_test_event(ctx, GFX_EVENT_CHAR, 1, 0, 0, GFX_MOD_CTRL)
	fruit_frame(ctx, &m)
	assert_marks(c"11111", &m)
	# Without focus the list ignores the keyboard.
	ctx.focus = 0
	ui_test_nav(ctx, GFX_NAV_DOWN)
	fruit_frame(ctx, &m)
	assert_marks(c"11111", &m)
	ui_render_destroy(&fx.r)


ui_access_tree* captured_fruit(ui_context* ctx, fruit_model* m):
	ui_access_tree* tree = ui_access_tree_new(64, 4096)
	ui_access_capture(ctx, tree)
	fruit_frame(ctx, m)
	ui_access_capture(ctx, 0)
	return tree


void test_listbox_publishes_and_takes_the_selection():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	fruit_model m
	fruit_init(&m)
	m.picked[1] = 1
	m.picked[3] = 1
	ui_access_tree* tree = captured_fruit(ctx, &m)
	ui_access_node* list = ui_access_find(tree, 1)
	assert_equal(UI_ACCESS_LIST, list.role)
	assert_strings_equal(c"Fruit", list.name.data)
	asserts(c"multiselectable", (list.states & UI_ACCESS_MULTISELECTABLE) != 0)
	asserts(c"focusable", (list.states & UI_ACCESS_FOCUSABLE) != 0)
	assert_equal(1, ui_access_is_multiselectable(list))
	assert_equal(2, ui_access_selected_count(list))
	assert_strings_equal(c"Banana", ui_access_selected_at(list, 0).name.data)
	assert_strings_equal(c"Date", ui_access_selected_at(list, 1).name.data)
	ui_access_node* cherry = ui_access_find(tree, 4)
	assert_equal(UI_ACCESS_LIST_ITEM, cherry.role)
	assert_strings_equal(c"Cherry", cherry.name.data)
	asserts(c"items select", (cherry.actions & UI_ACCESS_SELECT) != 0)

	# Add, remove and select-only requests reach the flags next frame.
	assert_equal(1, ui_access_dispatch_select(tree, 4, UI_ACCESS_SELECT_ADD))
	assert_equal(1, ui_access_dispatch_select(tree, 3, UI_ACCESS_SELECT_REMOVE))
	fruit_frame(ctx, &m)
	assert_marks(c"00110", &m)
	assert_equal(1, ui_access_dispatch_select(tree, 6, UI_ACCESS_SELECT_ONLY))
	fruit_frame(ctx, &m)
	assert_marks(c"00001", &m)
	# Requests live for one frame; activation selects one item.
	fruit_frame(ctx, &m)
	assert_marks(c"00001", &m)
	assert_equal(1, ui_access_dispatch(tree, 2, UI_ACCESS_ACTIVATE, 0, 0))
	fruit_frame(ctx, &m)
	assert_marks(c"10000", &m)
	ui_access_tree_free(tree)

	# A focus request on an item focuses the list with its cursor there,
	# and the snapshot then reports that item as focused.
	tree = captured_fruit(ctx, &m)
	assert_equal(1, ui_access_dispatch(tree, 5, UI_ACCESS_FOCUS, 0, 0))
	ui_access_tree_free(tree)
	tree = captured_fruit(ctx, &m)
	assert_equal(1, ctx.focus)
	assert_equal(3, m.st.cursor)
	assert_equal(5, tree.focused_id)
	ui_access_tree_free(tree)
	# Focus moves the cursor, not the anchor (Apple, activated last), as
	# Ctrl+arrows do: Shift+Down then selects Apple through Elder.
	ui_test_key(ctx, GFX_NAV_DOWN, GFX_MOD_SHIFT)
	tree = captured_fruit(ctx, &m)
	assert_marks(c"11111", &m)
	assert_equal(6, tree.focused_id)
	assert_equal(5, ui_access_selected_count(ui_access_find(tree, 1)))
	ui_test_char(ctx, 32)
	fruit_frame(ctx, &m)
	assert_marks(c"11110", &m)
	# A frame applies its arrows before its characters.
	ui_test_key(ctx, GFX_NAV_UP, GFX_MOD_CTRL)
	ui_test_char(ctx, 32)
	fruit_frame(ctx, &m)
	assert_marks(c"11100", &m)
	ui_test_key(ctx, GFX_NAV_UP, GFX_MOD_CTRL)
	ui_test_key(ctx, GFX_NAV_UP, GFX_MOD_CTRL)
	ui_test_char(ctx, 32)
	fruit_frame(ctx, &m)
	assert_marks(c"10100", &m)

	ui_access_tree_free(tree)

	# A list disabled since publication refuses them in the widget.
	tree = captured_fruit(ctx, &m)
	assert_equal(1, ui_access_dispatch_select(tree, 2, UI_ACCESS_SELECT_REMOVE))
	m.disabled = 1
	fruit_frame(ctx, &m)
	assert_marks(c"10100", &m)
	ui_access_tree_free(tree)
	# and, published disabled, the dispatcher refuses them outright.
	tree = captured_fruit(ctx, &m)
	assert_equal(0, ui_access_dispatch_select(tree, 2, UI_ACCESS_SELECT_REMOVE))
	ui_access_tree_free(tree)
	ui_render_destroy(&fx.r)


# A grid (#913): a header spanning two columns, a row-header column and
# cells spanning rows and columns, as tools/access_depth_app.w builds by
# hand.
void grid_frame(ui_context* ctx, ui_table_state* st, int* picked):
	char*[3] headers
	headers[0] = c"Kind"
	headers[1] = c"Item"
	headers[2] = c""
	int32[3] spans
	spans[0] = 1
	spans[1] = 2
	spans[2] = 1
	int32[3] widths
	widths[0] = 80
	widths[1] = 80
	widths[2] = 60
	st.row_header_col = 0
	st.header_spans = &spans[0]
	ui_begin(ctx, 320, 240)
	ui_table_begin(ctx, ui_rect_new(8.0, 8.0, 240.0, 200.0), &headers[0], &widths[0], 3, st)
	if (ui_table_row(ctx, st, 0)):
		ui_table_cell_span(ctx, st, c"Fruit", 2, 1)
		ui_table_cell(ctx, st, c"Apple")
		ui_table_cell(ctx, st, c"Red")
	if (ui_table_row(ctx, st, 1)):
		ui_table_cell_span(ctx, st, c"Cherry", 1, 2)
	if (ui_table_row(ctx, st, 2)):
		ui_table_cell(ctx, st, c"Nut")
		ui_table_cell(ctx, st, c"Pecan")
		ui_table_cell(ctx, st, c"Brown")
	picked[0] = ui_table_end(ctx, st)
	ui_end(ctx)


void test_table_publishes_headers_and_spans():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_table_state st
	ui_table_init(&st)
	int picked = 0
	ui_access_tree* tree = ui_access_tree_new(64, 4096)
	ui_access_capture(ctx, tree)
	grid_frame(ctx, &st, &picked)
	ui_access_capture(ctx, 0)
	ui_access_node* table = ui_access_find(tree, 1)
	assert_equal(UI_ACCESS_TABLE, table.role)
	ui_access_node* header = ui_access_header_row(table)
	asserts(c"explicit header row", (header != 0) && ((header.states & UI_ACCESS_HEADER) != 0))
	assert_equal(2, ui_access_row_cells(header))
	ui_access_node* item = ui_access_row_cell(header, 1)
	assert_strings_equal(c"Item", item.name.data)
	assert_equal(2, item.col_span)
	assert_equal(3, ui_access_table_rows(table))
	assert_equal(3, ui_access_table_columns(table))

	# The row header spans two rows; Cherry fills the two columns it
	# leaves free in the second row.
	ui_access_node* fruit = ui_access_table_cell_at(table, 0, 0)
	assert_strings_equal(c"Fruit", fruit.name.data)
	asserts(c"row header", (fruit.states & UI_ACCESS_HEADER) != 0)
	assert_equal(2, fruit.row_span)
	assert_equal(1, ui_access_is_row_header(fruit))
	asserts(c"spans down", ui_access_table_cell_at(table, 1, 0) == fruit)
	ui_access_node* cherry = ui_access_table_cell_at(table, 1, 2)
	assert_strings_equal(c"Cherry", cherry.name.data)
	assert_equal(2, cherry.col_span)
	int row = 0
	int col = 0
	int rs = 0
	int cs = 0
	ui_access_cell_slot(cherry, &row, &col, &rs, &cs)
	assert_equal(1, row)
	assert_equal(1, col)
	ui_access_node* found = 0
	assert_equal(1, ui_access_row_headers_of(cherry, 0, &found))
	asserts(c"Cherry's row header", found == fruit)
	assert_equal(1, ui_access_column_headers_of(cherry, 0, &found))
	asserts(c"Cherry's column header", found == item)
	ui_access_node* nut = ui_access_table_cell_at(table, 2, 0)
	assert_strings_equal(c"Nut", nut.name.data)
	asserts(c"each row's first cell heads it", (nut.states & UI_ACCESS_HEADER) != 0)
	assert_equal(0, ui_access_table_cell_at(table, 2, 1).states & UI_ACCESS_HEADER)

	# Drawn where the snapshot says: Cherry right of the spanning row
	# header, two rows tall and two columns wide respectively.
	assert_equal(cast(int, fruit.bounds.x + 80.0), cast(int, cherry.bounds.x))
	assert_equal(cast(int, fruit.bounds.h), cast(int, cherry.bounds.h * 2.0))
	assert_equal(140, cast(int, cherry.bounds.w))
	ui_access_tree_free(tree)

	# A focused table reports its selected row as the focused node.
	tab(ctx, 0)
	ui_test_nav(ctx, GFX_NAV_DOWN)
	grid_frame(ctx, &st, &picked)
	assert_equal(0, picked)
	tree = ui_access_tree_new(64, 4096)
	ui_access_capture(ctx, tree)
	grid_frame(ctx, &st, &picked)
	ui_access_capture(ctx, 0)
	ui_access_node* first = ui_access_table_row(ui_access_find(tree, 1), 0)
	assert_equal(first.id, tree.focused_id)
	ui_access_tree_free(tree)
	ui_render_destroy(&fx.r)


# Rows that a span from above still covers stay in the issue window
# when the spanning row scrolls out, so their cells keep their columns.
void test_table_spans_survive_scrolling():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_table_state st
	ui_table_init(&st)
	int picked = 0
	grid_frame(ctx, &st, &picked)
	# One row's height down: row 0 (with Fruit's span) is off screen.
	st.scroll.view_h = 64.0
	st.scroll.offset_y = 40.0
	ui_access_tree* tree = ui_access_tree_new(64, 4096)
	ui_access_capture(ctx, tree)
	grid_frame(ctx, &st, &picked)
	ui_access_capture(ctx, 0)
	ui_access_node* table = ui_access_find(tree, 1)
	ui_access_node* cherry = ui_access_table_cell_at(table, 1, 1)
	asserts(c"Cherry keeps its column", (cherry != 0) && (strcmp(cherry.name.data, c"Cherry") == 0))
	ui_access_tree_free(tree)
	ui_render_destroy(&fx.r)
