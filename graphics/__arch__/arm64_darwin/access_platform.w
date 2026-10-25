# Platform accessibility bridge for this target. The macOS NSAccessibility
# bridge (graphics.ui.accessibility_cocoa) needs the companion
# libwaccessibility.dylib beside the executable, and importing it makes a
# missing companion a dyld startup error. So the default macOS build has no
# bridge (open returns 0); tools/mac/access_cocoa/ holds the opt-in
# replacement of this file, selected with
#   bin/wv2 arm64_darwin --import-root tools/mac/access_cocoa APP.w -o APP
# (docs/projects/mermaid_desktop_qualification.md). Same five calls as
# every target (graphics/__arch__/*/access_platform.w).
import graphics.ui.accessibility
import graphics.window

char* ui_access_platform_name():
	return c"none"

int ui_access_platform_open(gfx_window* win, char* app_name):
	return 0

void ui_access_platform_origin(int bridge, gfx_window* win):
	return

int ui_access_platform_publish(int bridge, ui_access_tree* tree):
	return 0

int ui_access_platform_dispatch(int bridge, ui_access_tree* tree):
	return 0

void ui_access_platform_close(int bridge):
	return
