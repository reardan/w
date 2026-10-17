# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int specialization_case_number


void specialization_result(process_result* result, char* diagnostic, int checking, char* path):
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


void specialization_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1):
	specialization_case_number = specialization_case_number + 1
	char* number = itoa(specialization_case_number)
	char* prefix = c"bin/specialization_case32_"
	if (__word_size__ == 8): prefix = c"bin/specialization_case64_"
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
		specialization_result(checked, diagnostic, 1, full)
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
		specialization_result(compiled, diagnostic, 0, full)
		process_result_free(compiled)
		free(cast(void*, compiling))
		if (diagnostic):
			assert1(open(output, 0, 0) < 0)
		else:
			char** run = strv_new(1)
			strv_set(run, 0, output)
			process_result* executed = process_run(output, run, 0, 0, 30000)
			assert1(executed != 0)
			assert_equal(0, executed.status)
			process_result_free(executed)
			free(cast(void*, run))
		unlink(output)
	unlink(full)
	free(output)
	free(full)


void test_checked_generic_specialization():
	# explicit scalar
	specialization_case(c"T identity[T](T p):\n\treturn p\nint main():\n\tint x = 7\n\tref int* r = &x\n\treturn identity[int](*r) - 7\n", 0)
	# inferred scalar
	specialization_case(c"T identity[T](T p):\n\treturn p\nint main():\n\tint x = 7\n\tref int* r = &x\n\treturn identity(*r) - 7\n", 0)
	# explicit owner
	specialization_case(c"T identity[T](T p):\n\treturn p\nint main():\n\town int* p = new int\n\t*p = 7\n\town int* q = identity[own int*](p)\n\treturn *q - 7\n", 0)
	# inferred owner
	specialization_case(c"T identity[T](T p):\n\treturn p\nint main():\n\town int* p = new int\n\t*p = 7\n\town int* q = identity(p)\n\treturn *q - 7\n", 0)
	# explicit owner moved
	specialization_case(c"T identity[T](T p):\n\treturn p\nint main():\n\town int* p = new int\n\town int* q = identity[own int*](p)\n\treturn *p\n", c"moved value")
	# explicit ref
	specialization_case(c"T identity[T](T p):\n\treturn p\nint main():\n\tint x = 7\n\tref int* r = identity[ref int*](&x)\n\treturn *r - 7\n", 0)
	# inferred ref
	specialization_case(c"T identity[T](T p):\n\treturn p\nint main():\n\tint x = 7\n\tref int* p = &x\n\tref int* r = identity(p)\n\treturn *r - 7\n", 0)
	# explicit ref lifetime
	specialization_case(c"T identity[T](T p):\n\treturn p\nint main():\n\tint x = 7\n\tref int* r = identity[ref[a] int*](&x)\n\treturn *r - 7\n", 0)
	# explicit ref invalidation
	specialization_case(c"T identity[T](T p):\n\treturn p\nint main():\n\tint x = 7\n\tref int* r = identity[ref int*](&x)\n\tx = 4\n\treturn *r\n", c"conflicting")
	# specialized body checked
	specialization_case(c"T duplicate[T](T p):\n\tT q = p\n\treturn p\nint main():\n\town int* p = duplicate[own int*](new int)\n\treturn *p\n", c"moved value")


void test_checked_generic_pointer_contracts():
	# named generic borrowed result
	specialization_case(c"ref[a] T* view[T](ref[a] T* p):\n\treturn p\nint main():\n\tint x = 7\n\tref int* r = view[int](&x)\n\treturn *r - 7\n", 0)
	# generic owner result
	specialization_case(c"own T* make[T](own T* item):\n\treturn item\nint main():\n\town int* p = make[int](new int)\n\treturn *p\n", 0)
	# generic owner parameter
	specialization_case(c"int consume[T](own T* p):\n\treturn 0\nint main():\n\town int* p = new int\n\treturn consume[int](p)\n", 0)
	# named multiple inputs
	specialization_case(c"ref[a] T* choose[T](ref[a] T* p, ref[a] T* q, int first):\n\tif first: return p\n\treturn q\nint main():\n\tint x = 7\n\tint y = 3\n\tref int* r = choose[int](&x, &y, 0)\n\treturn *r - 3\n", 0)
	# named multiple invalidation
	specialization_case(c"ref[a] T* choose[T](ref[a] T* p, ref[a] T* q, int first):\n\tif first: return p\n\treturn q\nint main():\n\tint x = 7\n\tint y = 3\n\tref int* r = choose[int](&x, &y, 0)\n\tx = 4\n\treturn *r\n", c"conflicting")
	# named invalid return
	specialization_case(c"ref[a] T* bad[T](ref[a] T* p):\n\tT local = *p\n\treturn &local\nint main():\n\tint x = 7\n\tref int* r = bad[int](&x)\n\treturn *r\n", c"must borrow from")


void test_checked_generic_preserves_unsafe_callbacks():
	specialization_case(c"type Callback = fn(int) -> int\nint increment(int value): return value + 1\nint main():\n\town int* p = new int\n\t*p = 7\n\tint result = 0\n\tunsafe:\n\t\tCallback* callback = increment\n\t\tresult = callback(6)\n\treturn result - *p\n", 0)


void test_checked_generic_representation_boundaries():
	specialization_case(c"T identity[T](T p):\n\treturn p\nstruct View:\n\tref[a] int* item\nint main():\n\tint x = 7\n\tref View p = View(&x)\n\tref View q = identity(p)\n\tref int* view = q.item\n\treturn *view - 7\n", 0)
	specialization_case(c"T identity[T](T p):\n\treturn p\nint main():\n\tint[2] data\n\tdata[0] = 7\n\tref int[] p = data\n\tref int[] q = identity(p)\n\treturn q[0] - 7\n", 0)
	specialization_case(c"T identity[T](T p):\n\treturn p\nint main():\n\tbyte[2] data\n\tdata[0] = cast(byte, 7)\n\tref byte[] p = data\n\tref byte[] q = identity[ref byte[]](p)\n\treturn cast(int, q[0]) - 7\n", 0)
