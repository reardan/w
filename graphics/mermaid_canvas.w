# Canvas-only selection adorners; never enter source or SVG output.
import graphics.mermaid
import libs.extras.mermaid.canvas
import graphics.ui.widgets.textarea

void mm_canvas_render(ui_renderer* r, mm_canvas* c, mm_editor* e, ui_rect viewport, int focused):
	mm_ui_render(r, e.scene, viewport, c.zoom, c.pan_x, c.pan_y)
	ui_clip_push(r, viewport)
	ui_color accent = mm_ui_color(0x2563eb)
	if (focused): mm_ui_outline(r, ui_rect_new(viewport.x + 1.0, viewport.y + 1.0, viewport.w - 2.0, viewport.h - 2.0), 0.0, accent, 2.0)
	if (e.scene != 0 && c.node >= 0 && c.node < e.scene.nodes.length):
		mm_bounds* b = e.scene.nodes[c.node]
		ui_rect box = ui_rect_new(viewport.x + c.pan_x + cast(float32, b.x) * c.zoom - 4.0, viewport.y + c.pan_y + cast(float32, b.y) * c.zoom - 4.0, cast(float32, b.w) * c.zoom + 8.0, cast(float32, b.h) * c.zoom + 8.0)
		mm_ui_outline(r, box, 3.0, accent, 2.0)
	if (c.edge >= 0):
		mm_scene* selected = mm_canvas_edge_scene(e, c.edge)
		if (selected != 0):
			for mm_primitive* p in selected.items:
				if (p.kind == MM_LINE): mm_ui_line(r, viewport.x + c.pan_x + cast(float32, p.x) * c.zoom, viewport.y + c.pan_y + cast(float32, p.y) * c.zoom, viewport.x + c.pan_x + cast(float32, p.x2) * c.zoom, viewport.y + c.pan_y + cast(float32, p.y2) * c.zoom, 0, accent, 3.0)
			mm_scene_free(selected)
	ui_clip_pop(r)

# Source replacements preserve the nearest existing caret position and leave the
# scroll state intact; the widget clamps/reveals it for the new document extent.
void mm_canvas_source_sync(ui_textarea_state* area, char* source):
	if (strcmp(area.buf.data, source) == 0): return
	int offset = ui_textarea_caret_offset(area)
	ui_textarea_set(area, source)
	if (offset > area.buf.length): offset = area.buf.length
	ui_textarea_set_caret(area, ui_grapheme_floor(area.buf.data, offset))
	area.caret_goal_col = area.caret_col
