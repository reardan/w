# Opt-in wasm semantic mirror for tools/web/index.html. One bridge per host.
# Publish only on semantic changes; drain actions against the published tree
# before replacing/freeing it. See docs/projects/accessibility.md.
import graphics.ui.accessibility

c_lib "env"
extern int gfx_access_begin(int max_nodes, int max_bytes, int snapshot)
extern int gfx_access_add(int id, int parent, int role, int states, int actions, int level)
extern int gfx_access_text(int id, int field, char* data, int length)
extern int gfx_access_commit(int focused_id)
extern int gfx_access_next(int snapshot, int32* metadata, char* data, int capacity)
extern void gfx_access_close()

int ui_access_web_publish(ui_access_tree* tree):
	if ((tree == 0) || (tree.root == 0)): return 0
	if (!gfx_access_begin(tree.max_nodes, tree.max_text_bytes, cast(int, tree))): return 0
	for int id in tree.nodes:
		ui_access_node* n = tree.nodes[id]
		int parent = 0
		if (n.parent != 0): parent = n.parent.id
		if (!gfx_access_add(id, parent, n.role, n.states, n.actions, n.heading_level)): return gfx_access_commit(0)
		if (!gfx_access_text(id, UI_ACCESS_NAME, n.name.data, n.name.length)): return gfx_access_commit(0)
		if (!gfx_access_text(id, UI_ACCESS_VALUE, n.value.data, n.value.length)): return gfx_access_commit(0)
		if (!gfx_access_text(id, UI_ACCESS_DESCRIPTION, n.description.data, n.description.length)): return gfx_access_commit(0)
	return gfx_access_commit(tree.focused_id)

# Host requests are revalidated against current W state. A different snapshot
# cannot consume this queue. Callbacks must not free or republish during dispatch.
int ui_access_web_dispatch(ui_access_tree* tree):
	if (tree == 0): return 0
	char* value = cast(char*, __w_alloc(__w_size_add(tree.max_text_bytes, 1)))
	int32[3] metadata
	int count = 0
	while (count < 64):
		if (gfx_access_next(cast(int, tree), &metadata[0], value, tree.max_text_bytes) != 1): break
		int accepted = ui_access_dispatch(tree, metadata[0], metadata[1], value, metadata[2])
		if (accepted && (metadata[1] == UI_ACCESS_FOCUS)): tree.focused_id = metadata[0]
		count = count + 1
	free(value)
	return count
