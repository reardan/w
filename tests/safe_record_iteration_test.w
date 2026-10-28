# wbuild: x64
# wbuild: deps=lib/safe_vector.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int record_iteration_case_number


void record_iteration_result(process_result* result, char* diagnostic, int checking, char* path):
	assert1(result != 0)
	char* message = result.stderr_text
	if (checking): message = result.stdout_text
	if (diagnostic == 0):
		if (result.status):
			print(path)
			print(message)
		assert_equal(0, result.status)
	else:
		if ((result.status != 1) || (assert_has(message, diagnostic) == 0)):
			print(path)
			print(message)
		assert_equal(1, result.status)
		assert_contains(message, diagnostic)


void record_iteration_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	record_iteration_case_number = record_iteration_case_number + 1
	char* number = itoa(record_iteration_case_number)
	char* prefix = c"bin/record_iteration_case32_"
	if (__word_size__ == 8): prefix = c"bin/record_iteration_case64_"
	char* path = strjoin(prefix, number)
	free(number)
	if (seed >= 0):
		char* seed_number = itoa(seed)
		char* tagged = strjoin(path, c"_seed_")
		free(path)
		path = strjoin(tagged, seed_number)
		free(tagged)
		free(seed_number)
	char* full = strjoin(path, c".w")
	free(path)
	char* output = strjoin(full, c".out")
	assert1(file_write_text(full, source))
	for mode in range(2):
		if (mode && explicit_safe_diagnostic): diagnostic = explicit_safe_diagnostic
		unlink(output)
		char** checking = strv_new(7 + mode)
		strv_set(checking, 0, c"bin/wv2")
		strv_set(checking, 1, c"check")
		strv_set(checking, 2, c"--json")
		strv_set(checking, 3, c"--quiet")
		strv_set(checking, 4, c"--strict")
		if (relaxed): strv_set(checking, 4, c"--quiet")
		strv_set(checking, 5, c"--quiet")
		if (__word_size__ == 8): strv_set(checking, 5, c"x64")
		strv_set(checking, 6, full)
		if (mode): strv_set(checking, 7, c"--safe")
		process_result* checked = process_run(checking[0], checking, 0, 0, 30000)
		record_iteration_result(checked, diagnostic, 1, full)
		process_result_free(checked)
		free(cast(void*, checking))
		char** compiling = strv_new(8 + mode)
		strv_set(compiling, 0, c"bin/wv2")
		strv_set(compiling, 1, c"--quiet")
		strv_set(compiling, 2, c"--strict")
		if (relaxed): strv_set(compiling, 2, c"--quiet")
		strv_set(compiling, 3, c"--quiet")
		if (__word_size__ == 8): strv_set(compiling, 3, c"x64")
		strv_set(compiling, 4, c"--inline")
		strv_set(compiling, 5, full)
		strv_set(compiling, 6, c"-o")
		strv_set(compiling, 7, output)
		if (mode): strv_set(compiling, 8, c"--safe")
		process_result* compiled = process_run(compiling[0], compiling, 0, 0, 30000)
		record_iteration_result(compiled, diagnostic, 0, full)
		process_result_free(compiled)
		free(cast(void*, compiling))
		if (diagnostic):
			assert1(open(output, 0, 0) < 0)
		else:
			char** run = strv_new(1)
			strv_set(run, 0, output)
			process_result* executed = process_run(output, run, 0, 0, 30000)
			assert1(executed != 0)
			if (runtime_diagnostic):
				assert_equal(1, executed.status)
				assert_contains(executed.stderr_text, runtime_diagnostic)
			else: assert_equal(0, executed.status)
			process_result_free(executed)
			free(cast(void*, run))
		unlink(output)
	unlink(full)
	free(output)
	free(full)

void test_record_iteration_0():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tint total = 0\n\tfor item in buffer_view[Pair](values): total += item.left + item.right\n\treturn total - 17\n", 0, 0)

void test_record_iteration_1():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tint total = 0\n\tfor ref Pair* item in buffer_view[Pair](values): total += item.right\n\treturn total - 10\n", 0, 0)

void test_record_iteration_2():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tint total = 0\n\tref Pair[] view = buffer_view[Pair](values)\n\tfor item in view[1:]: total += item.left\n\treturn total - 5\n", 0, 0)

void test_record_iteration_3():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor item in buffer_view[Pair](values): item.left = 1\n\treturn 0\n", c"shared reference", 0)

void test_record_iteration_4():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor item in buffer_view[Pair](values): buffer_clear[Pair](values)\n\treturn 0\n", c"borrow", 0)

void test_record_iteration_5():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor item in buffer_view[Pair](values):\n\t\tbuffer_clear[Pair](values)\n\t\treturn item.left\n\treturn 0\n", c"borrow", 0)

void test_record_iteration_6():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor item in buffer_view[Pair](values):\n\t\tbuffer_clear[Pair](values)\n\t\tbreak\n\treturn 0\n", 0, 0)

void test_record_iteration_7():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor item in buffer_view[Pair](values): pass\n\treturn item.left\n", c"uninitialized", 0)

void test_record_iteration_8():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tfor item in buffer_view[Pair](values): pass\n\treturn item.left\n", c"uninitialized", 0)

void test_record_iteration_9():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tint total = 0\n\tfor item in buffer_view[Pair](values):\n\t\tfor other in buffer_view[Pair](values): total += item.left * other.left\n\treturn total - 49\n", 0, 0)

void test_record_iteration_10():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\toptref Pair* saved = 0\n\tfor item in buffer_view[Pair](values):\n\t\tif saved: saved = item\n\t\telse: saved = item\n\tif saved: return saved.left - 5\n\treturn 1\n", 0, 0)

void test_record_iteration_11():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\toptref Pair* saved = 0\n\tfor item in buffer_view[Pair](values): saved = item\n\tbuffer_clear[Pair](values)\n\tif saved: return saved.left\n\treturn 0\n", c"borrow", 0)

void test_record_iteration_12():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tint total = 0\n\tfor item in buffer_view[Pair](values):\n\t\tref int* field = &item.left\n\t\ttotal += *field\n\treturn total - 7\n", 0, 0)

void test_record_iteration_13():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor refmut Pair* item in buffer_view[Pair](values): pass\n\treturn 0\n", c"shared reference variable", 0)

void test_record_iteration_14():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor Pair* item in buffer_view[Pair](values): pass\n\treturn 0\n", c"shared reference variable", 0)

void test_record_iteration_15():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor ref int* item in buffer_view[Pair](values): pass\n\treturn 0\n", c"incompatible record slice", 0)

void test_record_iteration_16():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor item in buffer_view_mut[Pair](values): pass\n\treturn 0\n", c"checked shared slice", 0)

void test_record_iteration_17():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nref[a] Pair* first(ref[a] Pair[] view, ref[a] WBuffer[Pair]* fallback):\n\tfor item in view: return item\n\tref Pair[] backup = buffer_view[Pair](fallback)\n\treturn &backup[0]\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tref Pair* found = first(buffer_view[Pair](values), values)\n\treturn found.left - 2\n", 0, 0)

void test_record_iteration_18():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nref Pair* bad(ref Pair* fallback):\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor item in buffer_view[Pair](values): return item\n\treturn fallback\nint main():\n\treturn 0\n", c"returned reference", 0)

void test_record_iteration_19():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tint total = 0\n\tfor item in buffer_view[Pair](values):\n\t\tdefer: total += item.left\n\t\tif item.left == 2: continue\n\t\tbreak\n\treturn total - 7\n", 0, 0)

void test_record_iteration_20():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nref[a] T[] tail[T](ref[a] T[] view):\n\treturn view[1:]\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tint total = 0\n\tfor item in tail[Pair](buffer_view[Pair](values)): total += item.right\n\treturn total - 7\n", 0, 0)

void test_record_iteration_21():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor item in buffer_view[Pair](values):\n\t\town WBuffer[Pair]* moved = values\n\treturn 0\n", c"safe:", 0)

void test_record_iteration_22():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor item in buffer_view[Pair](values):\n\t\trefmut Pair* mutable = item\n\treturn 0\n", c"safe:", 0)

void test_record_iteration_23():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tint total = 0\n\tfor item in buffer_view[Pair](values):\n\t\tref Pair* same = item\n\t\ttotal += same.right\n\tbuffer_clear[Pair](values)\n\treturn total - 10\n", 0, 0)

void test_record_iteration_24():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tref Pair[] view = buffer_view[Pair](values)\n\tfor item in view:\n\t\tif item.left == 2: continue\n\t\tbuffer_clear[Pair](values)\n\treturn 0\n", c"borrow", 0)

void test_record_iteration_25():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tint total = 0\n\tfor item in buffer_view[Pair](values):\n\t\tswitch item.left:\n\t\t\tcase 2: continue\n\t\t\tdefault: total += item.right\n\treturn total - 7\n", 0, 0)

void test_record_iteration_26():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nstruct Holder:\n\tref[a] Pair[] items\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tint total = 0\n\tref[a] Holder holder = Holder(buffer_view[Pair](values))\n\tfor item in holder.items: total += item.left\n\treturn total - 7\n", 0, 0)

void test_record_iteration_27():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor item in buffer_view[Pair](values):\n\t\titem = &buffer_view[Pair](values)[0]\n\treturn 0\n", c"references cannot be reassigned", 0)

void test_record_iteration_28():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tref Pair[] view = buffer_view[Pair](values)\n\toptref int* saved = 0\n\tfor item in view: saved = &item.left\n\tif saved: return *saved - 5\n\treturn 1\n", 0, 0)

void test_record_iteration_29():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tref Pair[] view = buffer_view[Pair](values)\n\toptref int* saved = 0\n\tfor item in view: saved = &item.left\n\tbuffer_clear[Pair](values)\n\tif saved: return *saved\n\treturn 0\n", c"borrow", 0)

void test_record_iteration_30():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tref Pair[] view = buffer_view[Pair](values)\n\tfor item in view:\n\t\tbuffer_push[Pair](values, Pair(1, 1))\n\t\tbreak\n\treturn 0\n", 0, 0)

void test_record_iteration_31():
	record_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tref Pair[] view = buffer_view[Pair](values)\n\tfor item in view:\n\t\tbuffer_push[Pair](values, Pair(1, 1))\n\t\treturn item.left\n\treturn 0\n", c"borrow", 0)
