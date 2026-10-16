# Runtime cases for tools/wgrind_test.w, intentionally invalid accesses.
import lib.lib
import lib.assert


int main(int argc, char** argv):
	if (argc < 2): return 2
	char* mode = argv[1]
	if (strcmp(mode, c"forced_uninitialized") == 0): malloc_force_debug_mode()
	char* p = cast(char*, malloc(13))
	if (strcmp(mode, c"underflow") == 0):
		p[-1] = 1
	elif (strcmp(mode, c"underflow_realloc") == 0):
		p[-16] = 1
		p = realloc(p, 13, 20)
	elif (strcmp(mode, c"underflow_report") == 0):
		p[-1] = 1
		debug_alloc_report_leaks()
	elif (strcmp(mode, c"overflow") == 0):
		p[13] = 1
	elif (strcmp(mode, c"underflow_read") == 0):
		if (p[-1] == 42): println(c"invalid")
	elif ((strcmp(mode, c"uninitialized") == 0) || (strcmp(mode, c"forced_uninitialized") == 0)):
		if (p[0] == 42): println(c"undefined")
	elif (strcmp(mode, c"reused_uninitialized") == 0):
		for i in range(13): p[i] = 42
		free(p)
		p = cast(char*, malloc(13))
		if (p[0] == 42): println(c"undefined")
	elif (strcmp(mode, c"uaf") == 0):
		free(p)
		p[0] = 1
		return 0
	elif (strcmp(mode, c"leak") == 0):
		return 0
	elif (strcmp(mode, c"realloc_undefined") == 0):
		p[0] = 7
		p = realloc(p, 13, 40)
		if (p[12] == 42): println(c"undefined")
		free(p)
		return 0
	elif (strcmp(mode, c"realloc_tail") == 0):
		for i in range(13): p[i] = 7
		p = realloc(p, 13, 40)
		if (p[13] == 42): println(c"undefined")
		free(p)
		return 0
	elif (strcmp(mode, c"clean") == 0):
		for i in range(13): p[i] = i
		p = realloc(p, 13, 40)
		for i in range(13): assert_equal(i, p[i])
		p = realloc(p, 40, 5)
		assert_equal(4, p[4])
	elif (strcmp(mode, c"churn") == 0):
		# Recycle and split poisoned blocks, then allocate many live
		# blocks and free oldest-first (the old lookup was quadratic).
		for round in range(100):
			char* big = cast(char*, malloc(8000))
			free(big)
			char* small = cast(char*, malloc(33))
			small[32] = 7
			free(small)
		int[18000] blocks
		for i in range(9000): blocks[i] = cast(int, malloc(16))
		int before = debug_tbl_probes
		for i in range(9000): free(cast(void*, blocks[i]))
		asserts(c"indexed lookup stays near linear", debug_tbl_probes - before < 90000)
		if (vg_active):
			assert_equal(0, debug_quarantine_bytes)
			assert_equal(4096, debug_history_count)
			int capacity = debug_tbl_capacity
			for round in range(3):
				for i in range(9000): blocks[i] = cast(int, malloc(16))
				for i in range(9000): free(cast(void*, blocks[i]))
				assert_equal(capacity, debug_tbl_capacity)
			# Force index growth after slots and addresses have been reused;
			# the newest allocation may now occupy a lower-numbered slot.
			for i in range(18000): blocks[i] = cast(int, malloc(16))
			for i in range(18000): free(cast(void*, blocks[i]))
			asserts(c"pooled allocations use less than two MiB", malloc_heap_total < 2097152)
		char* empty = realloc(0, 17, 12)
		free(empty)
		assert1(malloc(-1) == 0)
		assert1(realloc(p, 13, -1) == 0)
	elif (strcmp(mode, c"double_free") == 0):
		free(p)
		free(p)
	elif (strcmp(mode, c"bad_oldlen") == 0):
		p = realloc(p, 12, 32)
	elif (strcmp(mode, c"status") == 0):
		free(p)
		return 7
	elif (strcmp(mode, c"argument with spaces") == 0):
		println(c"argument preserved")
	else: return 2
	free(p)
	return 0
