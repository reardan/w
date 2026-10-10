# wbuild: name=graphics_ui_accessibility_darwin arch_only=arm64_darwin
# Cross-compiled in Linux CI; execute on macOS after build_accessibility.sh.
import lib.lib
import lib.assert
import lib.ci_skip
import graphics.window
import graphics.cocoa
import graphics.ui.accessibility_cocoa

int main():
	gfx_window* win = gfx_window_open(c"Accessibility bridge smoke", 300, 200)
	if (win == 0):
		test_skip(c"accessibility SKIP: no Cocoa GUI session")
		return 0
	int view = objc_msg0(win.window, sel_registerName(c"contentView"))
	int bridge = w_access_open(view, 128)
	asserts(c"native bridge", bridge != 0)
	ui_access_tree* tree = ui_access_tree_new(4, 128)
	ui_rect bounds = ui_rect_new(0.0, 0.0, 300.0, 200.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, bounds)
	ui_access_node* button = ui_access_add(tree, 2, 1, UI_ACCESS_BUTTON, ui_rect_new(10.0, 10.0, 80.0, 32.0))
	button.states = UI_ACCESS_FOCUSABLE
	button.actions = UI_ACCESS_ACTIVATE | UI_ACCESS_FOCUS
	ui_access_set_text(tree, 2, UI_ACCESS_NAME, c"Open", 4)
	tree.focused_id = 2
	assert_equal(1, ui_access_cocoa_publish(bridge, tree))
	int roots = objc_msg0(view, sel_registerName(c"accessibilityChildren"))
	assert_equal(1, objc_msg0(roots, sel_registerName(c"count")))
	int root = objc_msg1(roots, sel_registerName(c"objectAtIndex:"), 0)
	int children = objc_msg0(root, sel_registerName(c"accessibilityChildren"))
	int native_button = objc_msg1(children, sel_registerName(c"objectAtIndex:"), 0)
	assert_equal(1, objc_msg0(native_button, sel_registerName(c"accessibilityPerformPress")) & 255)
	int[3] event
	assert_equal(1, w_access_next(bridge, &event[0], 0, 0))
	assert_equal(2, event[0])
	assert_equal(UI_ACCESS_ACTIVATE, event[1])
	w_access_close(bridge)
	ui_access_tree_free(tree)
	gfx_window_destroy(win)
	println(c"Cocoa accessibility OK")
	return 0
