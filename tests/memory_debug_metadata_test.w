# wbuild: x64
# wbuild: step="bin/wv2 tests/memory_debug_snapshot_fixture.w -o bin/memory_debug_snapshot_fixture"
# wbuild: step="bin/memory_debug_snapshot_fixture" env="W_TEST_LEAKS=1" expect_fail expect_stdout="LEAK: 'test_reused_slot_leak()' returned with 1 heap block(s), 37 byte(s)" expect_stdout="Summary: 1 passed, 1 failed"
# wbuild: step="bin/wv2 x64 tests/memory_debug_snapshot_fixture.w -o bin/memory_debug_snapshot_fixture_x64"
# wbuild: step="bin/memory_debug_snapshot_fixture_x64" env="W_TEST_LEAKS=1" expect_fail expect_stdout="LEAK: 'test_reused_slot_leak()' returned with 1 heap block(s), 37 byte(s)" expect_stdout="Summary: 1 passed, 1 failed"
# wbuild: step="bin/wv2 tests/memory_debug_metadata_fault_fixture.w -o bin/memory_debug_metadata_fault_fixture"
# wbuild: step="bin/memory_debug_metadata_fault_fixture protect" expect_status=1 expect_stderr="memory_debug: cannot protect freed allocation"
# wbuild: step="bin/memory_debug_metadata_fault_fixture release" expect_status=1 expect_stderr="memory_debug: quarantine release failed"
# wbuild: step="bin/memory_debug_metadata_fault_fixture sequence" expect_status=1 expect_stderr="memory_debug: allocation sequence exhausted"
# wbuild: step="bin/wv2 x64 tests/memory_debug_metadata_fault_fixture.w -o bin/memory_debug_metadata_fault_fixture_x64"
# wbuild: step="bin/memory_debug_metadata_fault_fixture_x64 protect" expect_status=1 expect_stderr="memory_debug: cannot protect freed allocation"
# wbuild: step="bin/memory_debug_metadata_fault_fixture_x64 release" expect_status=1 expect_stderr="memory_debug: quarantine release failed"
# wbuild: step="bin/memory_debug_metadata_fault_fixture_x64 sequence" expect_status=1 expect_stderr="memory_debug: allocation sequence exhausted"
import lib.lib
import lib.assert


int main():
	malloc_force_debug_mode()
	# Previously, draining newer frees advanced the allocation-order
	# cursor past this live block. Its eventual free was never reclaimed.
	char* oldest = cast(char*, malloc(19))
	char* newer = cast(char*, malloc(23))
	free(newer)
	debug_quarantine_reclaim_to(0)
	oldest[18] = 7
	assert_equal(7, oldest[18])
	free(oldest)
	debug_quarantine_reclaim_to(0)
	assert_equal(0, debug_quarantine_bytes)
	assert_equal(0, debug_quarantine_head)
	assert_equal(0, debug_quarantine_tail)

	# Keep older live pointers in the index while slots and addresses
	# around them are repeatedly recycled. Include a table growth with
	# live, quarantined and reusable slots present.
	int[5000] live
	for i in range(5000):
		live[i] = cast(int, malloc(17))
		char* block = cast(char*, live[i])
		block[16] = i & 127
	int capacity = debug_tbl_capacity
	for round in range(6):
		for i in range(12000):
			char* p = cast(char*, malloc(13))
			p[12] = 9
			free(p)
			if (i % 31 == 0): debug_quarantine_reclaim_to(0)
		debug_quarantine_reclaim_to(0)
		assert_equal(capacity, debug_tbl_capacity)
		assert_equal(0, debug_quarantine_bytes)
		for i in range(5000):
			assert1(debug_tbl_find(live[i]) >= 0)
			char* block = cast(char*, live[i])
			assert_equal(i & 127, block[16])
	# Deliberately free in a different order from allocation.
	for i in range(2500): free(cast(void*, live[i * 2 + 1]))
	debug_quarantine_reclaim_to(0)
	for i in range(2500): free(cast(void*, live[i * 2]))
	debug_quarantine_reclaim_to(0)
	assert_equal(0, debug_quarantine_bytes)
	assert_equal(0, debug_alloc_report_leaks())
	println(c"memory_debug_metadata_test: OK")
	return 0
