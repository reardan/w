# wbuild: x64
import lib.assert
import libs.wgrind.heap
import libs.wgrind.leak_report
import structures.json

int[4096] leak_memory
int leak_reader_fail = 0


int leak_reader(int opaque, int address, int size, int* out):
	if (leak_reader_fail || (opaque != 17) || (size != __word_size__) || (address < 65536) || (address >= 65536 + (__word_size__ * 4096))): return 0
	*out = leak_memory[(address - 65536) / __word_size__]
	return 1


int leak_at(int index):
	return 65536 + index * __word_size__ * 2


void leak_reset():
	for i in range(4096): leak_memory[i] = 0
	leak_reader_fail = 0


void leak_classification():
	leak_reset()
	wg_context* c = wg_create(32, 32, 4)
	assert1(c != 0)
	for i in range(10): assert1(wg_allocate(c, leak_at(i), __word_size__ * 2, 1, 100 + i))
	# A->B, root A: both reachable. C->D, interior root C: possible.
	# E->F: E directly lost, F indirectly. G<->H: one direct cycle
	# representative, one indirect. I->H: I direct, entire G/H indirect.
	# J isolated and directly lost.
	leak_memory[0] = leak_at(1)
	leak_memory[4] = leak_at(3)
	leak_memory[8] = leak_at(5)
	leak_memory[12] = leak_at(7)
	leak_memory[14] = leak_at(6)
	leak_memory[16] = leak_at(7)
	wg_leaks* l = wg_leaks_create(c, 32, 64, 1000, __word_size__, &leak_reader, 17)
	assert1(l != 0)
	assert1(wg_leaks_begin(l))
	assert1(wg_leaks_root_value(l, leak_at(0)))
	assert1(wg_leaks_root_value(l, leak_at(2) + 1))
	assert1(wg_leaks_finish(l))
	assert_equal(2, l.blocks[WG_LEAK_REACHABLE])
	assert_equal(2, l.blocks[WG_LEAK_POSSIBLE])
	assert_equal(3, l.blocks[WG_LEAK_DIRECT])
	assert_equal(3, l.blocks[WG_LEAK_INDIRECT])
	assert_equal(__word_size__ * 4, l.bytes[WG_LEAK_REACHABLE])
	assert_equal(WG_LEAK_DIRECT, l.nodes[4].kind)
	assert_equal(WG_LEAK_INDIRECT, l.nodes[5].kind)
	# Repeat without allocating checker metadata; exact root upgrades an
	# earlier interior root and propagates through the whole graph.
	int reserved = c.reserved_bytes
	assert1(wg_leaks_begin(l))
	assert1(wg_leaks_root_value(l, leak_at(2) + 1))
	assert1(wg_leaks_root_value(l, leak_at(2)))
	assert1(wg_leaks_finish(l))
	assert_equal(2, l.blocks[WG_LEAK_REACHABLE])
	assert_equal(0, l.blocks[WG_LEAK_POSSIBLE])
	assert_equal(reserved, c.reserved_bytes)
	# Isolate cycle: lowest-address member becomes its representative.
	leak_memory[16] = 0
	assert1(wg_leaks_begin(l))
	assert1(wg_leaks_finish(l))
	assert_equal(WG_LEAK_DIRECT, l.nodes[6].kind)
	assert_equal(WG_LEAK_INDIRECT, l.nodes[7].kind)
	wg_destroy(c)


void leak_root_rules():
	leak_reset()
	wg_context* c = wg_create(32, 32, 4)
	assert1(c != 0)
	for i in range(4): assert1(wg_allocate(c, leak_at(i), __word_size__ * 2, 1, 200 + i))
	# Defined interior heap edge makes the child possibly lost.
	leak_memory[0] = leak_at(1) + 1
	# Undefined bytes containing a real pointer must not keep an object.
	leak_memory[2] = leak_at(2)
	assert1(wg_mark(c, leak_at(1), 1, 3, 1, 210))
	int root = leak_at(32)
	leak_memory[64] = leak_at(0)
	leak_memory[65] = leak_at(3)
	assert1(wg_mark(c, root, __word_size__ * 2, 3, 0, 0))
	wg_leaks* l = wg_leaks_create(c, 32, 64, 1000, __word_size__, &leak_reader, 17)
	assert1(l != 0)
	assert1(wg_leaks_begin(l))
	# Leading unaligned root bytes aren't read as an aligned pointer.
	assert1(wg_leaks_root_range(l, root + 1, __word_size__ * 2 - 1))
	assert1(wg_leaks_root_value(l, leak_at(0)))
	assert1(wg_leaks_finish(l))
	assert_equal(2, l.blocks[WG_LEAK_REACHABLE])
	assert_equal(1, l.blocks[WG_LEAK_POSSIBLE])
	assert_equal(1, l.blocks[WG_LEAK_DIRECT])
	assert_equal(WG_LEAK_DIRECT, l.nodes[2].kind)
	# Checker memory is ignored even when a frontend supplied a root
	# encompassing it. Reader would reject this address if called.
	l.exclude_checker = 1
	assert1(wg_mark(c, cast(int, c), __word_size__, 3, 0, 0))
	assert1(wg_leaks_begin(l))
	assert1(wg_leaks_root_range(l, cast(int, c), __word_size__))
	assert1(wg_leaks_root_range(l, leak_at(0), __word_size__ * 8))
	assert1(wg_leaks_finish(l))
	assert_equal(0, l.blocks[WG_LEAK_REACHABLE])
	wg_destroy(c)


void leak_chain_and_limits():
	leak_reset()
	wg_context* c = wg_create(32, 2048, 4)
	assert1(c != 0)
	for i in range(1024):
		assert1(wg_allocate(c, leak_at(i), __word_size__, 1, i))
		if (i < 1023): leak_memory[i * 2] = leak_at(i + 1)
	wg_leaks* l = wg_leaks_create(c, 1024, 1024, 4096, __word_size__, &leak_reader, 17)
	assert1(l != 0)
	assert1(wg_leaks_begin(l))
	assert1(wg_leaks_finish(l))
	assert_equal(1, l.blocks[WG_LEAK_DIRECT])
	assert_equal(1023, l.blocks[WG_LEAK_INDIRECT])
	assert1(wg_leaks_begin(l))
	assert1(wg_leaks_root_value(l, leak_at(0)))
	assert1(wg_leaks_finish(l))
	assert_equal(1024, l.blocks[WG_LEAK_REACHABLE])
	leak_reader_fail = 1
	assert_equal(0, wg_leaks_begin(l))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)
	leak_reset()
	c = wg_create(8, 8, 2)
	assert1(wg_allocate(c, leak_at(0), __word_size__ * 2, 1, 1))
	l = wg_leaks_create(c, 8, 8, 1, __word_size__, &leak_reader, 17)
	assert1(l != 0)
	assert_equal(0, wg_leaks_begin(l))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)


void exhaustive_small_graphs():
	# Independent transitive-closure oracle for all 512 directed graphs
	# on three allocations, including self edges and every cycle shape.
	leak_reset()
	wg_context* c = wg_create(8, 8, 2)
	assert1(c != 0)
	for i in range(3): assert1(wg_allocate(c, 65536 + i * __word_size__ * 4, __word_size__ * 3, 1, i))
	wg_leaks* l = wg_leaks_create(c, 8, 16, 100, __word_size__, &leak_reader, 17)
	assert1(l != 0)
	for graph in range(512):
		int[9] paths
		for i in range(3):
			for j in range(3):
				int edge = (graph >> (i * 3 + j)) & 1
				paths[i * 3 + j] = edge || (i == j)
				leak_memory[i * 4 + j] = 0
				if (edge): leak_memory[i * 4 + j] = 65536 + j * __word_size__ * 4
		for k in range(3):
			for i in range(3):
				for j in range(3):
					paths[i * 3 + j] = paths[i * 3 + j] || (paths[i * 3 + k] && paths[k * 3 + j])
		assert1(wg_leaks_begin(l))
		int rooted = (graph % 7) == 0
		if (rooted): assert1(wg_leaks_root_value(l, 65536))
		assert1(wg_leaks_finish(l))
		for i in range(3):
			int expected = WG_LEAK_INDIRECT
			if (rooted && paths[i]): expected = WG_LEAK_REACHABLE
			else:
				int representative = i
				int incoming = 0
				for j in range(3):
					int same = paths[i * 3 + j] && paths[j * 3 + i]
					if (same && (j < representative)): representative = j
					if ((same == 0) && paths[j * 3 + i]): incoming = 1
				if ((representative == i) && (incoming == 0)): expected = WG_LEAK_DIRECT
			assert_equal(expected, l.nodes[i].kind)
	wg_destroy(c)


void local_reader_check():
	int[2] memory
	memory[0] = 0
	memory[1] = 0
	wg_context* c = wg_create(8, 8, 2)
	assert1(c != 0)
	assert1(wg_allocate(c, cast(int, &memory[0]), (__word_size__ * 2), 1, 1))
	wg_leaks* l = wg_leaks_create(c, 8, 8, 8, __word_size__, &wg_read_local, 0)
	assert1(l != 0)
	assert1(wg_leaks_begin(l))
	assert1(wg_leaks_root_value(l, cast(int, &memory[0])))
	assert1(wg_leaks_finish(l))
	assert_equal(1, l.blocks[WG_LEAK_REACHABLE])
	wg_destroy(c)


void leak_reports():
	leak_reset()
	wg_context* c = wg_create(8, 8, 2)
	assert1(c != 0)
	assert1(wg_allocate(c, leak_at(0), __word_size__ * 2, 1, 0x1234))
	wg_leaks* l = wg_leaks_create(c, 8, 8, 8, __word_size__, &leak_reader, 17)
	assert1(l != 0)
	assert_equal(-1, wg_leaks_found(l))
	assert_equal(0, wg_leaks_report(l, 2))
	assert1(wg_leaks_begin(l))
	assert1(wg_leaks_finish(l))
	assert_equal(1, wg_leaks_found(l))
	int[2] fds
	assert_equal(0, pipe(&fds[0]))
	int reader = load_int32(cast(char*, &fds[0]))
	int writer = load_int32(cast(char*, &fds[0]) + 4)
	assert1(wg_leaks_report(l, writer))
	assert1(wg_leaks_report_details(l, writer))
	assert_equal(0, close(writer))
	char[1024] buffer
	int n = read(reader, &buffer[0], 1023)
	assert1(n > 0)
	buffer[n] = 0
	assert_equal(0, close(reader))
	int split = 0
	while (buffer[split] != '\n'): split = split + 1
	buffer[split] = 0
	json_value* report = json_parse(&buffer[0])
	assert1(report != 0)
	assert_strings_equal(c"leak-summary", json_object_get(report, c"kind").string_value)
	json_value* direct = json_object_get(report, c"definitely-lost")
	assert_equal(1, json_object_get(direct, c"blocks").int_value)
	assert_equal(__word_size__ * 2, json_object_get(direct, c"bytes").int_value)
	json_free(report)
	report = json_parse(&buffer[split + 1])
	assert1(report != 0)
	assert_strings_equal(c"leak", json_object_get(report, c"kind").string_value)
	assert_strings_equal(c"definitely-lost", json_object_get(report, c"classification").string_value)
	assert_equal(__word_size__ * 2, json_object_get(report, c"size").int_value)
	json_free(report)
	assert_equal(0, wg_leaks_report(l, -1))
	assert_equal(0, wg_leaks_report_details(l, -1))
	assert1(wg_leaks_begin(l))
	assert1(wg_leaks_root_value(l, leak_at(0)))
	assert1(wg_leaks_finish(l))
	assert_equal(0, wg_leaks_found(l))
	wg_destroy(c)


int main():
	leak_classification()
	leak_root_rules()
	leak_chain_and_limits()
	exhaustive_small_graphs()
	local_reader_check()
	leak_reports()
	print("wgrind_leaks_test: OK\n")
	return 0
