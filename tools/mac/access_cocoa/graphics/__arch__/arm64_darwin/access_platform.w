# Opt-in macOS NSAccessibility bridge (VoiceOver). Selected by
#   bin/wv2 arm64_darwin --import-root tools/mac/access_cocoa APP.w -o APP
# in place of graphics/__arch__/arm64_darwin/access_platform.w. Ship
# libwaccessibility.dylib (tools/mac/build_accessibility.sh) beside APP:
# without it the executable does not start.
import graphics.cocoa
import graphics.ui.accessibility_cocoa
import graphics.window

char* ui_access_platform_name():
	return c"NSAccessibility"

# The GL window's content view hosts the NSAccessibilityElement tree.
int ui_access_platform_open(gfx_window* win, char* app_name):
	if (win == 0): return 0
	int view = objc_msg0(win.window, sel_registerName(c"contentView"))
	return w_access_open(view, 1048576)

# Geometry is relative to the content view; AppKit converts it at query time.
void ui_access_platform_origin(int bridge, gfx_window* win):
	return

int ui_access_platform_publish(int bridge, ui_access_tree* tree):
	if (bridge == 0): return 0
	return ui_access_cocoa_publish(bridge, tree)

int ui_access_platform_dispatch(int bridge, ui_access_tree* tree):
	if (bridge == 0): return 0
	return ui_access_cocoa_dispatch(bridge, tree)

void ui_access_platform_close(int bridge):
	if (bridge != 0): w_access_close(bridge)
