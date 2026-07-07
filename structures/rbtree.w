/*
Intrusive red-black tree, after the Linux kernel's include/linux/rbtree.h
(design: docs/projects/linux_idioms.md). W's first ordered container.

The rb_node lives inside the user's struct (recover the container with
container_of from structures/intrusive_list.w). The tree does not know
the key: callers walk to the insertion point themselves, link the node,
then let the tree rebalance. This keeps comparisons monomorphic and
allocation-free, kernel style:

	rb_node** slot = &tree.root
	rb_node* parent = 0
	while (*slot != 0):
		parent = *slot
		if (key < node_key(parent)):
			slot = &parent.left
		else:
			slot = &parent.right
	rb_link_node(&item.node, parent, slot)
	rb_insert_color(&item.node, &tree)

Removal is rb_erase(&item.node, &tree). Ordered traversal is
rb_first/rb_next (or rb_last/rb_prev), also exposed through the cursor
protocol so `for rb_node* n in tree_ptr:` visits nodes in sorted order.

Red-black invariants maintained: the root is black, no red node has a
red child, and every root-to-leaf path crosses the same number of black
nodes — guaranteeing O(log n) search, insert and erase.
*/
import lib.lib
import lib.assert


int rb_red():
	return 0


int rb_black():
	return 1


struct rb_node:
	rb_node* parent
	rb_node* left
	rb_node* right
	int color


struct rb_root:
	rb_node* root


void rb_root_init(rb_root* tree):
	tree.root = 0


int rb_empty(rb_root* tree):
	return tree.root == 0


# Attach node under parent at *slot (either &parent.left, &parent.right
# or &tree.root). The node starts red; rb_insert_color rebalances.
void rb_link_node(rb_node* node, rb_node* parent, rb_node** slot):
	node.parent = parent
	node.left = 0
	node.right = 0
	node.color = rb_red()
	*slot = node


int rb_is_red(rb_node* node):
	if (node == 0):
		return 0
	return node.color == rb_red()


void rb_set_parent_slot(rb_root* tree, rb_node* old, rb_node* new_node, rb_node* parent):
	if (parent == 0):
		tree.root = new_node
	else if (parent.left == old):
		parent.left = new_node
	else:
		parent.right = new_node


void rb_rotate_left(rb_root* tree, rb_node* node):
	rb_node* right = node.right
	node.right = right.left
	if (right.left != 0):
		right.left.parent = node
	right.parent = node.parent
	rb_set_parent_slot(tree, node, right, node.parent)
	right.left = node
	node.parent = right


void rb_rotate_right(rb_root* tree, rb_node* node):
	rb_node* left = node.left
	node.left = left.right
	if (left.right != 0):
		left.right.parent = node
	left.parent = node.parent
	rb_set_parent_slot(tree, node, left, node.parent)
	left.right = node
	node.parent = left


void rb_insert_color(rb_node* node, rb_root* tree):
	while (rb_is_red(node.parent)):
		rb_node* parent = node.parent
		# parent is red so it is never the root and grandparent exists.
		rb_node* grand = parent.parent
		if (parent == grand.left):
			rb_node* uncle = grand.right
			if (rb_is_red(uncle)):
				parent.color = rb_black()
				uncle.color = rb_black()
				grand.color = rb_red()
				node = grand
			else:
				if (node == parent.right):
					node = parent
					rb_rotate_left(tree, node)
					parent = node.parent
				parent.color = rb_black()
				grand.color = rb_red()
				rb_rotate_right(tree, grand)
		else:
			rb_node* uncle2 = grand.left
			if (rb_is_red(uncle2)):
				parent.color = rb_black()
				uncle2.color = rb_black()
				grand.color = rb_red()
				node = grand
			else:
				if (node == parent.left):
					node = parent
					rb_rotate_right(tree, node)
					parent = node.parent
				parent.color = rb_black()
				grand.color = rb_red()
				rb_rotate_left(tree, grand)
	tree.root.color = rb_black()


# Restore the black-height invariant after unlinking a black node whose
# replacement is node (possibly 0) under parent. Standard CLRS fixup
# with an explicit parent so nil children need no sentinel object.
void rb_erase_fixup(rb_root* tree, rb_node* node, rb_node* parent):
	while ((node != tree.root) & (rb_is_red(node) == 0)):
		if (parent.left == node):
			rb_node* sibling = parent.right
			if (rb_is_red(sibling)):
				sibling.color = rb_black()
				parent.color = rb_red()
				rb_rotate_left(tree, parent)
				sibling = parent.right
			if ((rb_is_red(sibling.left) == 0) & (rb_is_red(sibling.right) == 0)):
				sibling.color = rb_red()
				node = parent
				parent = node.parent
			else:
				if (rb_is_red(sibling.right) == 0):
					sibling.left.color = rb_black()
					sibling.color = rb_red()
					rb_rotate_right(tree, sibling)
					sibling = parent.right
				sibling.color = parent.color
				parent.color = rb_black()
				sibling.right.color = rb_black()
				rb_rotate_left(tree, parent)
				node = tree.root
				parent = 0
		else:
			rb_node* sibling2 = parent.left
			if (rb_is_red(sibling2)):
				sibling2.color = rb_black()
				parent.color = rb_red()
				rb_rotate_right(tree, parent)
				sibling2 = parent.left
			if ((rb_is_red(sibling2.left) == 0) & (rb_is_red(sibling2.right) == 0)):
				sibling2.color = rb_red()
				node = parent
				parent = node.parent
			else:
				if (rb_is_red(sibling2.left) == 0):
					sibling2.right.color = rb_black()
					sibling2.color = rb_red()
					rb_rotate_left(tree, sibling2)
					sibling2 = parent.left
				sibling2.color = parent.color
				parent.color = rb_black()
				sibling2.left.color = rb_black()
				rb_rotate_right(tree, parent)
				node = tree.root
				parent = 0
	if (node != 0):
		node.color = rb_black()


void rb_erase(rb_node* node, rb_root* tree):
	rb_node* child = 0
	rb_node* child_parent = 0
	int removed_color = node.color

	if (node.left == 0):
		child = node.right
		child_parent = node.parent
		rb_set_parent_slot(tree, node, child, node.parent)
		if (child != 0):
			child.parent = node.parent
	else if (node.right == 0):
		child = node.left
		child_parent = node.parent
		rb_set_parent_slot(tree, node, child, node.parent)
		child.parent = node.parent
	else:
		# Two children: the in-order successor (leftmost of the right
		# subtree) replaces node; its own right child fills its slot.
		rb_node* successor = node.right
		while (successor.left != 0):
			successor = successor.left
		removed_color = successor.color
		child = successor.right

		if (successor.parent == node):
			child_parent = successor
		else:
			child_parent = successor.parent
			successor.parent.left = child
			if (child != 0):
				child.parent = successor.parent
			successor.right = node.right
			node.right.parent = successor

		rb_set_parent_slot(tree, node, successor, node.parent)
		successor.parent = node.parent
		successor.left = node.left
		node.left.parent = successor
		successor.color = node.color
		if (child != 0):
			child.parent = child_parent

	if (removed_color == rb_black()):
		rb_erase_fixup(tree, child, child_parent)
	node.parent = 0
	node.left = 0
	node.right = 0


rb_node* rb_first(rb_root* tree):
	rb_node* node = tree.root
	if (node == 0):
		return 0
	while (node.left != 0):
		node = node.left
	return node


rb_node* rb_last(rb_root* tree):
	rb_node* node = tree.root
	if (node == 0):
		return 0
	while (node.right != 0):
		node = node.right
	return node


rb_node* rb_next(rb_node* node):
	if (node.right != 0):
		node = node.right
		while (node.left != 0):
			node = node.left
		return node
	rb_node* parent = node.parent
	while ((parent != 0) && (node == parent.right)):
		node = parent
		parent = parent.parent
	return parent


rb_node* rb_prev(rb_node* node):
	if (node.left != 0):
		node = node.left
		while (node.right != 0):
			node = node.right
		return node
	rb_node* parent = node.parent
	while ((parent != 0) && (node == parent.left)):
		node = parent
		parent = parent.parent
	return parent


# Cursor protocol (docs/projects/iteration.md): in-order traversal,
# cursors are node addresses, 0 is past-the-end.
int rb_root_iter_begin(rb_root* tree):
	return cast(int, rb_first(tree))


int rb_root_iter_done(rb_root* tree, int cursor):
	return cursor == 0


int rb_root_iter_next(rb_root* tree, int cursor):
	return cast(int, rb_next(cast(rb_node*, cursor)))


int rb_root_iter_value(rb_root* tree, int cursor):
	return cursor
