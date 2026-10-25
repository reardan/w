# wbuild: x64
import lib.testing
import libs.extras.mermaid.canvas

mm_editor* canvas_fixture():
	return mm_editor_new(c"bin/canvas_fixture.mmd", c"flowchart LR\nA[Alpha] --> B[Beta]\n")

void test_canvas_click_threshold_and_one_undo_per_drag():
	mm_editor* e = canvas_fixture()
	mm_canvas c
	mm_canvas_init(&c)
	int x = e.scene.nodes[0].x
	int y = e.scene.nodes[0].y
	float32 px = cast(float32, x + 20)
	float32 py = cast(float32, y + 20)
	mm_canvas_press(&c, e, px, py)
	assert_equal(0, c.node)
	mm_canvas_motion(&c, e, px + 3.0, py)
	mm_canvas_release(&c, e)
	assert_equal(1, e.history.length)
	assert_equal(x, e.scene.nodes[0].x)
	mm_canvas_press(&c, e, px, py)
	for i in range(1, 21): mm_canvas_motion(&c, e, px + cast(float32, i * 2), py + 10.0)
	assert_equal(1, e.history.length)
	assert_equal(0, mm_editor_dirty(e))
	assert_equal(x + 40, e.scene.nodes[0].x)
	assert_equal(1, mm_canvas_release(&c, e))
	assert_equal(2, e.history.length)
	assert_equal(0, cast(int, c.pan_x))
	assert_equal(1, mm_editor_undo(e, 0))
	assert_equal(x, e.scene.nodes[0].x)
	mm_editor_free(e)

void test_canvas_cancel_restores_preview_and_pan():
	mm_editor* e = canvas_fixture()
	mm_canvas c
	mm_canvas_init(&c)
	int x = e.scene.nodes[0].x
	int y = e.scene.nodes[0].y
	mm_canvas_press(&c, e, cast(float32, x + 20), cast(float32, y + 20))
	mm_canvas_motion(&c, e, cast(float32, x + 90), cast(float32, y + 50))
	mm_canvas_cancel(&c, e)
	assert_equal(x, e.scene.nodes[0].x)
	assert_equal(y, e.scene.nodes[0].y)
	assert_equal(1, e.history.length)
	mm_canvas_press(&c, e, 2000.0, 2000.0)
	mm_canvas_motion(&c, e, 2100.0, 2050.0)
	assert_equal(100, cast(int, c.pan_x))
	mm_canvas_cancel(&c, e)
	assert_equal(0, cast(int, c.pan_x))
	assert_equal(0, cast(int, c.pan_y))
	mm_editor_free(e)

void test_canvas_zoom_anchor_fit_and_reset():
	mm_editor* e = canvas_fixture()
	mm_canvas c
	mm_canvas_init(&c)
	mm_canvas_fit(&c, e.scene, 1000.0, 800.0)
	asserts(c"fit centers horizontally", c.pan_x > 0.0)
	asserts(c"fit centers vertically", c.pan_y > 0.0)
	float32 x = (350.0 - c.pan_x) / c.zoom
	float32 y = (250.0 - c.pan_y) / c.zoom
	mm_canvas_zoom(&c, 1.25, 350.0, 250.0)
	asserts(c"anchor x invariant", fabs((350.0 - c.pan_x) / c.zoom - x) < 0.01)
	asserts(c"anchor y invariant", fabs((250.0 - c.pan_y) / c.zoom - y) < 0.01)
	float32 pan = c.pan_x
	c.node = 0
	c.move_here = 1
	c.connect_from = 0
	mm_canvas_reset(&c, e)
	assert_equal(-1, c.node)
	assert_equal(-1, c.connect_from)
	assert_equal(0, c.move_here)
	asserts(c"reset preserves camera", c.pan_x == pan)
	mm_editor_free(e)

void test_canvas_click_move_and_keyboard_are_drag_alternatives():
	mm_editor* e = canvas_fixture()
	mm_canvas c
	mm_canvas_init(&c)
	mm_canvas_cycle(&c, e, 0)
	assert_equal(0, c.node)
	c.move_here = 1
	assert_equal(1, mm_canvas_press(&c, e, 200.0, 150.0))
	assert_equal(200, e.scene.nodes[0].x)
	assert_equal(150, e.scene.nodes[0].y)
	assert_equal(1, mm_canvas_nudge(&c, e, 10, -1))
	assert_equal(210, e.scene.nodes[0].x)
	assert_equal(149, e.scene.nodes[0].y)
	assert_equal(3, e.history.length)
	mm_canvas_cycle(&c, e, 1)
	assert_equal(1, c.node)
	mm_editor_free(e)

void test_canvas_edge_hit_uses_rendered_geometry():
	mm_editor* e = canvas_fixture()
	mm_canvas c
	mm_canvas_init(&c)
	mm_scene* edge = mm_canvas_edge_scene(e, 0)
	mm_primitive* line = edge.items[1]
	float32 x = cast(float32, line.x + line.x2) / 2.0
	float32 y = cast(float32, line.y + line.y2) / 2.0
	assert_equal(0, mm_canvas_hit_edge(&c, e, x, y))
	mm_canvas_press(&c, e, x, y)
	assert_equal(0, c.edge)
	assert_equal(0, c.gesture)
	assert_equal(1, mm_canvas_delete(&c, e))
	assert_equal(0, e.document.edges.length)
	assert_equal(-1, c.edge)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_equal(1, e.document.edges.length)
	mm_scene_free(edge)
	mm_editor_free(e)

void test_canvas_connection_mode_and_unsupported_family():
	mm_editor* e = canvas_fixture()
	mm_canvas c
	mm_canvas_init(&c)
	c.connect_from = 0
	mm_bounds* b = e.scene.nodes[1]
	assert_equal(1, mm_canvas_press(&c, e, cast(float32, b.x + 20), cast(float32, b.y + 20)))
	assert_equal(2, e.document.edges.length)
	assert_equal(-1, c.connect_from)
	mm_canvas_reset(&c, e)
	mm_editor_change(e, c"pie\n  \"A\" : 1\n")
	assert_equal(0, mm_canvas_nudge(&c, e, 10, 0))
	mm_canvas_cycle(&c, e, 0)
	assert_equal(-1, c.node)
	assert_equal(-1, mm_canvas_hit_edge(&c, e, 50.0, 50.0))
	mm_editor_free(e)

void test_canvas_history_selection_tracks_identity_and_refreshes_labels():
	mm_editor* e = canvas_fixture()
	mm_canvas c
	mm_canvas_init(&c)
	c.node = 1
	assert_equal(1, mm_canvas_nudge(&c, e, 10, 0))
	assert_equal(1, mm_canvas_undo(&c, e, 0))
	assert_equal(1, c.node)
	assert_strings_equal(c"B", e.document.nodes[c.node].id)
	assert_equal(1, mm_canvas_undo(&c, e, 1))
	assert_equal(1, c.node)
	mm_canvas_reset(&c, e)
	mm_canvas_cycle(&c, e, 1)
	assert_equal(1, c.node)
	mm_editor_free(e)

void test_canvas_er_click_connection_and_selected_node_delete():
	mm_editor* e = mm_editor_new(c"bin/canvas_er.mmd", c"erDiagram\nA\nB\n")
	mm_canvas c
	mm_canvas_init(&c)
	c.connect_from = 0
	mm_bounds* b = e.scene.nodes[1]
	assert_equal(1, mm_canvas_press(&c, e, cast(float32, b.x + 20), cast(float32, b.y + 20)))
	assert_equal(1, e.document.edges.length)
	assert_equal(1, c.node)
	assert_equal(1, mm_canvas_delete(&c, e))
	assert_equal(1, e.document.nodes.length)
	assert_equal(0, e.document.edges.length)
	assert_equal(-1, c.node)
	mm_editor_free(e)

void test_canvas_selection_and_focus_change_exit_click_modes():
	mm_editor* e = canvas_fixture()
	mm_canvas c
	mm_canvas_init(&c)
	c.node = 0
	c.connect_from = 0
	mm_canvas_cycle(&c, e, 0)
	assert_equal(1, c.node)
	assert_equal(-1, c.connect_from)
	c.move_here = 1
	mm_canvas_cycle(&c, e, 1)
	assert_equal(0, c.node)
	assert_equal(0, c.move_here)
	c.connect_from = 0
	c.move_here = 1
	# The UI uses cancel when keyboard or pointer focus leaves the canvas.
	mm_canvas_cancel(&c, e)
	assert_equal(0, c.node)
	assert_equal(-1, c.connect_from)
	assert_equal(0, c.move_here)
	assert_equal(1, e.history.length)
	mm_editor_free(e)

void test_canvas_state_diagram_select_connect_drag_and_delete():
	mm_editor* e = mm_editor_new(c"unused.mmd", c"stateDiagram-v2\nIdle --> Busy\nDone\n")
	mm_canvas c
	mm_canvas_init(&c)
	int busy = mm_find_node(e.document, c"Busy")
	int done = mm_find_node(e.document, c"Done")
	mm_canvas_cycle(&c, e, 0)
	assert_equal(0, c.node)
	mm_bounds* b = e.scene.nodes[busy]
	mm_canvas_press(&c, e, cast(float32, b.x + 20), cast(float32, b.y + 20))
	assert_equal(busy, c.node)
	c.connect_from = busy
	b = e.scene.nodes[done]
	assert_equal(1, mm_canvas_press(&c, e, cast(float32, b.x + 20), cast(float32, b.y + 20)))
	assert_equal(2, e.document.edges.length)
	assert_strings_equal(c"Done", e.document.nodes[e.document.edges[1].to_node].id)
	mm_canvas_reset(&c, e)
	b = e.scene.nodes[done]
	float32 px = cast(float32, b.x + 20)
	float32 py = cast(float32, b.y + 20)
	mm_canvas_press(&c, e, px, py)
	assert_equal(2, c.gesture)
	mm_canvas_motion(&c, e, px + 40.0, py + 30.0)
	assert_equal(1, mm_canvas_release(&c, e))
	asserts(c"state drag persisted", index_of(e.document.source, c"%% @w-position \"Done\" ") >= 0)
	c.node = mm_find_node(e.document, c"Busy")
	assert_equal(1, mm_canvas_delete(&c, e))
	assert_equal(-1, mm_find_node(e.document, c"Busy"))
	assert_equal(0, e.document.edges.length)
	mm_editor_free(e)

float32 ct_cx(mm_editor* e, int i):
	return cast(float32, e.scene.nodes[i].x + e.scene.nodes[i].w / 2)

float32 ct_cy(mm_editor* e, int i):
	return cast(float32, e.scene.nodes[i].y + e.scene.nodes[i].h / 2)

void ct_drag(mm_canvas* c, mm_editor* e, float32 x, float32 y, float32 dx, float32 dy):
	for i in range(1, 11): mm_canvas_motion(c, e, x + dx * cast(float32, i) / 10.0, y + dy * cast(float32, i) / 10.0)

void test_canvas_shift_click_multi_select_drags_and_deletes_as_one_step():
	mm_editor* e = mm_editor_new(c"bin/canvas_fixture.mmd", c"flowchart LR\nA[Alpha] --> B[Beta]\nB --> C[Gamma]\n")
	mm_canvas c
	mm_canvas_init(&c)
	int a = mm_find_node(e.document, c"A")
	int b = mm_find_node(e.document, c"B")
	int ax = e.scene.nodes[a].x
	int bx = e.scene.nodes[b].x
	mm_canvas_press(&c, e, ct_cx(e, a), ct_cy(e, a))
	mm_canvas_release(&c, e)
	mm_canvas_press_mods(&c, e, ct_cx(e, b), ct_cy(e, b), MM_CANVAS_EXTEND)
	mm_canvas_release(&c, e)
	assert_equal(2, mm_canvas_selection_count(&c, e))
	assert_equal(1, mm_canvas_selected(&c, a))
	assert_equal(1, mm_canvas_selected(&c, b))
	# Dragging one member moves the whole selection in one undo step.
	float32 px = ct_cx(e, a)
	float32 py = ct_cy(e, a)
	mm_canvas_press(&c, e, px, py)
	ct_drag(&c, e, px, py, 30.0, 40.0)
	assert_equal(bx + 30, e.scene.nodes[b].x)
	assert_equal(1, mm_canvas_release(&c, e))
	assert_equal(2, e.history.length)
	assert_equal(ax + 30, e.scene.nodes[mm_find_node(e.document, c"A")].x)
	assert_equal(bx + 30, e.scene.nodes[mm_find_node(e.document, c"B")].x)
	asserts(c"both records", index_of(e.document.source, c"@w-position \"A\"") >= 0 && index_of(e.document.source, c"@w-position \"B\"") >= 0)
	# Shift-click again removes a member; arrows move what remains.
	c.node = mm_find_node(e.document, c"A")
	mm_canvas_toggle_node(&c, e, mm_find_node(e.document, c"B"))
	mm_canvas_toggle_node(&c, e, mm_find_node(e.document, c"C"))
	assert_equal(2, mm_canvas_selection_count(&c, e))
	assert_equal(1, mm_canvas_nudge(&c, e, 10, 0))
	assert_equal(3, e.history.length)
	assert_equal(1, mm_canvas_delete(&c, e))
	assert_equal(4, e.history.length)
	assert_equal(1, e.document.nodes.length)
	assert_strings_equal(c"B", e.document.nodes[0].id)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_equal(3, e.document.nodes.length)
	mm_editor_free(e)

void test_canvas_rubber_band_select_all_and_keyboard_extend():
	mm_editor* e = mm_editor_new(c"bin/canvas_fixture.mmd", c"flowchart LR\nA[Alpha] --> B[Beta]\nB --> C[Gamma]\n")
	mm_canvas c
	mm_canvas_init(&c)
	int a = mm_find_node(e.document, c"A")
	int b = mm_find_node(e.document, c"B")
	# A band from the background around A and B only.
	float32 x0 = cast(float32, e.scene.nodes[a].x - 4)
	float32 y0 = 1.0
	float32 x1 = cast(float32, e.scene.nodes[b].x + e.scene.nodes[b].w + 2)
	float32 y1 = cast(float32, e.scene.height - 1)
	asserts(c"band starts on background", mm_editor_hit(e, cast(int, x0), cast(int, y0)) < 0)
	mm_canvas_press_mods(&c, e, x0, y0, MM_CANVAS_EXTEND)
	assert_equal(3, c.gesture)
	ct_drag(&c, e, x0, y0, x1 - x0, y1 - y0)
	assert_equal(0, mm_canvas_release(&c, e))
	assert_equal(2, mm_canvas_selection_count(&c, e))
	assert_equal(0, mm_canvas_selected(&c, mm_find_node(e.document, c"C")))
	assert_equal(1, e.history.length)
	mm_canvas_select_all(&c, e)
	assert_equal(3, mm_canvas_selection_count(&c, e))
	# A plain click collapses to one node.
	mm_canvas_press(&c, e, ct_cx(e, a), ct_cy(e, a))
	mm_canvas_release(&c, e)
	assert_equal(1, mm_canvas_selection_count(&c, e))
	# Space keeps the set while Tab moves focus.
	mm_canvas_toggle_focused(&c, e)
	mm_canvas_cycle(&c, e, 0)
	mm_canvas_toggle_focused(&c, e)
	assert_equal(2, mm_canvas_selection_count(&c, e))
	mm_canvas_reset(&c, e)
	assert_equal(0, mm_canvas_selection_count(&c, e))
	mm_editor_free(e)

void test_canvas_resize_handle_and_keyboard_grow_persist_sizes():
	mm_editor* e = mm_editor_new(c"bin/canvas_fixture.mmd", c"flowchart LR\nA[Alpha] --> B[Beta]\n")
	mm_canvas c
	mm_canvas_init(&c)
	int w = e.scene.nodes[0].w
	int h = e.scene.nodes[0].h
	mm_canvas_press(&c, e, ct_cx(e, 0), ct_cy(e, 0))
	mm_canvas_release(&c, e)
	float32 hx = cast(float32, e.scene.nodes[0].x + w)
	float32 hy = cast(float32, e.scene.nodes[0].y + h)
	mm_canvas_press(&c, e, hx, hy)
	assert_equal(4, c.gesture)
	ct_drag(&c, e, hx, hy, 40.0, 20.0)
	assert_equal(w + 40, e.scene.nodes[0].w)
	assert_equal(1, mm_canvas_release(&c, e))
	assert_equal(2, e.history.length)
	asserts(c"size record", index_of(e.document.source, c"@w-size \"A\"") >= 0)
	assert_equal(w + 40, e.scene.nodes[0].w)
	assert_equal(h + 20, e.scene.nodes[0].h)
	c.node = 0
	assert_equal(1, mm_canvas_grow(&c, e, 0 - 10, 0))
	assert_equal(w + 30, e.scene.nodes[0].w)
	assert_equal(3, e.history.length)
	mm_editor_free(e)

void test_canvas_groups_select_drag_with_members_and_cycle():
	mm_editor* e = mm_editor_new(c"bin/canvas_fixture.mmd", c"flowchart LR\nsubgraph G[Group]\n  A[Alpha]\nend\nA --> B[Beta]\n")
	mm_canvas c
	mm_canvas_init(&c)
	int g = mm_find_node(e.document, c"G")
	int a = mm_find_node(e.document, c"A")
	int ax = e.scene.nodes[a].x
	# The group title band is the group, not its member.
	float32 tx = cast(float32, e.scene.nodes[g].x + 6)
	float32 ty = cast(float32, e.scene.nodes[g].y + 6)
	mm_canvas_press(&c, e, tx, ty)
	assert_equal(g, c.node)
	ct_drag(&c, e, tx, ty, 50.0, 0.0)
	assert_equal(ax + 50, e.scene.nodes[a].x)
	assert_equal(1, mm_canvas_release(&c, e))
	assert_equal(ax + 50, e.scene.nodes[mm_find_node(e.document, c"A")].x)
	# Tab reaches the group too.
	mm_canvas_reset(&c, e)
	int seen = 0
	for i in range(6):
		mm_canvas_cycle(&c, e, 0)
		if (c.node == mm_find_node(e.document, c"G")): seen = 1
	assert_equal(1, seen)
	mm_editor_free(e)
