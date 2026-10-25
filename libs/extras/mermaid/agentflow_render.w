# Agentflow presentation: per-edge curves and collapsed-container views.
import libs.extras.mermaid.style_render
import libs.extras.mermaid.shapes
import libs.extras.mermaid.agentflow

# Static rendering of an edge's `curve` metadata (MM_CURVE_*): the route
# from (ax,ay) through the bend at mx or my to (bx,by) ends with an
# axis-aligned leg so arrowheads and failure crosses keep their orientation.
# `animate` / `animation` stay metadata: the native renderer is static.
void mm_agent_edge_path(mm_scene* s, int curve, int ax, int ay, int mx, int my, int bx, int by, int horizontal, int dashed):
	if (horizontal):
		if (curve == MM_CURVE_LINEAR): mm_line(s, ax, ay, mx, by, dashed)
		else if (curve == MM_CURVE_BASIS): mm_style_bezier(s, ax, ay, (ax + mx) / 2, ay, (ax + mx) / 2, by, mx, by, dashed)
		else:
			mm_line(s, ax, ay, mx, ay, dashed)
			mm_line(s, mx, ay, mx, by, dashed)
		mm_line(s, mx, by, bx, by, dashed)
	else:
		if (curve == MM_CURVE_LINEAR): mm_line(s, ax, ay, bx, my, dashed)
		else if (curve == MM_CURVE_BASIS): mm_style_bezier(s, ax, ay, ax, (ay + my) / 2, bx, (ay + my) / 2, bx, my, dashed)
		else:
			mm_line(s, ax, ay, ax, my, dashed)
			mm_line(s, ax, my, bx, my, dashed)
		mm_line(s, bx, my, bx, by, dashed)

# Re-index a scene laid out for a projected view (mm_agent_project) back to
# the original nodes: hidden descendants take their collapsed container's
# box, so every original index has bounds.
void mm_agent_unproject(mm_scene* s, list[int] slots):
	list[mm_bounds*] view = s.nodes
	list[mm_bounds*] nodes = new list[mm_bounds*]
	for i in range(slots.length):
		mm_bounds* b = new mm_bounds()
		if (slots[i] >= 0 && slots[i] < view.length):
			mm_bounds* source = view[slots[i]]
			b.x = source.x
			b.y = source.y
			b.w = source.w
			b.h = source.h
			b.rank = source.rank
		nodes.push(b)
	for mm_bounds* b in view: free(b)
	__w_list_free(cast(__w_list*, view))
	s.nodes = nodes
