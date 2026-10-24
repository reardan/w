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
