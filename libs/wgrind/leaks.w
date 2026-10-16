# Conservative, target-width reachability with explicit guest roots.
# Frontends stop all mutators for begin/root/finish. Checker-owned slabs
# are excluded. Only aligned, fully defined readable pointer words count.
import libs.wgrind.reader

const int WG_LEAK_REACHABLE = 1
const int WG_LEAK_POSSIBLE = 2
const int WG_LEAK_DIRECT = 3
const int WG_LEAK_INDIRECT = 4

struct wg_leak_node:
	wg_block* block
	int edges
	int reach
	int index
	int low
	int onstack
	int component
	int kind

struct wg_leak_edge:
	int target
	int interior
	int next

struct wg_leaks:
	wg_context* context
	wg_reader* reader
	int opaque
	int exclude_checker
	int pointer_size
	int node_limit
	int edge_limit
	int word_limit
	int words
	int count
	int edge_count
	int phase
	wg_leak_node* nodes
	wg_leak_edge* edges
	int* queue
	int queue_head
	int queue_tail
	int* stack
	int* frames
	int* iterators
	int* representatives
	int* incoming
	int* blocks
	int* bytes


wg_leaks* wg_leaks_create(wg_context* c, int node_limit, int edge_limit, int word_limit, int pointer_size, wg_reader* reader, int opaque):
	if (c.error): return 0
	if ((node_limit < 1) || (node_limit > 1048576) || (edge_limit < 1) || (edge_limit > 4194304) || (word_limit < 1) || ((pointer_size != 4) && (pointer_size != 8)) || (pointer_size > __word_size__) || (reader == 0)):
		wg_error(c, WG_INCOMPLETE, 0, node_limit, 0, 0)
		return 0
	wg_leaks* l = cast(wg_leaks*, wg_reserve(c, sizeof(wg_leaks)))
	if (l == 0): return 0
	l.context = c
	l.reader = reader
	l.opaque = opaque
	l.exclude_checker = reader == &wg_read_local
	l.pointer_size = pointer_size
	l.node_limit = node_limit
	l.edge_limit = edge_limit
	l.word_limit = word_limit
	l.phase = 0
	l.blocks = cast(int*, wg_reserve(c, __word_size__ * 5))
	l.bytes = cast(int*, wg_reserve(c, __word_size__ * 5))
	l.nodes = cast(wg_leak_node*, wg_reserve(c, sizeof(wg_leak_node) * node_limit))
	l.edges = cast(wg_leak_edge*, wg_reserve(c, sizeof(wg_leak_edge) * edge_limit))
	l.queue = cast(int*, wg_reserve(c, __word_size__ * node_limit * 2))
	l.stack = cast(int*, wg_reserve(c, __word_size__ * node_limit))
	l.frames = cast(int*, wg_reserve(c, __word_size__ * node_limit))
	l.iterators = cast(int*, wg_reserve(c, __word_size__ * node_limit))
	l.representatives = cast(int*, wg_reserve(c, __word_size__ * node_limit))
	l.incoming = cast(int*, wg_reserve(c, __word_size__ * node_limit))
	if (c.error): return 0
	return l


int wg_leak_checker_address(wg_context* c, int address):
	if (wg_less(address - cast(int, c), 4096)): return 1
	wg_arena* a = c.arenas
	while (a != 0):
		if (wg_less(address - cast(int, a), a.length)): return 1
		a = a.next
	return 0


int wg_leak_target(wg_leaks* l, int pointer):
	# Binary search the address-sorted live allocation snapshot.
	int left = 0
	int right = l.count
	while (left < right):
		int mid = left + (right - left) / 2
		if (wg_less(pointer, l.nodes[mid].block.address)): right = mid
		else: left = mid + 1
	if (left == 0): return -1
	wg_block* block = l.nodes[left - 1].block
	if ((pointer == block.address) || wg_less(pointer - block.address, block.size)): return left - 1
	return -1


int wg_leak_enqueue(wg_leaks* l, int target, int reach):
	wg_leak_node* node = &l.nodes[target]
	if ((node.reach == 0) || (reach < node.reach)):
		if (l.queue_tail >= l.node_limit * 2): return wg_error(l.context, WG_INCOMPLETE, 0, l.queue_tail, 0, 0)
		node.reach = reach
		l.queue[l.queue_tail] = target
		l.queue_tail = l.queue_tail + 1
	return 1


int wg_leaks_root_value(wg_leaks* l, int value):
	if (l.context.error): return 0
	if (l.phase != 1): return wg_error(l.context, WG_INCOMPLETE, value, 0, 0, 0)
	int target = wg_leak_target(l, value)
	if (target < 0): return 1
	int reach = WG_LEAK_REACHABLE
	if (value != l.nodes[target].block.address): reach = WG_LEAK_POSSIBLE
	return wg_leak_enqueue(l, target, reach)


int wg_leak_scan(wg_leaks* l, int address, int size, int source):
	wg_context* c = l.context
	if (wg_range(address, size) == 0): return wg_error(c, WG_INCOMPLETE, address, size, 0, 0)
	int width = l.pointer_size
	int skip = (width - (address & (width - 1))) & (width - 1)
	int offset = skip
	while (offset <= size - width):
		int at = address + offset
		if (l.words == l.word_limit): return wg_error(c, WG_INCOMPLETE, at, width, 0, 0)
		l.words = l.words + 1
		int readable = 1
		# Separate address spaces can legitimately reuse checker addresses.
		if (l.exclude_checker): readable = wg_leak_checker_address(c, at) == 0
		# Heap contents are graph edges, never unconditional root memory.
		if ((source == -1) && (wg_leak_target(l, at) >= 0)): readable = 0
		for i in range(width):
			wg_page* page = wg_page_find(c, at + i)
			if (page == 0): readable = 0
			else:
				int index = (at + i) & 4095
				if (((page.permissions[index] & WG_READ) == 0) || page.undefined[index]): readable = 0
		if (readable):
			int value = 0
			if (l.reader(l.opaque, at, width, &value) == 0): return wg_error(c, WG_INCOMPLETE, at, width, 0, 0)
			int target = wg_leak_target(l, value)
			if (target >= 0):
				if (source < 0):
					if (wg_leaks_root_value(l, value) == 0): return 0
				else:
					if (l.edge_count == l.edge_limit): return wg_error(c, WG_INCOMPLETE, at, width, 0, 0)
					wg_leak_edge* edge = &l.edges[l.edge_count]
					edge.target = target
					edge.interior = value != l.nodes[target].block.address
					edge.next = l.nodes[source].edges
					l.nodes[source].edges = l.edge_count
					l.edge_count = l.edge_count + 1
		offset = offset + width
	return 1


int wg_leaks_begin(wg_leaks* l):
	wg_context* c = l.context
	if (c.error): return 0
	if (l.phase == 1): return wg_error(c, WG_INCOMPLETE, 0, 0, 0, 0)
	l.count = 0
	l.edge_count = 0
	l.words = 0
	l.queue_head = 0
	l.queue_tail = 0
	for i in range(5):
		l.blocks[i] = 0
		l.bytes[i] = 0
	# In-order traversal of the live allocation AVL tree.
	int depth = 0
	wg_block* block = c.live_root
	while ((block != 0) || depth):
		if (block != 0):
			if (depth == l.node_limit): return wg_error(c, WG_INCOMPLETE, 0, depth, 0, 0)
			l.stack[depth] = cast(int, block)
			depth = depth + 1
			block = block.left
		else:
			depth = depth - 1
			block = cast(wg_block*, l.stack[depth])
			if (l.count == l.node_limit): return wg_error(c, WG_INCOMPLETE, block.address, block.size, 0, 0)
			wg_leak_node* node = &l.nodes[l.count]
			node.block = block
			node.edges = -1
			node.reach = 0
			node.index = -1
			node.low = -1
			node.onstack = 0
			node.component = -1
			node.kind = 0
			l.count = l.count + 1
			block = block.right
	l.phase = 1
	for i in range(l.count):
		block = l.nodes[i].block
		if (wg_leak_scan(l, block.address, block.size, i) == 0): return 0
	return 1


int wg_leaks_root_range(wg_leaks* l, int address, int size):
	if (l.context.error): return 0
	if (l.phase != 1): return wg_error(l.context, WG_INCOMPLETE, address, size, 0, 0)
	return wg_leak_scan(l, address, size, -1)


# Only the execution frontend's validated live-stack extent may use
# this entry point. Unlike generic roots, a live malloc-backed stack is
# itself reachable and its active pointer slots are unconditional roots.
# Checker-memory exclusion still applies to both payloads and owners.
int wg_leaks_stack_range(wg_leaks* l, int address, int size):
	wg_context* c = l.context
	if (c.error): return 0
	if ((l.phase != 1) || (wg_range(address, size) == 0)): return wg_error(c, WG_INCOMPLETE, address, size, 0, 0)
	if (size == 0): return 1
	for i in range(l.count):
		wg_block* block = l.nodes[i].block
		if (l.exclude_checker && wg_leak_checker_address(c, block.address)): continue
		if (wg_less(address - block.address, block.size) || wg_less(block.address - address, size)):
			if (wg_leak_enqueue(l, i, WG_LEAK_REACHABLE) == 0): return 0
	return wg_leak_scan(l, address, size, -2)


int wg_leaks_finish(wg_leaks* l):
	wg_context* c = l.context
	if (c.error): return 0
	if (l.phase != 1): return wg_error(c, WG_INCOMPLETE, 0, 0, 0, 0)
	while (l.queue_head < l.queue_tail):
		int source = l.queue[l.queue_head]
		l.queue_head = l.queue_head + 1
		int e = l.nodes[source].edges
		while (e >= 0):
			wg_leak_edge* edge = &l.edges[e]
			int reach = l.nodes[source].reach
			if (edge.interior): reach = WG_LEAK_POSSIBLE
			if (wg_leak_enqueue(l, edge.target, reach) == 0): return 0
			e = edge.next
	# Iterative Tarjan SCC avoids a host-stack overflow on long chains.
	int serial = 0
	int top = 0
	int components = 0
	for start in range(l.count):
		if (l.nodes[start].reach || (l.nodes[start].index >= 0)): continue
		int depth = 1
		l.frames[0] = start
		l.iterators[0] = -2
		while (depth):
			int current = l.frames[depth - 1]
			wg_leak_node* node = &l.nodes[current]
			if (l.iterators[depth - 1] == -2):
				node.index = serial
				node.low = serial
				serial = serial + 1
				node.onstack = 1
				l.stack[top] = current
				top = top + 1
				l.iterators[depth - 1] = node.edges
			int e = l.iterators[depth - 1]
			if (e >= 0):
				wg_leak_edge* edge = &l.edges[e]
				l.iterators[depth - 1] = edge.next
				wg_leak_node* target = &l.nodes[edge.target]
				if (target.reach): continue
				if (target.index < 0):
					l.frames[depth] = edge.target
					l.iterators[depth] = -2
					depth = depth + 1
				else:
					if (target.onstack && (target.index < node.low)): node.low = target.index
			else:
				if (node.low == node.index):
					int done = 0
					int representative = current
					while (done == 0):
						top = top - 1
						int member = l.stack[top]
						l.nodes[member].onstack = 0
						l.nodes[member].component = components
						if (member < representative): representative = member
						done = member == current
					l.representatives[components] = representative
					l.incoming[components] = 0
					components = components + 1
				depth = depth - 1
				if (depth):
					wg_leak_node* parent = &l.nodes[l.frames[depth - 1]]
					if (node.low < parent.low): parent.low = node.low
	for i in range(l.count):
		wg_leak_node* node = &l.nodes[i]
		if (node.reach): continue
		int e = node.edges
		while (e >= 0):
			wg_leak_node* target = &l.nodes[l.edges[e].target]
			if ((target.reach == 0) && (target.component != node.component)): l.incoming[target.component] = 1
			e = l.edges[e].next
	for i in range(l.count):
		wg_leak_node* node = &l.nodes[i]
		int kind = node.reach
		if (kind == 0):
			kind = WG_LEAK_INDIRECT
			if ((l.incoming[node.component] == 0) && (l.representatives[node.component] == i)): kind = WG_LEAK_DIRECT
		node.kind = kind
		l.blocks[kind] = l.blocks[kind] + 1
		l.bytes[kind] = l.bytes[kind] + node.block.size
	l.phase = 2
	return 1
