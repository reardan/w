/*
graphics.ui.rect: the axis-aligned rectangle primitive for the UI
layer (docs/projects/ui_framework.md §4). Pixel-space, y-down (the
same orientation as the gfx_window mouse coordinates), by-value like
graphics.math's vec2/mat4.
*/


struct ui_rect:
	float32 x
	float32 y
	float32 w
	float32 h


ui_rect ui_rect_new(float32 x, float32 y, float32 w, float32 h):
	ui_rect r
	r.x = x
	r.y = y
	r.w = w
	r.h = h
	return r


# 1 when the point lies inside the rect; the right/bottom edges are
# exclusive so adjacent rects do not both claim a shared edge.
int ui_rect_contains(ui_rect r, float32 px, float32 py):
	if ((px < r.x) || (py < r.y)):
		return 0
	if ((px >= r.x + r.w) || (py >= r.y + r.h)):
		return 0
	return 1


ui_rect ui_rect_inset(ui_rect r, float32 d):
	return ui_rect_new(r.x + d, r.y + d, r.w - d * 2.0, r.h - d * 2.0)
