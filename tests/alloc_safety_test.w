# wbuild: x64
# wbuild: step="bin/alloc_safety_test oom_new" expect_fail expect_stderr="out of memory: allocation of 40 bytes failed"
# wbuild: step="bin/alloc_safety_test oom_array" expect_fail expect_stderr="out of memory: allocation of"
# wbuild: step="bin/alloc_safety_test oom_list" expect_fail expect_stderr="out of memory: allocation of"
# wbuild: step="bin/alloc_safety_test oom_map" expect_fail expect_stderr="out of memory: allocation of"
# wbuild: step="bin/alloc_safety_test oom_grow" expect_fail expect_stderr="out of memory: allocation of"
# wbuild: step="bin/alloc_safety_test list_overflow" expect_fail expect_stderr="allocation size overflow: "
# wbuild: step="bin/alloc_safety_test string_overflow" expect_fail expect_stderr="allocation size overflow: "
# wbuild: step="bin/alloc_safety_test double_free" expect_fail expect_stderr="free(): double free detected"
# wbuild: step="bin/alloc_safety_test bad_free" expect_fail expect_stderr="free(): invalid pointer (not a heap block)"
# wbuild: step="bin/alloc_safety_test debug" env="W_DEBUG_ALLOC=1" expect_stdout="debug allocator ok"
# wbuild: step="bin/alloc_safety_test debug_slack" env="W_DEBUG_ALLOC=1" expect_fail expect_stderr="memory_debug: heap buffer overflow"
#
# Issue #530, allocation safety. With no argument this runs the checks
# that succeed in-process; each named scenario is a separate run whose
# expected death (or debug-allocator output) the steps above assert.
# Out of memory is simulated with lib/memory.w's malloc hook returning
# null, which is deterministic where a real memory limit is not.
import lib.lib
import lib.assert
import lib.memory
import structures.string


struct as_record:
	int a
	int b
	int c
	char* name
	int e
	int f
	int g
	int h
	int i
	int j


struct as_pair:
	int left
	int right


int as_failing_malloc(int size):
	return 0


int as_failing_realloc(int old, int oldlen, int newlen):
	return 0


void as_fail_allocations():
	malloc_hook_set(cast(int, as_failing_malloc), 0, cast(int, as_failing_realloc))


int as_ok(char* what):
	print(what)
	println(c" ok")
	return 0


# 'new T' memory is zeroed even when the block was used before.
void as_check_new_zeroed():
	for round in range(3):
		as_record* r = new as_record
		assert_equal(0, r.a)
		assert_equal(0, r.c)
		assert_equal(0, cast(int, r.name))
		assert_equal(0, r.j)
		int* words = cast(int*, r)
		for k in range(sizeof(as_record) / __word_size__): words[k] = 1515870810
		free(r)
	as_pair* s = new as_pair(7, 8)
	assert_equal(7, s.left)
	assert_equal(8, s.right)
	free(s)
	int[] xs = new int[9]
	for k in range(9): assert_equal(0, xs[k])


void as_check_malloc_sizes():
	assert_equal(0, cast(int, malloc(-1)))
	assert_equal(0, cast(int, malloc(0 - 4096)))
	assert1(malloc(0) != 0)
	char* p = malloc(16)
	p[0] = 'k'
	assert_equal(0, cast(int, realloc(p, 16, -8)))
	assert_equal('k', p[0])
	free(p)
	assert_equal(12, __w_size_mul(3, 4))
	assert_equal(0, __w_size_mul(0, __w_word_max()))
	assert_equal(__w_word_max(), __w_size_add(__w_word_max() - 1, 1))
	assert_equal(32, __w_grow_capacity(16, 17))
	assert_equal(100, __w_grow_capacity(16, 100))
	assert_equal(__w_word_max(), __w_grow_capacity(__w_word_max() - 3, __w_word_max()))


void as_check_containers_still_grow():
	list[int] l = new list[int]
	for k in range(5000): l.push(k)
	assert_equal(4999, l[4999])
	map[int, int] m = new map[int, int]
	for k in range(5000): m[k] = k * 2
	assert_equal(9998, m[4999])
	string_builder* sb = string_new()
	for k in range(5000): string_append(sb, c"ab")
	assert_equal(10000, sb.length)


int as_debug_allocator():
	# malloc(13) used to come back 3 mod 8 under W_DEBUG_ALLOC.
	for size in range(1, 40):
		char* p = malloc(size)
		assert_equal(0, cast(int, p) & 7)
		for k in range(size): p[k] = k
		free(p)
	# Shrinking realloc used to copy oldlen bytes into the smaller block
	# and fault on its guard page.
	char* big = malloc(5000)
	for k in range(5000): big[k] = k % 100
	char* small = realloc(big, 5000, 10)
	for k in range(10): assert_equal(k, small[k])
	char* grown = realloc(small, 10, 9000)
	for k in range(10): assert_equal(k, grown[k])
	free(grown)
	println(c"debug allocator ok")
	return 0


int main(int argc, char** argv):
	if (argc < 2):
		as_check_new_zeroed()
		as_check_malloc_sizes()
		as_check_containers_still_grow()
		return as_ok(c"alloc safety")
	char* mode = argv[1]
	if (strcmp(mode, c"debug") == 0): return as_debug_allocator()
	if (strcmp(mode, c"debug_slack") == 0):
		char* p = malloc(10)
		p[11] = 1
		free(p)
		return 0
	if (strcmp(mode, c"double_free") == 0):
		char* q = malloc(24)
		free(q)
		free(q)
		return 0
	if (strcmp(mode, c"bad_free") == 0):
		int* fake = malloc(8 * __word_size__)
		fake[0] = 13
		fake[1] = 0
		free(&fake[2])
		return 0
	if (strcmp(mode, c"list_overflow") == 0):
		list[int] l = new list[int]
		l.push(1)
		__w_list_ensure(cast(__w_list*, l), __w_word_max())
		return 0
	if (strcmp(mode, c"string_overflow") == 0):
		string_builder* s = string_new()
		string_append(s, c"x")
		string_reserve(s, __w_word_max() - 1)
		return 0
	if (strcmp(mode, c"oom_grow") == 0):
		list[int] g = new list[int]
		as_fail_allocations()
		for k in range(100): g.push(k)
		return 0
	as_fail_allocations()
	if (strcmp(mode, c"oom_new") == 0):
		as_record* r = new as_record
		r.a = 1
	else if (strcmp(mode, c"oom_array") == 0):
		int[] xs = new int[64]
		xs[0] = 1
	else if (strcmp(mode, c"oom_list") == 0):
		list[int] l2 = new list[int]
		l2.push(1)
	else if (strcmp(mode, c"oom_map") == 0):
		map[int, int] m = new map[int, int]
		m[1] = 1
	return 0
