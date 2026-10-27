# wbuild: name=graphics_ui_accessibility_web_test
# W -> browser DOM -> action queue -> W callback regression, including UTF-8.
# The host runner also checks absent optional-host behavior and wasm ABI bounds.
import lib.lib
import lib.assert
import graphics.ui.accessibility_web

ui_access_tree* web_test_tree
int web_test_calls
int web_test_selection_seen

int web_test_action(void* context, int id, int action, char* data, int length):
	asserts(c"callback context", context == cast(void*, web_test_tree))
	if (action == UI_ACCESS_ACTIVATE): assert_equal(2, id)
	if (action == UI_ACCESS_FOCUS): assert_equal(3, id)
	if (action == UI_ACCESS_SET_VALUE):
		assert_equal(3, id)
		assert_equal(8, length)
		char* expected = c"文\0🙂"
		for i in range(length): assert_equal(cast(int, expected[i]), cast(int, data[i]))
	if (action == UI_ACCESS_SET_SELECTION):
		assert_equal(3, id)
		int anchor = 0
		int active = 0
		assert_equal(1, ui_access_selection_parse(data, length, &anchor, &active))
		web_test_selection_seen = anchor * 100 + active
	web_test_calls = web_test_calls + 1
	return 1

export int web_test_dispatch():
	return ui_access_web_dispatch(web_test_tree)

export int web_test_call_count():
	return web_test_calls

# The last selection request as anchor * 100 + active.
export int web_test_selection():
	return web_test_selection_seen

export int web_test_focus():
	return web_test_tree.focused_id

export int web_test_publish():
	return ui_access_web_publish(web_test_tree)

export void web_test_disable():
	ui_access_find(web_test_tree, 2).states = UI_ACCESS_DISABLED

export int web_test_other_snapshot():
	ui_access_tree* other = ui_access_tree_new(1, 128)
	int result = ui_access_web_dispatch(other)
	ui_access_tree_free(other)
	return result

# The status line changes and an assertive announcement rides along.
export int web_test_saved():
	ui_access_set_text(web_test_tree, 4, UI_ACCESS_NAME, c"Saved.", 6)
	ui_access_announce(web_test_tree, c"Exported", 8, UI_ACCESS_LIVE_ASSERTIVE)
	return ui_access_web_publish(web_test_tree)

export int web_test_announcement_length():
	return web_test_tree.announcement.length

export void web_test_close():
	gfx_access_close()
	ui_access_tree_free(web_test_tree)
	web_test_tree = 0

int main():
	web_test_tree = ui_access_tree_new(8, 160)
	web_test_tree.action = web_test_action
	web_test_tree.context = cast(void*, web_test_tree)
	ui_access_add(web_test_tree, 1, 0, UI_ACCESS_DOCUMENT, ui_rect_new(0.0, 0.0, 320.0, 200.0))
	ui_access_node* button = ui_access_add(web_test_tree, 2, 1, UI_ACCESS_BUTTON, ui_rect_new(10.0, 10.0, 80.0, 30.0))
	button.states = UI_ACCESS_FOCUSABLE
	button.actions = UI_ACCESS_ACTIVATE | UI_ACCESS_FOCUS
	assert_equal(1, ui_access_set_text(web_test_tree, 2, UI_ACCESS_NAME, c"Open <日本>", 13))
	ui_access_node* textbox = ui_access_add(web_test_tree, 3, 1, UI_ACCESS_TEXTBOX, ui_rect_new(10.0, 50.0, 180.0, 30.0))
	textbox.states = UI_ACCESS_FOCUSABLE
	textbox.actions = UI_ACCESS_SET_VALUE | UI_ACCESS_SET_SELECTION | UI_ACCESS_FOCUS
	assert_equal(1, ui_access_set_text(web_test_tree, 3, UI_ACCESS_NAME, c"Query", 5))
	assert_equal(1, ui_access_set_text(web_test_tree, 3, UI_ACCESS_VALUE, c"a\0é", 4))
	ui_access_node* status = ui_access_add(web_test_tree, 4, 1, UI_ACCESS_TEXT, ui_rect_new(10.0, 90.0, 180.0, 20.0))
	status.live = UI_ACCESS_LIVE_POLITE
	assert_equal(1, ui_access_set_text(web_test_tree, 4, UI_ACCESS_NAME, c"Ready.", 6))
	assert_equal(1, ui_access_set_selection(web_test_tree, 3, 3, 3))
	assert_equal(1, ui_access_web_publish(web_test_tree))
	return 0

# wbuild: target=graphics_ui_accessibility_web_test tag=tests_wasm dep=wv2 dep=wrun input=tools/web/headless_chromium.mjs
# wbuild: step="bin/wv2 wasm graphics/ui/accessibility_web_test.w -o bin/graphics_ui_accessibility_web_test.wasm"
# wbuild: step="bin/wrun node tools/web/accessibility_test.mjs" expect_stdout="web accessibility DOM/ABI contracts OK"
# wbuild: step="bin/wrun node tools/web/run_accessibility_test.mjs bin/graphics_ui_accessibility_web_test.wasm" expect_stdout="web accessibility W/DOM round trip OK"
# Real headless Chromium: DOM identity, selection, IME composition and live regions in its accessibility tree.
# wbuild: step="bin/wrun node tools/web/run_accessibility_chromium.mjs" expect_stdout="web accessibility Chromium"
