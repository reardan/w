# Platform accessibility bridge for this target: Linux AT-SPI 2 (Orca) over
# the pure-W D-Bus client. The same five calls exist on every target
# (graphics/__arch__/*/access_platform.w); a zero handle means no assistive
# technology bus, and every call then does nothing.
import graphics.ui.accessibility_atspi
import graphics.window

c_lib "libX11.so.6"
extern int XTranslateCoordinates(int display, int source, int destination, int x, int y, int32* ox, int32* oy, int* child)

char* ui_access_platform_name():
	return c"AT-SPI"

int ui_access_platform_open(gfx_window* win, char* app_name):
	return cast(int, ui_access_atspi_open(app_name))

# Screen position of the window's client area, for screen-coordinate
# geometry queries. Cheap enough to call every frame.
void ui_access_platform_origin(int bridge, gfx_window* win):
	if (bridge == 0 || win == 0): return
	int32 x = 0
	int32 y = 0
	int child = 0
	if (XTranslateCoordinates(win.display, win.window, XRootWindow(win.display, XDefaultScreen(win.display)), 0, 0, &x, &y, &child)): ui_access_atspi_set_origin(cast(ui_atspi_bridge*, bridge), cast(int, x), cast(int, y))

int ui_access_platform_publish(int bridge, ui_access_tree* tree):
	if (bridge == 0): return 0
	return ui_access_atspi_publish(cast(ui_atspi_bridge*, bridge), tree)

# -1 once the bus is gone; callers then close the bridge and carry on.
int ui_access_platform_dispatch(int bridge, ui_access_tree* tree):
	if (bridge == 0): return 0
	return ui_access_atspi_dispatch(cast(ui_atspi_bridge*, bridge), tree)

void ui_access_platform_close(int bridge):
	if (bridge != 0): ui_access_atspi_close(cast(ui_atspi_bridge*, bridge))
