# Platform accessibility bridge for this target: the browser ARIA mirror
# (tools/web hosts). Same five calls as every target
# (graphics/__arch__/*/access_platform.w). The mirror is per page, so the
# handle is a constant 1 once a host accepted the first publication.
import graphics.ui.accessibility_web
import graphics.window

char* ui_access_platform_name():
	return c"ARIA"

int ui_access_platform_open(gfx_window* win, char* app_name):
	return 1

void ui_access_platform_origin(int bridge, gfx_window* win):
	return

int ui_access_platform_publish(int bridge, ui_access_tree* tree):
	if (bridge == 0): return 0
	return ui_access_web_publish(tree)

int ui_access_platform_dispatch(int bridge, ui_access_tree* tree):
	if (bridge == 0): return 0
	return ui_access_web_dispatch(tree)

void ui_access_platform_close(int bridge):
	if (bridge != 0): gfx_access_close()
