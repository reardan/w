# macOS NSAccessibility bridge. Build the companion with
# tools/mac/build_accessibility.sh; see docs/projects/accessibility.md.
import graphics.ui.accessibility

c_lib "@executable_path/libwaccessibility.dylib"
extern int w_access_open(int view, int max_bytes)
extern void w_access_begin(int bridge)
extern int w_access_add(int bridge, int id, int parent, int role, int states, int actions)
extern void w_access_bounds(int bridge, int id, float64 x, float64 y, float64 width, float64 height)
extern void w_access_heading(int bridge, int id, int level)
extern int w_access_text(int bridge, int id, int field, char* data, int length)
extern int w_access_commit(int bridge, int focused_id)
extern int w_access_next(int bridge, int* metadata, char* buffer, int capacity)
extern void w_access_close(int bridge)

# Publish copies all data into AppKit objects; no W snapshot is borrowed.
# Call on the UI thread, after draining actions from the previous snapshot.
int ui_access_cocoa_publish(int bridge, ui_access_tree* tree):
	if ((bridge == 0) || (tree == 0) || (tree.root == 0)): return 0
	w_access_begin(bridge)
	# Map iteration is insertion ordered; parents were inserted first.
	for int id in tree.nodes:
		ui_access_node* n = tree.nodes[id]
		int parent_id = 0
		if (n.parent != 0): parent_id = n.parent.id
		if (!w_access_add(bridge, id, parent_id, n.role, n.states, n.actions)): return w_access_commit(bridge, 0)
		w_access_bounds(bridge, id, cast(float64, n.bounds.x), cast(float64, n.bounds.y), cast(float64, n.bounds.w), cast(float64, n.bounds.h))
		w_access_heading(bridge, id, n.heading_level)
		if (!w_access_text(bridge, id, UI_ACCESS_NAME, n.name.data, n.name.length)): return w_access_commit(bridge, 0)
		if (!w_access_text(bridge, id, UI_ACCESS_VALUE, n.value.data, n.value.length)): return w_access_commit(bridge, 0)
		if (!w_access_text(bridge, id, UI_ACCESS_DESCRIPTION, n.description.data, n.description.length)): return w_access_commit(bridge, 0)
	return w_access_commit(bridge, tree.focused_id)

# Dispatch up to 64 native actions against the same snapshot that was
# published. The application callback changes its model; publish afterward.
int ui_access_cocoa_dispatch(int bridge, ui_access_tree* tree):
	if ((bridge == 0) || (tree == 0)): return 0
	char* value = cast(char*, __w_alloc(__w_size_add(tree.max_text_bytes, 1)))
	int[3] metadata
	int count = 0
	while (count < 64):
		int result = w_access_next(bridge, &metadata[0], value, tree.max_text_bytes)
		if (result != 1): break
		ui_access_dispatch(tree, metadata[0], metadata[1], value, metadata[2])
		count = count + 1
	free(value)
	return count
