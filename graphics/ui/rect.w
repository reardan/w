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


# 1 when the rect covers no pixels. A zero or negative extent on either
# axis is empty; ui_rect_intersect returns such a rect for disjoint
# inputs rather than a negative-size one.
int ui_rect_is_empty(ui_rect r):
	if ((r.w <= 0.0) || (r.h <= 0.0)):
		return 1
	return 0


# The overlap of two rects, or a zero-size rect at a's origin when they
# do not overlap (never a negative extent — callers test with
# ui_rect_is_empty). The clip stack composes with this.
ui_rect ui_rect_intersect(ui_rect a, ui_rect b):
	float32 x0 = a.x
	if (b.x > x0):
		x0 = b.x
	float32 y0 = a.y
	if (b.y > y0):
		y0 = b.y
	float32 x1 = a.x + a.w
	if (b.x + b.w < x1):
		x1 = b.x + b.w
	float32 y1 = a.y + a.h
	if (b.y + b.h < y1):
		y1 = b.y + b.h
	if ((x1 <= x0) || (y1 <= y0)):
		return ui_rect_new(x0, y0, 0.0, 0.0)
	return ui_rect_new(x0, y0, x1 - x0, y1 - y0)
