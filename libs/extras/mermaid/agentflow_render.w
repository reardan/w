# Agentflow presentation: per-edge curves and collapsed-container views.
import libs.extras.mermaid.style_render
import libs.extras.mermaid.shapes
import libs.extras.mermaid.agentflow

# An edge's `curve` metadata (MM_CURVE_*) is drawn by mm_render_edge through
# mm_style_curve_override: along its layered channel or obstacle route, ending
# with an axis-aligned leg so arrowheads and failure crosses keep their
# orientation. `animate` / `animation` set e.animate (mm_agent_edge_animate):
# the edge's segments draw dashed and the SVG export marches the dashes with
# SMIL (1s, fast 0.5s, slow 2s), as animated flowchart links do.

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
	for mm_bounds* b in view: mm_bounds_free(b)
	__w_list_free(cast(__w_list*, view))
	s.nodes = nodes
