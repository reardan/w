import lib.testing
import structures.rbtree
import structures.intrusive_list


struct titem:
	int key
	rb_node node


int titem_node_offset():
	titem* base = cast(titem*, 0)
	return cast(int, &base.node)


titem* titem_from_node(rb_node* node):
	return cast(titem*, container_of(cast(void*, node), titem_node_offset()))


titem* titem_new(int key):
	titem* item = new titem()
	item.key = key
	return item


# Kernel-style insert: walk to the slot, link, rebalance.
void tree_insert(rb_root* tree, titem* item):
	rb_node** slot = &tree.root
	rb_node* parent = 0
	while (*slot != 0):
		parent = *slot
		if (item.key < titem_from_node(parent).key):
			slot = &parent.left
		else:
			slot = &parent.right
	rb_link_node(&item.node, parent, slot)
	rb_insert_color(&item.node, tree)


titem* tree_find(rb_root* tree, int key):
	rb_node* node = tree.root
	while (node != 0):
		titem* item = titem_from_node(node)
		if (key == item.key):
			return item
		if (key < item.key):
			node = node.left
		else:
			node = node.right
	return 0


# --- red-black invariant checker ---

# Returns the black height of the subtree; asserts BST order, no
# red-red edges, consistent parent pointers and equal black heights.
int check_subtree(rb_node* node, rb_node* parent):
	if (node == 0):
		return 1
	asserts(c"parent pointer corrupt", node.parent == parent)
	if (rb_is_red(node)):
		asserts(c"red node has red child (left)", rb_is_red(node.left) == 0)
		asserts(c"red node has red child (right)", rb_is_red(node.right) == 0)
	int key = titem_from_node(node).key
	if (node.left != 0):
		asserts(c"BST order violated (left)", titem_from_node(node.left).key <= key)
	if (node.right != 0):
		asserts(c"BST order violated (right)", key <= titem_from_node(node.right).key)
	int left_height = check_subtree(node.left, node)
	int right_height = check_subtree(node.right, node)
	asserts(c"black heights differ", left_height == right_height)
	if (rb_is_red(node)):
		return left_height
	return left_height + 1


void check_tree(rb_root* tree):
	if (tree.root != 0):
		asserts(c"root must be black", rb_is_red(tree.root) == 0)
	check_subtree(tree.root, 0)


int tree_count(rb_root* tree):
	int n = 0
	rb_node* node = rb_first(tree)
	while (node != 0):
		n = n + 1
		node = rb_next(node)
	return n


# Deterministic xorshift-style PRNG (no ^ operator, so mix with
# multiply/add/shift instead; quality is fine for shuffling keys).
int rng_state
int rng_next(int bound):
	rng_state = rng_state * 1103515245 + 12345
	int value = (rng_state >> 8) & 1048575
	return value % bound


void test_empty_tree():
	rb_root tree
	rb_root_init(&tree)
	assert_equal(1, rb_empty(&tree))
	assert_equal(0, cast(int, rb_first(&tree)))
	assert_equal(0, cast(int, rb_last(&tree)))
	check_tree(&tree)


void test_single_node():
	rb_root tree
	rb_root_init(&tree)
	titem* item = titem_new(42)
	tree_insert(&tree, item)
	check_tree(&tree)
	assert_equal(42, titem_from_node(rb_first(&tree)).key)
	assert_equal(42, titem_from_node(rb_last(&tree)).key)
	rb_erase(&item.node, &tree)
	assert_equal(1, rb_empty(&tree))
	check_tree(&tree)
	free(item)


void test_sorted_iteration_after_random_inserts():
	rb_root tree
	rb_root_init(&tree)
	# Insert 0..99 in a scrambled deterministic order.
	rng_state = 12345
	int[100] keys
	int i = 0
	while (i < 100):
		keys[i] = i
		i = i + 1
	i = 99
	while (i > 0):
		int j = rng_next(i + 1)
		int tmp = keys[i]
		keys[i] = keys[j]
		keys[j] = tmp
		i = i - 1
	i = 0
	while (i < 100):
		tree_insert(&tree, titem_new(keys[i]))
		check_tree(&tree)
		i = i + 1

	# In-order traversal must yield 0..99 exactly.
	int expected = 0
	rb_node* node = rb_first(&tree)
	while (node != 0):
		assert_equal(expected, titem_from_node(node).key)
		expected = expected + 1
		node = rb_next(node)
	assert_equal(100, expected)

	# Reverse traversal must yield 99..0.
	expected = 99
	node = rb_last(&tree)
	while (node != 0):
		assert_equal(expected, titem_from_node(node).key)
		expected = expected - 1
		node = rb_prev(node)
	assert_equal((-1), expected)


void test_find():
	rb_root tree
	rb_root_init(&tree)
	int i = 0
	while (i < 50):
		tree_insert(&tree, titem_new(i * 2))
		i = i + 1
	assert_equal(48, tree_find(&tree, 48).key)
	assert_equal(0, tree_find(&tree, 0).key)
	assert_equal(98, tree_find(&tree, 98).key)
	assert_equal(0, cast(int, tree_find(&tree, 49)))
	assert_equal(0, cast(int, tree_find(&tree, 100)))


void test_erase_all_orders():
	# Erase ascending, descending, and root-first; invariants must hold
	# after every step and remaining nodes stay reachable and sorted.
	int order = 0
	while (order < 3):
		rb_root tree
		rb_root_init(&tree)
		# Word array of titem* (a T*[N] local would be natural here, but
		# see docs/todo.txt: pointer-array locals miscompile conditions).
		int[64] items
		int i = 0
		while (i < 64):
			titem* fresh = titem_new(i)
			items[i] = cast(int, fresh)
			tree_insert(&tree, fresh)
			i = i + 1

		int removed = 0
		while (removed < 64):
			titem* victim = 0
			if (order == 0):
				victim = cast(titem*, items[removed])
			else if (order == 1):
				victim = cast(titem*, items[63 - removed])
			else:
				victim = titem_from_node(tree.root)
			rb_erase(&victim.node, &tree)
			removed = removed + 1
			check_tree(&tree)
			assert_equal(64 - removed, tree_count(&tree))

		assert_equal(1, rb_empty(&tree))
		i = 0
		while (i < 64):
			free(cast(titem*, items[i]))
			i = i + 1
		order = order + 1


void test_random_insert_erase_stress():
	rb_root tree
	rb_root_init(&tree)
	rng_state = 987654321
	# Heap buffer of titem* words: local arrays >= ~126 words clobber
	# later locals (see docs/todo.txt), and T*[N] element types are not
	# supported, so a malloc'd word buffer sidesteps both.
	int* live = cast(int*, malloc(128 * __word_size__))
	int live_count = 0
	int next_key = 0
	int step = 0
	while (step < 1000):
		int do_insert = 1
		if (live_count == 128):
			do_insert = 0
		else if ((live_count > 0) & (rng_next(100) < 40)):
			do_insert = 0
		if (do_insert):
			titem* item = titem_new(next_key % 37)
			next_key = next_key + 1
			live[live_count] = cast(int, item)
			live_count = live_count + 1
			tree_insert(&tree, item)
		else:
			int pick = rng_next(live_count)
			titem* victim = cast(titem*, live[pick])
			live[pick] = live[live_count - 1]
			live_count = live_count - 1
			rb_erase(&victim.node, &tree)
			free(victim)
		check_tree(&tree)
		assert_equal(live_count, tree_count(&tree))
		step = step + 1
	free(live)


void test_duplicate_keys():
	rb_root tree
	rb_root_init(&tree)
	int i = 0
	while (i < 10):
		tree_insert(&tree, titem_new(7))
		i = i + 1
	check_tree(&tree)
	assert_equal(10, tree_count(&tree))
	rb_node* node = rb_first(&tree)
	while (node != 0):
		assert_equal(7, titem_from_node(node).key)
		node = rb_next(node)


void test_for_loop_cursor_protocol():
	rb_root tree
	rb_root_init(&tree)
	tree_insert(&tree, titem_new(30))
	tree_insert(&tree, titem_new(10))
	tree_insert(&tree, titem_new(20))
	rb_root* tree_ptr = &tree
	int previous = (-1)
	int count = 0
	for rb_node* node in tree_ptr:
		int key = titem_from_node(node).key
		asserts(c"for loop out of order", previous < key)
		previous = key
		count = count + 1
	assert_equal(3, count)
