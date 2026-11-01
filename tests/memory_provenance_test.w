# wbuild: x64
# wbuild: step="bin/wv2 --strict tests/memory_provenance_fault_fixture.w -o bin/memory_provenance_fault"
# wbuild: step="bin/memory_provenance_fault null" expect_fail expect_stderr="foreign owner: non-null result is null"
# wbuild: step="bin/memory_provenance_fault interior" expect_fail expect_stderr="foreign owner: result is not a live W allocation of the required size"
# wbuild: step="bin/memory_provenance_fault freed" expect_fail expect_stderr="foreign owner: result is not a live W allocation of the required size"
# wbuild: step="bin/memory_provenance_fault undersized" expect_fail expect_stderr="foreign owner: result is not a live W allocation of the required size"
# wbuild: step="bin/memory_provenance_fault unknown" expect_fail expect_stderr="foreign owner: result is not a live W allocation of the required size"
# wbuild: step="bin/memory_provenance_fault sentinel" expect_fail expect_stderr="foreign owner: result is not a live W allocation of the required size"
# wbuild: step="bin/memory_provenance_fault record" expect_fail expect_stderr="foreign provenance: invalid allocation address"
# wbuild: step="bin/memory_provenance_fault misaligned" expect_fail expect_stderr="foreign owner: result is misaligned"
# wbuild: step="bin/wv2 x64 --strict tests/memory_provenance_fault_fixture.w -o bin/memory_provenance_fault64"
# wbuild: step="bin/memory_provenance_fault64 null" expect_fail expect_stderr="foreign owner: non-null result is null"
# wbuild: step="bin/memory_provenance_fault64 interior" expect_fail expect_stderr="foreign owner: result is not a live W allocation of the required size"
# wbuild: step="bin/memory_provenance_fault64 freed" expect_fail expect_stderr="foreign owner: result is not a live W allocation of the required size"
# wbuild: step="bin/memory_provenance_fault64 undersized" expect_fail expect_stderr="foreign owner: result is not a live W allocation of the required size"
# wbuild: step="bin/memory_provenance_fault64 unknown" expect_fail expect_stderr="foreign owner: result is not a live W allocation of the required size"
# wbuild: step="bin/memory_provenance_fault64 sentinel" expect_fail expect_stderr="foreign owner: result is not a live W allocation of the required size"
# wbuild: step="bin/memory_provenance_fault64 record" expect_fail expect_stderr="foreign provenance: invalid allocation address"
# wbuild: step="bin/memory_provenance_fault64 misaligned" expect_fail expect_stderr="foreign owner: result is misaligned"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/memory_provenance_test"
# wbuild: step="bin/wv2 x64 --strict tests/memory_provenance_test.w -o bin/memory_provenance_debug64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/memory_provenance_debug64"
import lib.assert
import lib.memory


char* provenance_refuse_realloc(void* old, int oldlen, int newlen):
	return cast(char*, 0)


void provenance_allocations():
	char* initial = cast(char*, malloc(13))
	assert_equal(13, malloc_provenance_size(initial))
	assert_equal(-1, malloc_provenance_size(initial + 1))
	initial[0] = 71
	initial[12] = 73
	assert_equal(cast(int, initial), cast(int, __w_foreign_owner_check(initial, 13, 0)))
	char* grown = realloc(initial, 13, 4096)
	asserts(c"realloc returns storage", grown != 0)
	assert_equal(4096, malloc_provenance_size(grown))
	if (initial != grown): assert_equal(-1, malloc_provenance_size(initial))
	assert_equal(71, cast(int, grown[0]))
	assert_equal(73, cast(int, grown[12]))
	char* shrunk = realloc(grown, 4096, 7)
	assert_equal(7, malloc_provenance_size(shrunk))
	assert_equal(71, cast(int, shrunk[0]))
	if (grown != shrunk): assert_equal(-1, malloc_provenance_size(grown))

	# A backend failure must restore the original requested size and liveness.
	int previous = malloc_hook_realloc
	malloc_hook_realloc = cast(int, provenance_refuse_realloc)
	assert_equal(0, cast(int, realloc(shrunk, 7, 8192)))
	malloc_hook_realloc = previous
	assert_equal(7, malloc_provenance_size(shrunk))
	assert_equal(cast(int, shrunk), cast(int, __w_foreign_owner_check(shrunk, 7, 0)))
	free(shrunk)
	assert_equal(-1, malloc_provenance_size(shrunk))

	char* from_null = realloc(cast(void*, 0), 0, 32)
	assert_equal(32, malloc_provenance_size(from_null))
	free(from_null)
	void* zero = malloc(0)
	asserts(c"malloc zero returns storage", zero != 0)
	assert_equal(0, malloc_provenance_size(zero))
	free(zero)
	assert_equal(0, cast(int, __w_foreign_owner_check(cast(void*, 0), 8, 1)))
	assert_equal(-1, malloc_provenance_size(cast(void*, 0)))


void provenance_growth_and_tombstones():
	void*[2050] live
	for i in range(2050):
		live[i] = malloc(i % 31 + 1)
	asserts(c"registry grew", malloc_provenance_capacity >= 4096)
	for i in range(2050):
		assert_equal(i % 31 + 1, malloc_provenance_size(live[i]))
		free(live[i])
		assert_equal(-1, malloc_provenance_size(live[i]))
	assert_equal(0, malloc_provenance_live)
	int capacity = malloc_provenance_capacity

	# Synthetic distinct addresses exercise probing without dereferencing any
	# candidate address. Only allocator bookkeeping is called on these values.
	for i in range(20000):
		void* address = cast(void*, 4096 + i * 64)
		malloc_provenance_record(address, i + 1)
		assert_equal(i + 1, malloc_provenance_size(address))
		malloc_provenance_record(address, i + 2)
		assert_equal(1, malloc_provenance_live)
		assert_equal(i + 2, malloc_provenance_size(address))
		malloc_provenance_forget(address)
		malloc_provenance_forget(address)
		assert_equal(0, malloc_provenance_live)
		assert_equal(-1, malloc_provenance_size(address))
		# Sentinel values must not see stale tombstone sizes or decrement live.
		malloc_provenance_forget(cast(void*, 1))
		assert_equal(-1, malloc_provenance_size(cast(void*, 1)))
		assert_equal(0, malloc_provenance_live)
	assert_equal(capacity, malloc_provenance_capacity)


void provenance_reuse_and_duplicates():
	# Same-address churn must reuse one tombstone, not accumulate a cluster.
	void* address = cast(void*, 65536)
	malloc_provenance_record(address, 8)
	malloc_provenance_forget(address)
	int used = malloc_provenance_used
	int capacity = malloc_provenance_capacity
	for i in range(10000):
		malloc_provenance_record(address, 8)
		assert_equal(1, malloc_provenance_live)
		malloc_provenance_forget(address)
	assert_equal(used, malloc_provenance_used)
	assert_equal(capacity, malloc_provenance_capacity)

	# Build two addresses with one hash. Removing the first leaves a
	# tombstone before the second; updating the second must find its live
	# entry rather than creating a duplicate in the tombstone.
	int first = 131072
	int hash = ((first >> 3) ^ (first >> 17)) & (capacity - 1)
	int second = first + 8
	while ((((second >> 3) ^ (second >> 17)) & (capacity - 1)) != hash): second += 8
	malloc_provenance_record(cast(void*, first), 13)
	malloc_provenance_record(cast(void*, second), 17)
	malloc_provenance_forget(cast(void*, first))
	malloc_provenance_record(cast(void*, second), 23)
	assert_equal(1, malloc_provenance_live)
	assert_equal(23, malloc_provenance_size(cast(void*, second)))
	malloc_provenance_forget(cast(void*, second))
	assert_equal(-1, malloc_provenance_size(cast(void*, second)))
	assert_equal(0, malloc_provenance_live)


int main():
	# Normal programs opt out, including arbitrary unchecked pointer values.
	assert_equal(0, malloc_provenance_enabled)
	assert_equal(123, cast(int, __w_foreign_owner_check(cast(void*, 123), 8, 0)))
	malloc_provenance_enabled = 1
	provenance_allocations()
	provenance_growth_and_tombstones()
	provenance_reuse_and_duplicates()
	assert_equal(0, malloc_provenance_live)
	return 0
