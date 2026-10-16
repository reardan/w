import lib.testing


void test_recycled_slots_clean():
	char* p = cast(char*, malloc(31))
	free(p)
	debug_quarantine_reclaim_to(0)
	int first = debug_alloc_sequence
	int count = debug_tbl_count
	p = cast(char*, malloc(31))
	assert_equal(count, debug_tbl_count)
	int last = debug_alloc_sequence
	assert_equal(1, testing_live_between(first, last))
	free(p)
	assert_equal(0, testing_live_between(first, last))
	debug_quarantine_reclaim_to(0)
	# A later allocation reuses the slot but is outside the snapshot.
	p = cast(char*, malloc(31))
	assert_equal(0, testing_live_between(first, last))
	free(p)
	debug_quarantine_reclaim_to(0)


void test_reused_slot_leak():
	char* temporary = cast(char*, malloc(7))
	free(temporary)
	debug_quarantine_reclaim_to(0)
	malloc(37)
