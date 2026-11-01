# wbuild: x64
# wbuild: deps=lib/safe_vector.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int slice_iteration_case_number


void slice_iteration_result(process_result* result, char* diagnostic, int checking, char* path):
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


void slice_iteration_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	slice_iteration_case_number = slice_iteration_case_number + 1
	char* number = itoa(slice_iteration_case_number)
	char* prefix = c"bin/slice_iteration_case32_"
	if (__word_size__ == 8): prefix = c"bin/slice_iteration_case64_"
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
		slice_iteration_result(checked, diagnostic, 1, full)
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
		slice_iteration_result(compiled, diagnostic, 0, full)
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

void test_slice_iteration_0():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tint total = 0\n\tfor item in view: total += item\n\treturn total - 10\n", 0, 0)

void test_slice_iteration_1():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tint total = 0\n\tfor int item in buffer_view[int](values): total += item\n\treturn total - 10\n", 0, 0)

void test_slice_iteration_2():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tint total = 0\n\tfor item in buffer_view[int](values): total += item\n\treturn total\n", 0, 0)

void test_slice_iteration_3():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tint total = 0\n\tfor item in view:\n\t\tif item == 2: continue\n\t\tif item == 4: break\n\t\ttotal += item\n\treturn total - 4\n", 0, 0)

void test_slice_iteration_4():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tint total = 0\n\tfor item in view:\n\t\tfor other in view: total += item * other\n\treturn total - 100\n", 0, 0)

void test_slice_iteration_5():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor item in view: buffer_push[int](values, 9)\n\treturn 0\n", c"borrow", 0)

void test_slice_iteration_6():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor item in view: buffer_set[int](values, 0, 9)\n\treturn 0\n", c"borrow", 0)

void test_slice_iteration_7():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor item in view: buffer_clear[int](values)\n\treturn 0\n", c"borrow", 0)

void test_slice_iteration_8():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor item in view: buffer_pop[int](values)\n\treturn 0\n", c"borrow", 0)

void test_slice_iteration_9():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tfor item in buffer_view[int](values): buffer_clear[int](values)\n\treturn 0\n", c"borrow", 0)

void test_slice_iteration_10():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor item in view:\n\t\town WBuffer[int]* moved = values\n\treturn 0\n", c"safe:", 0)

void test_slice_iteration_11():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tint total = 0\n\tfor item in view: total += item\n\tbuffer_clear[int](values)\n\treturn total - 10\n", 0, 0)

void test_slice_iteration_12():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\town WBuffer[int]* other = buffer_new[int]()\n\tbuffer_push[int](other, 99)\n\tint total = 0\n\tfor item in view:\n\t\tview = buffer_view[int](other)\n\t\ttotal += item\n\treturn total - 10\n", c"references cannot be reassigned", 0)

void test_slice_iteration_13():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\town WBuffer[int]* other = buffer_new[int]()\n\tfor item in view:\n\t\tview = buffer_view[int](other)\n\t\tbuffer_clear[int](values)\n\treturn 0\n", c"references cannot be reassigned", 0)

void test_slice_iteration_14():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor item in view:\n\t\titem += 1\n\tbuffer_clear[int](values)\n\treturn 0\n", 0, 0)

void test_slice_iteration_15():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\toptref int* saved = 0\n\tfor item in view: saved = &item\n\tif saved: return *saved\n\treturn 0\n", c"borrow", 0)

void test_slice_iteration_16():
	slice_iteration_case(c"import lib.safe_vector\nref int* bad(ref int[] view):\n\tfor item in view: return &item\n\town int* fallback = new int\n\treturn fallback\nint main():\n\treturn 0\n", c"returned reference", 0)

void test_slice_iteration_17():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tint total = 0\n\tfor item in view:\n\t\town int* local = new int\n\t\t*local = item\n\t\tdefer: total += *local\n\t\tif item == 2: continue\n\t\tif item == 4: break\n\treturn total - 10\n", 0, 0)

void test_slice_iteration_18():
	slice_iteration_case(c"import lib.safe_vector\nint first(ref int[] view):\n\tfor item in view:\n\t\town int* local = new int\n\t\t*local = item\n\t\treturn *local\n\treturn -1\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\treturn first(view) - 1\n", 0, 0)

void test_slice_iteration_19():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\trefmut int[] view = buffer_view_mut[int](values)\n\tfor item in view: pass\n\treturn 0\n", 0, 0)

void test_slice_iteration_20():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tfor item in values: pass\n\treturn 0\n", c"not iterable", 0)

void test_slice_iteration_21():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\tint[3] values\n\tfor item in values: pass\n\town int* owner = new int\n\treturn 0\n", c"checked shared slice", 0)

void test_slice_iteration_22():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tref int[] view = values\n\tint total = 0\n\tfor item in view: total += item\n\treturn total - 7\n", 0, 0)

void test_slice_iteration_23():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[byte]* values = buffer_new[byte]()\n\tbuffer_push[byte](values, cast(byte, 7))\n\tint total = 0\n\tfor item in buffer_view[byte](values): total += cast(int, item)\n\treturn total - cast(int, cast(byte, 7))\n", 0, 0)

void test_slice_iteration_24():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[char]* values = buffer_new[char]()\n\tbuffer_push[char](values, 'a')\n\tint total = 0\n\tfor item in buffer_view[char](values): total += cast(int, item)\n\treturn total - cast(int, 'a')\n", 0, 0)

void test_slice_iteration_25():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[uint]* values = buffer_new[uint]()\n\tbuffer_push[uint](values, cast(uint, 7))\n\tint total = 0\n\tfor item in buffer_view[uint](values): total += cast(int, item)\n\treturn total - cast(int, cast(uint, 7))\n", 0, 0)

void test_slice_iteration_26():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[bool]* values = buffer_new[bool]()\n\tbuffer_push[bool](values, true)\n\tint total = 0\n\tfor item in buffer_view[bool](values): total += cast(int, item)\n\treturn total - cast(int, true)\n", 0, 0)

void test_slice_iteration_27():
	slice_iteration_case(c"import lib.safe_vector\nenum Item:\n\tone\n\ttwo\nint main():\n\town WBuffer[Item]* values = buffer_new[Item]()\n\tbuffer_push[Item](values, cast(Item, 1))\n\tint total = 0\n\tfor item in buffer_view[Item](values): total += cast(int, item)\n\treturn total - 1\n", 0, 0)

void test_slice_iteration_28():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[float32]* values = buffer_new[float32]()\n\tbuffer_push[float32](values, cast(float32, 1.5))\n\tfloat32 total = cast(float32, 0)\n\tfor item in buffer_view[float32](values): total += item\n\treturn total != cast(float32, 1.5)\n", 0, 0)

void test_slice_iteration_29():
	slice_iteration_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tfor item in buffer_view[Pair](values): pass\n\treturn 0\n", 0, 0)

void test_slice_iteration_30():
	slice_iteration_case(c"import lib.safe_vector\nref[a] int[] counted(ref[a] WBuffer[int]* values, refmut int* calls):\n\t*calls += 1\n\treturn buffer_view[int](values)\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\town int* calls = new int\n\tint total = 0\n\tfor item in counted(values, calls): total += item\n\treturn total + *calls - 11\n", 0, 0)

void test_slice_iteration_31():
	slice_iteration_case(c"import lib.safe_vector\nref[a] T[] tail[T](ref[a] T[] view):\n\treturn view[1:]\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tint total = 0\n\tfor item in tail[int](view): total += item\n\treturn total - 9\n", 0, 0)

void test_slice_iteration_32():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tint total = 0\n\tfor item in view[1:3]: total += item\n\treturn total - 5\n", 0, 0)

void test_slice_iteration_33():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor item in view:\n\t\tref int* local = &item\n\t\tif *local > 10: return 1\n\treturn 0\n", 0, 0)

void test_slice_iteration_34():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor item in view:\n\t\tfor nested in view: buffer_clear[int](values)\n\treturn 0\n", c"borrow", 0)

void test_slice_iteration_35():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tint total = 0\n\tfor item in view:\n\t\tswitch item:\n\t\t\tcase 1: continue\n\t\t\tdefault: total += item\n\treturn total - 9\n", 0, 0)

void test_slice_iteration_36():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tint total = 0\n\tfor item in view:\n\t\tfor nested in view:\n\t\t\tif nested == 2: break\n\t\t\ttotal += item\n\treturn total - 10\n", 0, 0)

void test_slice_iteration_37():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor item in view:\n\t\tbuffer_clear[int](values)\n\t\tbreak\n\treturn 0\n", 0, 0)

void test_slice_iteration_38():
	slice_iteration_case(c"import lib.safe_vector\nstruct Holder:\n\tref[a] int[] items\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref[a] Holder holder = Holder(buffer_view[int](values))\n\tint total = 0\n\tfor item in holder.items: total += item\n\treturn total - 10\n", 0, 0)

void test_slice_iteration_39():
	slice_iteration_case(c"import lib.safe_vector\nref[a] int[] copy(ref[a] int[] view):\n\treturn view\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tint total = 0\n\tfor item in copy(copy(buffer_view[int](values))): total += item\n\treturn total - 10\n", 0, 0)

void test_slice_iteration_40():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor item in view:\n\t\tif item == 1: continue\n\t\tbuffer_clear[int](values)\n\treturn 0\n", c"borrow", 0)

void test_slice_iteration_41():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor item in view:\n\t\tif item == 1: break\n\t\tbuffer_clear[int](values)\n\treturn 0\n", c"borrow", 0)

void test_slice_iteration_42():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor int* item in view: pass\n\treturn 0\n", c"for loop variable type mismatch", 1)

void test_slice_iteration_43():
	slice_iteration_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(4): buffer_push[int](values, i + 1)\n\tref int[] view = buffer_view[int](values)\n\tfor first, second in view: pass\n\treturn 0\n", c"two loop variables", 1)
