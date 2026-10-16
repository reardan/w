# Allocation events for the native shadow engine. No application memory
# is allocated/freed here: both compiler and binary frontends can use it.
import libs.wgrind.shadow


int wg_height(wg_block* p):
	if (p == 0): return 0
	return p.height


void wg_height_update(wg_block* p):
	int h = wg_height(p.left)
	if (wg_height(p.right) > h): h = wg_height(p.right)
	p.height = h + 1


wg_block* wg_rotate_left(wg_block* p):
	wg_block* r = p.right
	p.right = r.left
	r.left = p
	wg_height_update(p)
	wg_height_update(r)
	return r


wg_block* wg_rotate_right(wg_block* p):
	wg_block* l = p.left
	p.left = l.right
	l.right = p
	wg_height_update(p)
	wg_height_update(l)
	return l


wg_block* wg_balance(wg_block* p):
	wg_height_update(p)
	if (wg_height(p.left) - wg_height(p.right) > 1):
		if (wg_height(p.left.right) > wg_height(p.left.left)): p.left = wg_rotate_left(p.left)
		return wg_rotate_right(p)
	if (wg_height(p.right) - wg_height(p.left) > 1):
		if (wg_height(p.right.left) > wg_height(p.right.right)): p.right = wg_rotate_right(p.right)
		return wg_rotate_left(p)
	return p


wg_block* wg_tree_add(wg_block* root, wg_block* p):
	if (root == 0): return p
	if (wg_less(p.address, root.address)): root.left = wg_tree_add(root.left, p)
	else: root.right = wg_tree_add(root.right, p)
	return wg_balance(root)


wg_block* wg_tree_remove(wg_block* root, int address):
	if (root == 0): return 0
	if (root.address == address):
		if (root.left == 0): return root.right
		if (root.right == 0): return root.left
		wg_block* next = root.right
		while (next.left != 0): next = next.left
		wg_block* right = wg_tree_remove(root.right, next.address)
		next.left = root.left
		next.right = right
		return wg_balance(next)
	if (wg_less(address, root.address)): root.left = wg_tree_remove(root.left, address)
	else: root.right = wg_tree_remove(root.right, address)
	return wg_balance(root)


int wg_overlap(wg_block* root, int address, int size):
	while (root != 0):
		if (root.address == address): return 1
		if (wg_less(address, root.address)):
			if (wg_less(root.address - address, size)): return 1
			root = root.left
		else:
			if (wg_less(address - root.address, root.size)): return 1
			root = root.right
	return 0


void wg_history_remove(wg_context* c, wg_block* p):
	if (p.older != 0): p.older.newer = p.newer
	else: c.oldest = p.newer
	if (p.newer != 0): p.newer.older = p.older
	else: c.newest = p.older
	p.older = 0
	p.newer = 0
	c.history_count = c.history_count - 1


void wg_history_recycle(wg_context* c):
	wg_block* p = c.oldest
	wg_history_remove(c, p)
	int bucket = wg_bucket(p.address)
	wg_block* prev = 0
	wg_block* at = cast(wg_block*, c.blocks[bucket])
	while (at != p):
		prev = at
		at = at.hash_next
	if (prev == 0): c.blocks[bucket] = cast(int, p.hash_next)
	else: prev.hash_next = p.hash_next
	p.state = 0
	p.hash_next = c.spare_blocks
	c.spare_blocks = p


wg_block* wg_block_get(wg_context* c, int address):
	wg_block* p = wg_block_find(c, address)
	if (p != 0):
		wg_history_remove(c, p)
		return p
	if ((c.spare_blocks == 0) && (c.block_count == c.block_limit)):
		if (c.oldest != 0): wg_history_recycle(c)
		else:
			wg_error(c, WG_INCOMPLETE, address, 0, 0, 0)
			return 0
	if (c.spare_blocks != 0):
		p = c.spare_blocks
		c.spare_blocks = p.hash_next
	else:
		p = cast(wg_block*, wg_reserve(c, sizeof(wg_block)))
		if (p == 0): return 0
		c.block_count = c.block_count + 1
	int bucket = wg_bucket(address)
	p.hash_next = cast(wg_block*, c.blocks[bucket])
	c.blocks[bucket] = cast(int, p)
	p.address = address
	return p


int wg_allocate(wg_context* c, int address, int size, int zeroed, int site):
	if (c.error): return 0
	# Null is the allocator's failure result, not an allocation event.
	if (address == 0): return 1
	if ((wg_range(address, size) == 0) || (c.live_bytes + size < c.live_bytes)):
		return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	if (wg_overlap(c.live_root, address, size)):
		return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	wg_block* p = wg_block_get(c, address)
	if (p == 0): return 0
	int u = 255
	if (zeroed): u = 0
	if (wg_mark(c, address, size, WG_READ | WG_WRITE, u, site) == 0): return 0
	p.size = size
	p.allocated_at = site
	p.freed_at = 0
	p.state = 1
	p.left = 0
	p.right = 0
	p.height = 1
	c.live_root = wg_tree_add(c.live_root, p)
	c.live_blocks = c.live_blocks + 1
	c.live_bytes = c.live_bytes + size
	return 1


# Normalize a successful calloc event without wrapping its byte count.
int wg_callocate(wg_context* c, int address, int count, int size, int site):
	if (c.error): return 0
	if (address == 0): return 1
	int maximum = ~(1 << (__word_size__ * 8 - 1))
	if ((count < 0) || (size < 0)): return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	if (count != 0):
		if (size > maximum / count): return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	return wg_allocate(c, address, count * size, 1, site)


int wg_deallocate(wg_context* c, int address, int site):
	if (c.error): return 0
	if (address == 0): return 1
	wg_block* p = wg_block_find(c, address)
	if ((p == 0) || (p.state != 1)):
		int kind = WG_INVALID_FREE
		if (p != 0): kind = WG_DOUBLE_FREE
		wg_error(c, kind, address, 0, site, 0)
		wg_describe(c, address)
		return 0
	if (wg_mark(c, address, p.size, 0, 0, 0) == 0): return 0
	c.live_root = wg_tree_remove(c.live_root, address)
	p.left = 0
	p.right = 0
	p.state = 2
	p.freed_at = site
	p.older = c.newest
	p.newer = 0
	if (c.newest != 0): c.newest.newer = p
	else: c.oldest = p
	c.newest = p
	c.live_blocks = c.live_blocks - 1
	c.live_bytes = c.live_bytes - p.size
	c.history_count = c.history_count + 1
	while (c.history_count > c.history_limit): wg_history_recycle(c)
	return 1


# Explicit success distinguishes failed realloc from realloc(p,0) that
# frees p. Frontends normalize their ABI's zero-size allocation contract.
int wg_reallocate(wg_context* c, int old, int address, int size, int success, int site):
	if (c.error): return 0
	wg_block* p = 0
	if (old != 0):
		p = wg_block_find(c, old)
		if ((p == 0) || (p.state != 1)):
			wg_error(c, WG_BAD_REALLOC, old, size, site, 0)
			wg_describe(c, old)
			return 0
	if (success == 0): return 1
	if (wg_range(address, size) == 0): return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	if (address == 0):
		if (size != 0): return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
		return wg_deallocate(c, old, site)
	if (p == 0): return wg_allocate(c, address, size, 0, site)
	int oldsize = p.size
	if (address == old):
		c.live_root = wg_tree_remove(c.live_root, old)
		int overlap = wg_overlap(c.live_root, address, size)
		p.left = 0
		p.right = 0
		p.height = 1
		c.live_root = wg_tree_add(c.live_root, p)
		if (overlap || (c.live_bytes - oldsize + size < c.live_bytes - oldsize)):
			return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
		if (size > oldsize):
			if (wg_mark(c, old + oldsize, size - oldsize, WG_READ | WG_WRITE, 255, site) == 0): return 0
		elif (size < oldsize):
			if (wg_mark(c, old + size, oldsize - size, 0, 0, 0) == 0): return 0
		p.size = size
		c.live_bytes = c.live_bytes - oldsize + size
		return 1
	if (wg_allocate(c, address, size, 0, site) == 0): return 0
	int copied = oldsize
	if (size < copied): copied = size
	if (wg_copy(c, address, old, copied, site) == 0): return 0
	return wg_deallocate(c, old, site)
