# wbuild: x64
import lib.assert
import libs.wgrind.heap
import libs.wgrind.values
import libs.wgrind.report
import libs.wgrind.registers


wg_context* context(int pages, int blocks, int history):
	wg_context* c = wg_create(pages, blocks, history)
	assert1(c != 0)
	assert_equal(0, c.error)
	return c


void check_access_and_origins():
	wg_context* c = context(16, 32, 8)
	int base = 65533 # payload crosses a shadow-page boundary
	assert1(wg_allocate(c, base, 13, 0, 111))
	wg_value value
	assert1(wg_load(c, base, 4, 222, &value))
	assert_equal(wg_mask(4), value.undefined)
	assert_equal(111, value.origin)
	# A load may copy undefined bits. A consequential use reports them.
	assert_equal(0, c.error)
	assert_equal(0, wg_use(c, &value, 223))
	assert_equal(WG_UNDEFINED, c.error)
	assert_equal(111, c.error_origin)
	assert_equal(223, c.error_site)
	wg_clear_error(c)
	wg_value_set(&value, 7, 0x80, 333)
	assert1(wg_store(c, base + 1, 1, 224, &value))
	assert1(wg_load(c, base + 1, 1, 225, &value))
	assert_equal(0x80, value.undefined)
	assert_equal(333, value.origin)
	assert_equal(0, wg_access(c, base - 1, 1, WG_READ, 230))
	assert_equal(WG_INVALID_READ, c.error)
	assert_equal(-1, c.error_offset)
	assert_equal(111, c.error_allocation)
	wg_clear_error(c)
	# Check the entire width; the start alone is valid.
	wg_value_set(&value, 0, 0, 0)
	assert_equal(0, wg_store(c, base + 12, 2, 231, &value))
	assert_equal(WG_INVALID_WRITE, c.error)
	assert_equal(base + 13, c.error_address)
	assert_equal(2, c.error_size)
	wg_clear_error(c)
	assert1(wg_load(c, base + 12, 1, 232, &value))
	assert_equal(255, value.undefined) # failed store changed nothing
	assert1(wg_deallocate(c, base, 444))
	assert_equal(0, c.page_count)
	assert_equal(0, wg_access(c, base, 1, WG_READ, 445))
	assert_equal(111, c.error_allocation)
	assert_equal(444, c.error_free)
	wg_clear_error(c)
	assert_equal(0, wg_deallocate(c, base, 446))
	assert_equal(WG_DOUBLE_FREE, c.error)
	wg_clear_error(c)
	assert_equal(0, wg_deallocate(c, base + 1, 447))
	assert_equal(WG_INVALID_FREE, c.error)
	wg_clear_error(c)
	assert1(wg_allocate(c, base, 13, 1, 555))
	assert1(wg_load(c, base, 4, 556, &value))
	assert_equal(0, value.undefined)
	assert_equal(0, value.origin)
	assert_equal(0, c.history_count)
	assert_equal(1, c.live_blocks)
	assert_equal(13, c.live_bytes)
	assert1(wg_deallocate(c, base, 557))
	wg_destroy(c)


void check_copies_and_realloc():
	wg_context* c = context(16, 32, 8)
	int base = 65536
	assert1(wg_allocate(c, base, 16, 0, 101))
	wg_value value
	wg_value_set(&value, 3, 0, 0)
	assert1(wg_store(c, base, 4, 102, &value))
	assert1(wg_copy(c, base + 1, base, 8, 103))
	for i in range(5):
		assert1(wg_load(c, base + i, 1, 104, &value))
		assert_equal(0, value.undefined)
	assert1(wg_load(c, base + 5, 1, 105, &value))
	assert_equal(255, value.undefined)
	assert_equal(101, value.origin)
	assert1(wg_copy(c, base, base + 4, 8, 106))
	assert1(wg_load(c, base + 1, 1, 107, &value))
	assert_equal(255, value.undefined)
	# Failed output copy must not modify a valid prefix.
	assert_equal(0, wg_copy(c, base + 15, base, 2, 108))
	wg_clear_error(c)
	assert1(wg_load(c, base + 15, 1, 109, &value))
	assert_equal(255, value.undefined)
	assert1(wg_reallocate(c, base, 0, 100, 0, 110))
	assert_equal(16, c.live_bytes)
	assert1(wg_load(c, base, 1, 111, &value))
	assert_equal(0, value.undefined)
	assert1(wg_reallocate(c, base, 131072, 32, 1, 112))
	assert_equal(32, c.live_bytes)
	assert_equal(1, c.live_blocks)
	assert1(wg_load(c, 131072, 1, 113, &value))
	assert_equal(0, value.undefined)
	assert1(wg_load(c, 131073, 1, 114, &value))
	assert_equal(101, value.origin)
	assert1(wg_load(c, 131072 + 16, 1, 115, &value))
	assert_equal(112, value.origin)
	assert_equal(0, wg_access(c, base, 1, WG_WRITE, 116))
	assert_equal(112, c.error_free)
	wg_clear_error(c)
	assert1(wg_reallocate(c, 131072, 131072, 4, 1, 117))
	assert_equal(4, c.live_bytes)
	assert_equal(0, wg_access(c, 131076, 1, WG_READ, 118))
	wg_clear_error(c)
	assert1(wg_reallocate(c, 131072, 131072, 8, 1, 119))
	assert1(wg_load(c, 131076, 1, 120, &value))
	assert_equal(119, value.origin)
	assert_equal(255, value.undefined)
	assert1(wg_reallocate(c, 131072, 0, 0, 1, 121))
	assert_equal(0, c.live_bytes)
	assert_equal(0, c.live_blocks)
	assert1(wg_reallocate(c, 0, 262144, 0, 1, 122))
	assert_equal(1, c.live_blocks)
	assert_equal(0, wg_access(c, 262144, 1, WG_READ, 123))
	wg_clear_error(c)
	assert1(wg_deallocate(c, 262144, 124))
	assert_equal(0, wg_reallocate(c, 262144, 0, 1, 0, 125))
	assert_equal(WG_BAD_REALLOC, c.error)
	wg_destroy(c)


void check_kernel_boundaries():
	wg_context* c = context(4, 8, 2)
	assert1(wg_allocate(c, 65536, 8, 0, 1))
	assert1(wg_kernel_write(c, 65536, -4, 2))
	wg_value value
	assert1(wg_load(c, 65536, 1, 3, &value))
	assert_equal(255, value.undefined)
	assert1(wg_kernel_write(c, 65536, 3, 4))
	assert1(wg_kernel_read(c, 65536, 3, 5))
	assert_equal(0, wg_kernel_read(c, 65536, 8, 6))
	assert_equal(WG_UNDEFINED, c.error)
	assert_equal(65539, c.error_address)
	assert_equal(1, c.error_origin)
	wg_clear_error(c)
	assert_equal(0, wg_kernel_write(c, 65536, 9, 7))
	assert_equal(WG_INVALID_WRITE, c.error)
	wg_clear_error(c)
	assert1(wg_load(c, 65539, 1, 8, &value))
	assert_equal(255, value.undefined)
	assert1(wg_mark(c, 131072, 4, WG_READ, 0, 0))
	assert1(wg_access(c, 131072, 4, WG_READ, 9))
	assert_equal(0, wg_access(c, 131072, 1, WG_WRITE, 10))
	assert_equal(WG_INVALID_WRITE, c.error)
	wg_destroy(c)


int check_tree(wg_block* p):
	if (p == 0): return 0
	int l = check_tree(p.left)
	int r = check_tree(p.right)
	assert1(l - r <= 1)
	assert1(r - l <= 1)
	if (p.left != 0): assert1(wg_less(p.left.address, p.address))
	if (p.right != 0): assert1(wg_less(p.address, p.right.address))
	int expected = l + 1
	if (r > l): expected = r + 1
	assert_equal(expected, p.height)
	return expected


void check_recycling_and_tree():
	wg_context* c = context(32, 4096, 16)
	for i in range(2048): assert1(wg_allocate(c, 65536 + i * 16, 13, 0, i + 1))
	assert1(check_tree(c.live_root) < 16)
	assert_equal(2048, c.live_blocks)
	# Remove odd, then even indices; check rotations after every removal.
	for pass in range(2):
		for i in range(1024):
			assert1(wg_deallocate(c, 65536 + (i * 2 + pass) * 16, 9000))
			check_tree(c.live_root)
	assert_equal(0, c.live_bytes)
	assert_equal(0, c.page_count)
	assert_equal(16, c.history_count)
	int reserved = c.reserved_bytes
	for i in range(10000):
		int address = 1048576 + i * WG_PAGE
		assert1(wg_allocate(c, address, 16, 0, 10001 + i))
		assert1(wg_deallocate(c, address, 20001 + i))
		assert_equal(0, c.page_count)
	assert_equal(reserved, c.reserved_bytes)
	assert_equal(16, c.history_count)
	assert_equal(2048, c.block_count)
	# Reuse an address still in the middle of the free-history queue.
	int reused = 1048576 + 9990 * WG_PAGE
	assert1(wg_allocate(c, reused, 16, 0, 40000))
	assert_equal(15, c.history_count)
	assert1(wg_deallocate(c, reused, 40001))
	assert_equal(16, c.history_count)
	wg_destroy(c)


void check_limits_and_ranges():
	wg_context* c = context(1, 2, 1)
	assert1(wg_allocate(c, 65536, 4, 0, 1))
	assert_equal(0, wg_allocate(c, 65537, 4, 0, 2))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_clear_error(c)
	assert_equal(WG_INCOMPLETE, c.error) # cannot turn incomplete into clean
	wg_destroy(c)
	c = context(1, 2, 1)
	assert1(wg_allocate(c, 65536, 4, 0, 1))
	assert_equal(0, wg_allocate(c, 131072, 4, 0, 2))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)
	c = context(4, 1, 0)
	assert1(wg_allocate(c, 65536, 4, 0, 1))
	assert_equal(0, wg_allocate(c, 65552, 4, 0, 2))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)
	c = context(4, 1, 1)
	for i in range(100):
		assert1(wg_allocate(c, 65536 + i * 16, 4, 0, 1))
		assert1(wg_deallocate(c, 65536 + i * 16, 2))
	assert_equal(1, c.block_count)
	wg_destroy(c)
	assert_equal(0, wg_range(-2, 4))
	assert_equal(1, wg_range(-2, 2))
	assert_equal(1, wg_range(-1, 0))
	c = context(2, 4, 2)
	assert1(wg_allocate(c, -8, 8, 0, 12))
	wg_value value
	assert1(wg_load(c, -1, 1, 13, &value))
	assert_equal(12, value.origin)
	assert1(wg_deallocate(c, -8, 14))
	wg_destroy(c)


void trits(int state, wg_value* value):
	int v = 0
	int u = 0
	for i in range(4):
		int t = state % 3
		state = state / 3
		if (t == 1): v = v | (1 << i)
		if (t == 2): u = u | (1 << i)
	wg_value_set(value, v, u, 77)


int concrete(int op, int a, int b):
	if (op == WG_AND): return a & b
	if (op == WG_OR): return a | b
	if (op == WG_XOR): return a ^ b
	if (op == WG_ADD): return (a + b) & 255
	if (op == WG_SUB): return (a - b) & 255
	return a == b


void check_value_oracle():
	wg_context* c = context(1, 1, 0)
	wg_value a
	wg_value b
	wg_value out
	# Exhaust all 3^4 abstract values per operand, and independently
	# enumerate the concrete executions each abstract pair represents.
	for op in range(WG_AND, WG_EQ + 1):
		for sa in range(81):
			trits(sa, &a)
			for sb in range(81):
				trits(sb, &b)
				int every = 255
				int any = 0
				for x in range(16):
					if ((x & ~a.undefined) != a.value): continue
					for y in range(16):
						if ((y & ~b.undefined) != b.value): continue
						int v = concrete(op, x, y)
						every = every & v
						any = any | v
				assert1(wg_binary(c, op, 1, &a, &b, &out))
				assert_equal(concrete(op, a.value, b.value), out.value)
				assert_equal(any ^ every, out.undefined)
				if (out.undefined == 0): assert_equal(0, out.origin)
	wg_destroy(c)


int concrete_shift(int op, int value, int count):
	if (op == WG_SHL): return (value << count) & 255
	if (op == WG_SAR):
		if (value & 128): value = value - 256
	return (value >> count) & 255


void check_shift_oracle():
	wg_context* c = context(1, 1, 0)
	wg_value a
	wg_value count
	wg_value out
	for op in range(WG_SHL, WG_SAR + 1):
		for sa in range(81):
			trits(sa, &a)
			# Put one abstract bit in the sign position to exercise SAR.
			a.value = (a.value & 7) | ((a.value & 8) << 4)
			a.undefined = (a.undefined & 7) | ((a.undefined & 8) << 4)
			for sc in range(9):
				trits(sc, &count)
				int every = 255
				int any = 0
				for raw in range(16):
					int x = (raw & 7) | ((raw & 8) << 4)
					if ((x & ~a.undefined) != a.value): continue
					for k in range(4):
						if ((k & ~count.undefined) != count.value): continue
						int v = concrete_shift(op, x, k)
						every = every & v
						any = any | v
				assert1(wg_shift(c, op, 1, &a, &count, 1, &out))
				assert_equal(concrete_shift(op, a.value, count.value), out.value)
				assert_equal(any ^ every, out.undefined)
				if (out.undefined == 0): assert_equal(0, out.origin)
	wg_value_set(&a, 0, 0, 0)
	wg_value_set(&count, 0, 8, 123)
	assert_equal(0, wg_shift(c, WG_SHL, 1, &a, &count, 2, &out))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)


void check_word_values():
	wg_context* c = context(1, 1, 0)
	wg_value a
	wg_value b
	wg_value out
	wg_value_set(&a, -1, -1, 111)
	wg_value_set(&b, 0, 0, 0)
	assert1(wg_binary(c, WG_AND, __word_size__, &a, &b, &out))
	assert_equal(0, out.undefined)
	assert_equal(0, out.origin)
	wg_value_set(&b, -1, 0, 0)
	assert1(wg_binary(c, WG_OR, __word_size__, &a, &b, &a))
	assert_equal(0, a.undefined)
	assert_equal(-1, a.value)
	int top = 1 << (__word_size__ * 8 - 1)
	wg_value_set(&a, top, top, 222)
	wg_value_set(&b, __word_size__ * 8 - 1, 0, 0)
	assert1(wg_shift(c, WG_SHR, __word_size__, &a, &b, 1, &out))
	assert_equal(1, out.value)
	assert_equal(1, out.undefined)
	assert1(wg_shift(c, WG_SAR, __word_size__, &a, &b, 2, &out))
	assert_equal(-1, out.value)
	assert_equal(-1, out.undefined)
	wg_value_set(&b, 1, 0, 0)
	assert1(wg_shift(c, WG_SHL, __word_size__, &a, &b, 3, &out))
	assert_equal(0, out.undefined)
	assert_equal(0, out.origin)
	wg_value_set(&a, 128, 128, 333)
	assert1(wg_shift(c, WG_SAR, 1, &a, &b, 4, &out))
	assert_equal(192, out.undefined)
	wg_value_set(&a, 1, 128, 333)
	assert1(wg_nonzero(c, 1, &a, &out))
	assert_equal(0, out.undefined)
	assert_equal(1, out.value)
	wg_value_set(&a, 0, 128, 333)
	assert1(wg_nonzero(c, 1, &a, &out))
	assert_equal(1, out.undefined)
	wg_value_set(&b, 1, 1, 444)
	assert1(wg_shift(c, WG_SHL, 1, &a, &b, 5, &out))
	assert_equal(128, out.undefined)
	assert_equal(0, c.error)
	wg_value_set(&a, 0, 0, 0)
	assert1(wg_shift(c, WG_SHL, 1, &a, &b, 6, &out))
	assert_equal(0, out.undefined)
	assert_equal(0, out.origin)
	wg_value_set(&a, 1, 0, 0)
	assert1(wg_shift(c, WG_SHL, 1, &a, &b, 7, &out))
	assert_equal(3, out.undefined)
	assert_equal(0, wg_use(c, &out, 8))
	assert_equal(WG_UNDEFINED, c.error)
	assert_equal(444, c.error_origin)
	wg_clear_error(c)
	assert_equal(0, wg_binary(c, 999, 1, &a, &b, &out))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)


void check_register_aliases():
	wg_context* c = context(4, 8, 2)
	wg_registers first
	wg_registers second
	wg_registers_init(&first, 111)
	wg_registers_init(&second, 222)
	wg_value value
	wg_value out
	assert1(wg_register_read(c, &first, 0, 0, __word_size__, 1, &out))
	assert_equal(-1, out.undefined)
	assert_equal(111, out.origin)
	wg_value_set(&value, 0x12, 0, 0)
	assert1(wg_register_write(c, &first, 0, 0, 1, 0, 2, &value))
	assert1(wg_register_read(c, &first, 0, 0, __word_size__, 3, &out))
	assert_equal(0x12, out.value)
	assert_equal(~255, out.undefined)
	wg_value_set(&value, 0x34, 0x80, 333)
	assert1(wg_register_write(c, &first, 0, 1, 1, 0, 4, &value))
	assert1(wg_register_read(c, &first, 0, 0, 2, 5, &out))
	assert_equal(0x3412, out.value)
	assert_equal(0x8000, out.undefined)
	assert_equal(333, out.origin)
	assert1(wg_register_read(c, &first, 0, 2, 1, 6, &out))
	assert_equal(255, out.undefined)
	assert_equal(111, out.origin)
	assert1(wg_register_read(c, &second, 0, 0, 1, 7, &out))
	assert_equal(255, out.undefined)
	assert_equal(222, out.origin)
	assert1(wg_register_read(c, &first, 15, 0, 1, 8, &out))
	assert_equal(111, out.origin)
	# EAX-style writes clear upper bits; byte/word writes above did not.
	wg_value_set(&value, -1, 1, 444)
	assert1(wg_register_write(c, &first, 0, 0, 4, 1, 9, &value))
	assert1(wg_register_read(c, &first, 0, 0, __word_size__, 10, &out))
	assert_equal(wg_mask(4), out.value)
	assert_equal(1, out.undefined)
	assert_equal(444, out.origin)
	if (__word_size__ == 8):
		assert1(wg_register_read(c, &first, 0, 4, 4, 11, &out))
		assert_equal(0, out.value)
		assert_equal(0, out.undefined)
		assert_equal(0, out.origin)
	assert_equal(0, wg_register_write(c, &first, 0, 1, 1, 1, 12, &value))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_clear_error(c)
	assert_equal(0, wg_register_read(c, &first, 0, 0, 1, 13, &out))
	wg_destroy(c)
	c = context(4, 8, 2)
	assert_equal(0, wg_register_read(c, &first, 16, 0, 1, 14, &out))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)
	c = context(4, 8, 2)
	assert_equal(0, wg_register_read(c, &first, 0, __word_size__, 1, 15, &out))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)


void check_calloc_and_attribution():
	wg_context* c = context(4, 8, 4)
	assert1(wg_callocate(c, 65536, 4, 8, 111))
	wg_value value
	assert1(wg_load(c, 65536, __word_size__, 1, &value))
	assert_equal(0, value.undefined)
	assert_equal(32, c.live_bytes)
	assert_equal(0, wg_access(c, 0, 1, WG_READ, 2))
	assert_equal(0, c.error_allocation)
	wg_clear_error(c)
	assert_equal(0, wg_access(c, 65536 + 32 + 64, 1, WG_WRITE, 3))
	assert_equal(0, c.error_allocation)
	wg_clear_error(c)
	assert1(wg_deallocate(c, 65536, 4))
	# Reuse only a portion of a prior freed object's address range.
	assert1(wg_allocate(c, 65544, 8, 0, 222))
	assert1(wg_mark(c, 65544, 8, WG_READ, 255, 222))
	assert_equal(0, wg_access(c, 65544, 1, WG_WRITE, 5))
	assert_equal(222, c.error_allocation)
	assert_equal(0, c.error_free)
	wg_clear_error(c)
	assert1(wg_deallocate(c, 65544, 6))
	assert_equal(0, wg_access(c, 65545, 1, WG_READ, 7))
	assert_equal(222, c.error_allocation)
	assert_equal(6, c.error_free)
	assert_equal(1, c.error_offset)
	wg_clear_error(c)
	int maximum = ~(1 << (__word_size__ * 8 - 1))
	assert1(wg_callocate(c, 0, maximum, 2, 7)) # failed allocator event
	assert_equal(0, wg_callocate(c, 131072, maximum, 2, 8))
	assert_equal(WG_INCOMPLETE, c.error)
	assert_equal(0, c.live_bytes)
	wg_destroy(c)


int main():
	check_access_and_origins()
	check_copies_and_realloc()
	check_kernel_boundaries()
	check_recycling_and_tree()
	check_limits_and_ranges()
	check_value_oracle()
	check_word_values()
	check_shift_oracle()
	check_register_aliases()
	check_calloc_and_attribution()
	println(c"wgrind_shadow_test: OK")
	return 0
