# Platform accessibility bridge for this target: Windows UI Automation
# (Narrator, NVDA, JAWS) through COM providers written in W. Same five
# calls as every target (graphics/__arch__/*/access_platform.w).
import graphics.ui.accessibility_uia
import graphics.window

char* ui_access_platform_name():
	return c"UI Automation"

# Installs the window's WM_GETOBJECT hook so UIA clients find the tree.
int ui_access_platform_open(gfx_window* win, char* app_name):
	if (win == 0): return 0
	ui_uia_bridge* b = ui_access_uia_open(win.hwnd)
	if (b != 0): gfx_win32_getobject = ui_access_uia_wm_getobject
	return cast(int, b)

# The bridge maps client to screen coordinates through the window itself;
# it only needs the DPI scale between snapshot and device pixels.
void ui_access_platform_origin(int bridge, gfx_window* win):
	if ((bridge == 0) || (win == 0)): return
	ui_access_uia_set_scale(cast(ui_uia_bridge*, bridge), gfx_window_pixel_ratio(win))

int ui_access_platform_publish(int bridge, ui_access_tree* tree):
	if (bridge == 0): return 0
	return ui_access_uia_publish(cast(ui_uia_bridge*, bridge), tree)

int ui_access_platform_dispatch(int bridge, ui_access_tree* tree):
	if (bridge == 0): return 0
	return ui_access_uia_dispatch(cast(ui_uia_bridge*, bridge), tree)

void ui_access_platform_close(int bridge):
	if (bridge == 0): return
	gfx_win32_getobject = 0
	ui_access_uia_close(cast(ui_uia_bridge*, bridge))
