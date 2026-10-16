# wbuild: x64
# wbuild: deps=lib/safe_buffer.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int safe_extension_case_number


void safe_extension_result(process_result* result, char* diagnostic, int checking, char* path):
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


void safe_extension_case(char* source, char* diagnostic, int relaxed = 0):
	safe_extension_case_number = safe_extension_case_number + 1
	char* number = itoa(safe_extension_case_number)
	char* prefix = c"bin/safe_extension_case32_"
	if (__word_size__ == 8): prefix = c"bin/safe_extension_case64_"
	char* path = strjoin(prefix, number)
	free(number)
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
		safe_extension_result(checked, diagnostic, 1, full)
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
		safe_extension_result(compiled, diagnostic, 0, full)
		process_result_free(compiled)
		free(cast(void*, compiling))
		if (diagnostic):
			assert1(open(output, 0, 0) < 0)
		else:
			char** run = strv_new(1)
			strv_set(run, 0, output)
			process_result* executed = process_run(output, run, 0, 0, 30000)
			assert1(executed != 0)
			if (executed.status):
				print(full)
				print(executed.stderr_text)
			assert_equal(0, executed.status)
			process_result_free(executed)
			free(cast(void*, run))
		unlink(output)
	unlink(full)
	free(output)
	free(full)


void test_safe_extension_range_arguments():
	safe_extension_case(c"int record(refmut int* order, int value):\n\t*order = *order * 10 + value\n\treturn value\nint main():\n\town int* trigger = new int\n\tint order = 0\n\tint total = 0\n\tfor i in range(record(&order, 1), record(&order, 4), record(&order, 2)):\n\t\ttotal = total + i\n\treturn total + order - 146\n", 0)
	safe_extension_case(c"int count(own int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\t*p = 3\n\tint total = 0\n\tfor i in range(count(p)):\n\t\ttotal = total + i\n\treturn total - 3\n", 0)
	safe_extension_case(c"int count(own int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\tfor i in range(count(p), *p):\n\t\tpass\n\treturn 0\n", c"moved value")
	safe_extension_case(c"int main():\n\town int* p = new int\n\tint end = 4\n\tref int* r = &end\n\tint total = 0\n\tfor i in range(*r):\n\t\tend = 0\n\t\ttotal = total + i\n\treturn total - 6\n", 0)


void test_safe_extension_range_backedges():
	safe_extension_case(c"int main():\n\town int* p = new int\n\tfor i in range(2):\n\t\town int* moved = p\n\t\tcontinue\n\treturn 0\n", c"moved value")
	safe_extension_case(c"int main():\n\town int* p = new int\n\tint total = 0\n\tfor i in range(4):\n\t\town int* moved = p\n\t\t*moved = i\n\t\ttotal = total + *moved\n\t\tp = new int\n\t\tcontinue\n\treturn total - 6\n", 0)
	safe_extension_case(c"int main():\n\town int* p = new int\n\tref int* r = p\n\tfor i in range(2):\n\t\tint value = *r\n\t\t*p = value + 1\n\treturn 0\n", c"conflicting")
	safe_extension_case(c"int main():\n\town int* p = new int\n\tint result\n\tfor i in range(0):\n\t\tresult = i\n\treturn result\n", c"uninitialized")
	safe_extension_case(c"int main():\n\town int* p = new int\n\tfor i in range(1):\n\t\town int* moved = p\n\t\tbreak\n\treturn *p\n", c"moved value")
	safe_extension_case(c"int main():\n\town int* p = new int\n\tint total = 0\n\tfor i in range(1, 6, 2):\n\t\town int* local = new int\n\t\t*local = i\n\t\ttotal = total + *local\n\treturn total - 9\n", 0)


void test_safe_extension_switch_order():
	safe_extension_case(c"int mark(refmut int* order, int value):\n\t*order = *order * 10 + value\n\treturn value\nint main():\n\town int* p = new int\n\tint order = 0\n\tint result = 0\n\tswitch mark(&order, 2):\n\t\tcase mark(&order, 1), mark(&order, 2):\n\t\t\tresult = 7\n\t\tcase mark(&order, 3):\n\t\t\tresult = 99\n\t\tdefault:\n\t\t\tresult = 100\n\treturn order + result - 219\n", 0)
	safe_extension_case(c"int take(own int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\tswitch 2:\n\t\tcase take(p):\n\t\t\treturn 0\n\t\tdefault:\n\t\t\treturn *p\n", c"moved value")
	safe_extension_case(c"int main():\n\town int* p = new int\n\tswitch 2:\n\t\tcase 1:\n\t\t\town int* moved = p\n\t\tcase 2:\n\t\t\t*p = 4\n\treturn *p\n", c"moved value")
	safe_extension_case(c"int choose(ref int* p, int n):\n\tint result\n\tswitch n:\n\t\tcase 1:\n\t\t\tresult = 3\n\t\tdefault:\n\t\t\tresult = 4\n\treturn result\nint main():\n\town int* p = new int\n\treturn choose(p, 1) + choose(p, 2) - 7\n", 0)
	safe_extension_case(c"int main():\n\town int* p = new int\n\tint result\n\tswitch 2:\n\t\tcase 1:\n\t\t\tresult = 3\n\treturn result\n", c"uninitialized")


void test_safe_extension_nested_exits():
	safe_extension_case(c"int main():\n\town int* p = new int\n\tint total = 0\n\tfor i in range(4):\n\t\town int* local = new int\n\t\tswitch i:\n\t\t\tcase 0:\n\t\t\t\tcontinue\n\t\t\tcase 1:\n\t\t\t\tbreak\n\t\t\tdefault:\n\t\t\t\tfor j in range(3):\n\t\t\t\t\town int* nested = new int\n\t\t\t\t\tif j == 1: break\n\t\t\t\t\ttotal = total + 10\n\t\ttotal = total + i\n\treturn total - 26\n", 0)
	safe_extension_case(c"int main():\n\town int* p = new int\n\tfor i in range(3):\n\t\tswitch i:\n\t\t\tcase 0:\n\t\t\t\town int* moved = p\n\t\t\t\tcontinue\n\t\t\tdefault:\n\t\t\t\t*p = 3\n\treturn 0\n", c"moved value")


void test_safe_extension_defer_order():
	safe_extension_case(c"void append(refmut int* out, int value):\n\t*out = *out * 10 + value\nint work(refmut int* out):\n\town int* p = new int\n\tdefer append(out, 1)\n\tdefer append(out, 2)\n\treturn *out\nint main():\n\tint out = 0\n\tint returned = work(&out)\n\treturn returned + out - 21\n", 0)
	safe_extension_case(c"void set(refmut int* out, int value):\n\t*out = value\nint work(refmut int* out):\n\town int* p = new int\n\tint value = 1\n\tdefer set(out, value)\n\tvalue = 7\n\treturn value\nint main():\n\tint out = 0\n\tint returned = work(&out)\n\treturn returned + out - 14\n", 0)
	safe_extension_case(c"int consume(own int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\t*p = 7\n\tdefer consume(p)\n\treturn *p - 7\n", 0)


void test_safe_extension_defer_liveness():
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\tref int* r = p\n\tdefer probe_read(r)\n\t*p = 7\n\treturn 0\n", c"conflicting")
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\tdefer probe_read(p)\n\town int* moved = p\n\treturn 0\n", c"moved value")
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nown int* bad():\n\town int* p = new int\n\tdefer probe_read(p)\n\treturn p\nint main():\n\town int* p = bad()\n\treturn 0\n", c"moved value")
	safe_extension_case(c"int consume(own int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\tdefer consume(p)\n\tdefer consume(p)\n\treturn 0\n", c"moved value")
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nint consume(own int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\tdefer probe_read(p)\n\tdefer consume(p)\n\treturn 0\n", c"moved value")
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nint consume(own int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\tdefer consume(p)\n\tdefer probe_read(p)\n\treturn 0\n", 0)
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\tif *p:\n\t\tdefer probe_read(p)\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\tfor i in range(2):\n\t\tdefer probe_read(p)\n\treturn 0\n", c"safe:")


void test_safe_extension_optional_guards():
	safe_extension_case(c"int probe_read(optref int* p):\n\tif p == 0: return 0\n\treturn *p\nint main():\n\tint value = 7\n\toptref int* p = &value\n\treturn probe_read(p) + probe_read(0) - 7\n", 0)
	safe_extension_case(c"int probe_read(optref int* p):\n\tif p != 0: return *p\n\treturn 0\nint main():\n\tint value = 7\n\treturn probe_read(&value) + probe_read(0) - 7\n", 0)
	safe_extension_case(c"int probe_read(optref int* p):\n\tif !p: return 0\n\tref int* present = p\n\treturn *present\nint main():\n\tint value = 7\n\treturn probe_read(&value) + probe_read(0) - 7\n", 0)
	safe_extension_case(c"int probe_read(optref int* p):\n\tif p:\n\t\treturn *p\n\telse:\n\t\treturn 0\nint main():\n\tint value = 7\n\treturn probe_read(&value) + probe_read(0) - 7\n", 0)
	safe_extension_case(c"optref int* maybe(ref int* p, int yes):\n\tif yes: return p\n\treturn 0\nint main():\n\tint value = 7\n\toptref int* p = maybe(&value, 0)\n\treturn *p\n", c"presence check")
	safe_extension_case(c"int probe_read(optref int* p):\n\tif p == 0: return *p\n\treturn 0\nint main():\n\treturn probe_read(0)\n", c"presence check")
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nint checked(optref int* p):\n\treturn probe_read(p)\nint main():\n\treturn checked(0)\n", c"presence check")


void test_safe_extension_optional_joins():
	safe_extension_case(c"int probe_read(optref int* p, int n):\n\tif p:\n\t\tif n: p = 0\n\t\treturn *p\n\treturn 0\nint main():\n\treturn probe_read(0, 1)\n", c"presence check")
	safe_extension_case(c"int probe_read(optref int* p):\n\tif p:\n\t\tp = 0\n\t\treturn *p\n\treturn 0\nint main():\n\treturn probe_read(0)\n", c"presence check")
	safe_extension_case(c"int probe_read(optref int* p):\n\tif p:\n\t\tint n = 2\n\t\twhile n:\n\t\t\tint value = *p\n\t\t\tp = 0\n\t\t\tn = n - 1\n\treturn 0\nint main():\n\treturn probe_read(0)\n", c"presence check")
	safe_extension_case(c"int probe_read(optref int* p):\n\tint result = 0\n\twhile p:\n\t\tresult = *p\n\t\tp = 0\n\treturn result\nint main():\n\tint value = 7\n\treturn probe_read(&value) + probe_read(0) - 7\n", 0)
	safe_extension_case(c"int probe_read(optref int* p):\n\tif p:\n\t\tint value = *p\n\treturn *p\nint main():\n\treturn probe_read(0)\n", c"presence check")


void test_safe_extension_optional_origins():
	safe_extension_case(c"optref[a] int* choose(ref[a] int* left, ref[a] int* right, int n):\n\tif n == 1: return left\n\tif n == 2: return right\n\treturn 0\nint main():\n\town int* left = new int\n\town int* right = new int\n\toptref int* p = choose(left, right, 1)\n\t*right = 3\n\tif p: return *p\n\treturn 0\n", c"conflicting")
	safe_extension_case(c"optref int* bad(ref int* p):\n\tint local = 7\n\treturn &local\nint main():\n\treturn 0\n", c"must borrow from")
	safe_extension_case(c"int main():\n\town int* p = new int\n\toptref int* r = p\n\town int* moved = p\n\tif r: return *r\n\treturn 0\n", c"moved value")
	safe_extension_case(c"int main():\n\tint first = 7\n\tint second = 9\n\toptref int* r = &first\n\tr = &second\n\tfirst = 3\n\tif r: return *r\n\treturn 0\n", c"conflicting")


void test_safe_extension_optional_mutability():
	safe_extension_case(c"void update(optrefmut int* p):\n\tif p:\n\t\t*p = 7\nint main():\n\tint value = 0\n\tupdate(&value)\n\tupdate(0)\n\treturn value - 7\n", 0)
	safe_extension_case(c"void update(optref int* p):\n\tif p:\n\t\t*p = 7\nint main():\n\treturn 0\n", c"assignment to const")
	safe_extension_case(c"int main():\n\tint value = 0\n\toptrefmut int* p = &value\n\toptref int* q = p\n\tif p:\n\t\t*p = 7\n\tif q: return *q\n\treturn 0\n", c"conflicting")
	safe_extension_case(c"int main():\n\tint value = 0\n\toptref int* p = &value\n\tif p:\n\t\trefmut int* q = p\n\t\t*q = 7\n\treturn 0\n", c"shared", 1)


# A bounded interaction generator varies whether a loop reaches only continue,
# switch-break, nested-loop-break, or ordinary exit, while defer owns the root.
void test_safe_extension_generated_exit_paths():
	for limit in range(7):
		int expected = 0
		for i in range(limit):
			if i % 3 == 0: continue
			expected = expected + i
			if i % 3 == 2: expected = expected + 1
		char* bound = itoa(limit)
		char* result = itoa(expected)
		char* start = strjoin(c"void finish(own int* p, refmut int* out):\n\t*out = *p\nint work(refmut int* out):\n\town int* p = new int\n\t*p = 9\n\tdefer finish(p, out)\n\tint total = 0\n\tfor i in range(", bound)
		char* body = strjoin(start, c"):\n\t\town int* local = new int\n\t\t*local = i\n\t\tswitch i % 3:\n\t\t\tcase 0:\n\t\t\t\tcontinue\n\t\t\tcase 1:\n\t\t\t\tbreak\n\t\t\tdefault:\n\t\t\t\tfor j in range(3):\n\t\t\t\t\town int* nested = new int\n\t\t\t\t\tif j == 1: break\n\t\t\t\t\ttotal = total + 1\n\t\ttotal = total + *local\n\treturn total\nint main():\n\tint out = 0\n\tint total = work(&out)\n\treturn out + total - 9 - ")
		char* joined = strjoin(body, result)
		char* source = strjoin(joined, c"\n")
		safe_extension_case(source, 0)
		free(source)
		free(joined)
		free(body)
		free(start)
		free(result)
		free(bound)

void test_safe_extension_defer_returned_borrows():
	safe_extension_case(c"void mutate(refmut int* p):\n\t*p = 7\nref int* view(refmut int* p):\n\tdefer mutate(p)\n\treturn p\nint main():\n\tint value = 3\n\tref int* p = view(&value)\n\treturn *p\n", c"conflicting")
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nrefmut int* view(refmut int* p):\n\tdefer probe_read(p)\n\treturn p\nint main():\n\tint value = 3\n\trefmut int* p = view(&value)\n\treturn *p\n", c"conflicting")
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nref int* view(ref int* p):\n\tdefer probe_read(p)\n\treturn p\nint main():\n\tint value = 3\n\tref int* p = view(&value)\n\treturn *p - 3\n", 0)


void test_safe_extension_optional_conditions():
	safe_extension_case(c"int probe_read(optref int* p):\n\tif p && *p == 7: return 7\n\treturn 0\nint main():\n\tint value = 7\n\treturn probe_read(&value) + probe_read(0) - 7\n", 0)
	safe_extension_case(c"int probe_read(optref int* p):\n\tif !p || *p == 7: return 0\n\treturn 1\nint main():\n\tint value = 7\n\treturn probe_read(&value) + probe_read(0)\n", 0)
	safe_extension_case(c"int probe_read(optref int* p):\n\tif p || *p == 7: return 0\n\treturn 1\nint main():\n\treturn probe_read(0)\n", c"presence check")
	safe_extension_case(c"int probe_read(optref int* p):\n\tif !p && *p == 7: return 0\n\treturn 1\nint main():\n\treturn probe_read(0)\n", c"presence check")
	safe_extension_case(c"int probe_read(optref int* p):\n\treturn p ? *p : 0\nint main():\n\tint value = 7\n\treturn probe_read(&value) + probe_read(0) - 7\n", 0)
	safe_extension_case(c"int probe_read(optref int* p):\n\treturn p ? 0 : *p\nint main():\n\treturn probe_read(0)\n", c"presence check")
	safe_extension_case(c"int main():\n\toptref int* p = 0\n\tint n = 1\n\tif n:\n\t\tint local = 7\n\t\tp = &local\n\tif p: return *p\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\tint value = 7\n\toptref int* p = &value\n\toptref int* q = p\n\tp = 0\n\tif q: return *q - 7\n\treturn 1\n", 0)


void test_safe_extension_optional_cleared_parent():
	safe_extension_case(c"int main():\n\town int* p = new int\n\toptrefmut int* mutable = p\n\toptref int* shared = mutable\n\tmutable = 0\n\t*p = 7\n\tif shared: return *shared\n\treturn 0\n", c"conflicting")
	safe_extension_case(c"int main():\n\town int* p = new int\n\t*p = 7\n\toptrefmut int* mutable = p\n\toptref int* shared = mutable\n\tmutable = 0\n\tint old = *p\n\tif shared: return old + *shared - 14\n\treturn 1\n", 0)


void test_safe_extension_owned_buffer_interactions():
	safe_extension_case(c"import lib.safe_buffer\nint main():\n\town WOwnedIntBuffer* source = owned_int_buffer_new()\n\town WOwnedIntBuffer* destination = owned_int_buffer_new()\n\town int* p = new int\n\t*p = 7\n\towned_int_buffer_push(source, p)\n\towned_int_buffer_push(destination, owned_int_buffer_pop(source))\n\tref int* view = owned_int_buffer_get(destination, 0)\n\treturn *view + owned_int_buffer_length(source) - 7\n", 0)
	safe_extension_case(c"import lib.safe_buffer\nint main():\n\town WOwnedIntBuffer* b = owned_int_buffer_new()\n\towned_int_buffer_push(b, new int)\n\towned_int_buffer_push(b, owned_int_buffer_pop(b))\n\treturn 0\n", c"conflicting")
	safe_extension_case(c"import lib.safe_buffer\nint main():\n\town WOwnedIntBuffer* b = owned_int_buffer_new()\n\town int* p = new int\n\t*p = 7\n\towned_int_buffer_push(b, p)\n\town int* q = owned_int_buffer_pop(b)\n\tb = owned_int_buffer_new()\n\treturn *q - 7\n", 0)
	safe_extension_case(c"import lib.safe_buffer\nint fill(refmut WOwnedIntBuffer* b, own int* p):\n\tdefer owned_int_buffer_push(b, p)\n\treturn *p\nint main():\n\town WOwnedIntBuffer* b = owned_int_buffer_new()\n\town int* p = new int\n\t*p = 7\n\tint saved = fill(b, p)\n\tref int* view = owned_int_buffer_get(b, 0)\n\treturn saved + *view - 14\n", 0)
	safe_extension_case(c"import lib.safe_buffer\nint fill(refmut WOwnedIntBuffer* b, own int* p):\n\tdefer owned_int_buffer_push(b, p)\n\towned_int_buffer_push(b, p)\n\treturn 0\nint main():\n\town WOwnedIntBuffer* b = owned_int_buffer_new()\n\treturn fill(b, new int)\n", c"moved value")
	safe_extension_case(c"import lib.safe_buffer\nint main():\n\town WOwnedIntBuffer* b = owned_int_buffer_new()\n\towned_int_buffer_push(b, new int)\n\tdefer owned_int_buffer_pop(b)\n\treturn 0\n", c"checked pointers")
	safe_extension_case(c"import lib.safe_buffer\nref[a] int* choose(ref[a] WOwnedIntBuffer* left, ref[a] WOwnedIntBuffer* right, int n):\n\tif n: return owned_int_buffer_get(left, 0)\n\treturn owned_int_buffer_get(right, 0)\nint main():\n\town WOwnedIntBuffer* left = owned_int_buffer_new()\n\town WOwnedIntBuffer* right = owned_int_buffer_new()\n\towned_int_buffer_push(left, new int)\n\towned_int_buffer_push(right, new int)\n\tref int* view = choose(left, right, 1)\n\towned_int_buffer_clear(right)\n\treturn *view\n", c"conflicting")
	safe_extension_case(c"import lib.safe_buffer\nint main():\n\town WOwnedIntBuffer* b = owned_int_buffer_new()\n\towned_int_buffer_push(b, new int)\n\toptref int* view = owned_int_buffer_get(b, 0)\n\towned_int_buffer_clear(b)\n\tif view: return *view\n\treturn 0\n", c"conflicting")
	safe_extension_case(c"import lib.safe_buffer\nint main():\n\town WOwnedIntBuffer* b = owned_int_buffer_new()\n\towned_int_buffer_push(b, new int)\n\toptref int* view = owned_int_buffer_get(b, 0)\n\tview = 0\n\towned_int_buffer_clear(b)\n\treturn owned_int_buffer_length(b)\n", 0)


void test_safe_extension_arena_interactions():
	safe_extension_case(c"import lib.safe_buffer\nref[a] byte[] copied(refmut[a] WByteArena* arena):\n\tbyte[2] source\n\tsource[0] = cast(byte, 7)\n\treturn byte_arena_copy(arena, source)\nint main():\n\town WByteArena* arena = byte_arena_new()\n\tref byte[] view = copied(arena)\n\treturn cast(int, view[0]) - 7\n", 0)
	safe_extension_case(c"import lib.safe_buffer\nint main():\n\town WByteArena* arena = byte_arena_new()\n\tbyte[2] source\n\tsource[0] = cast(byte, 7)\n\tref byte[] view = byte_arena_copy(arena, source)\n\tsource[0] = cast(byte, 3)\n\treturn cast(int, view[0]) + cast(int, source[0]) - 10\n", 0)
	safe_extension_case(c"import lib.safe_buffer\nint main():\n\town WByteArena* arena = byte_arena_new()\n\tbyte[2] source\n\tref byte[] view = byte_arena_copy(arena, source)\n\tref byte[] duplicate = byte_arena_copy(arena, view)\n\treturn duplicate.length\n", c"conflicting")
	safe_extension_case(c"import lib.safe_buffer\nint main():\n\town WByteArena* arena = byte_arena_new()\n\tbyte[2] source\n\tref byte[] view = byte_arena_copy(arena, source)\n\tref int* length = &view.length\n\tbyte_arena_release(arena)\n\treturn *length\n", c"metadata")
	safe_extension_case(c"import lib.safe_buffer\nint main():\n\town WByteArena* arena = byte_arena_new()\n\tbyte[2] source\n\tref byte[] view = byte_arena_copy(arena, source)\n\tref byte* first = &view[0]\n\tbyte_arena_reset(arena)\n\treturn cast(int, *first)\n", c"conflicting")
	safe_extension_case(c"import lib.safe_buffer\nint main():\n\town WByteArena* arena = byte_arena_new()\n\tbyte[2] source\n\tref byte[] view = byte_arena_copy(arena, source)\n\tref byte[] nested = view[0:1]\n\tarena = byte_arena_new()\n\treturn cast(int, nested[0])\n", c"conflicting")
	safe_extension_case(c"import lib.safe_buffer\nint main():\n\town WByteArena* arena = byte_arena_new()\n\tbyte[2] source\n\tref byte[] original = source\n\tref byte[] view = byte_arena_copy(arena, original[0:0])\n\tint length = view.length\n\tbyte_arena_release(arena)\n\tref byte[] again = byte_arena_copy(arena, source)\n\treturn length + again.length - 2\n", 0)


void test_safe_extension_method_interactions():
	safe_extension_case(c"struct Point:\n\tint x\nint Point_value(ref Point* p):\n\treturn p.x\nint main():\n\toptref Point* p = 0\n\treturn p.value()\n", c"presence check")
	safe_extension_case(c"struct Point:\n\tint x\nint Point_value(ref Point* p):\n\treturn p.x\nint main():\n\town Point* owner = new Point(7)\n\toptref Point* p = owner\n\tif p: return p.value() - 7\n\treturn 1\n", 0)
	safe_extension_case(c"struct Point:\n\tint x\nref int* Point_view(ref Point* p):\n\treturn &p.x\nref int* bad(Point local, ref int* source):\n\treturn local.view()\nint main():\n\treturn 0\n", c"must borrow from")
	safe_extension_case(c"struct Point:\n\tint x\nint Point_take(own Point* p):\n\treturn p.x\nint main():\n\town Point* p = new Point(7)\n\tdefer p.take()\n\treturn p.x - 7\n", 0)
	safe_extension_case(c"struct Point:\n\tint x\nint Point_take(own Point* p):\n\treturn p.x\nint main():\n\town Point* p = new Point(7)\n\tdefer p.take()\n\tint value = p.take()\n\treturn value - 7\n", c"moved value")
	safe_extension_case(c"struct Point:\n\tint x\nvoid Point_set(refmut Point* p, int value):\n\tp.x = value\nint main():\n\town Point* owner = new Point(7)\n\toptref Point* p = owner\n\tif p: p.set(3)\n\treturn 0\n", c"shared")


void test_safe_extension_optional_deferred_presence():
	safe_extension_case(c"int probe_read(optref int* p):\n\tif p: return *p\n\treturn 0\nint main():\n\town int* p = new int\n\toptref int* r = p\n\tr = 0\n\town int* moved = p\n\treturn probe_read(r)\n", 0)
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\toptref int* r = p\n\tdefer probe_read(r)\n\tr = 0\n\treturn 0\n", c"presence check")
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nvoid observe(optref int* p):\n\tdefer p && probe_read(p)\nint main():\n\tint value = 7\n\tobserve(&value)\n\tobserve(0)\n\treturn 0\n", 0)
	safe_extension_case(c"int probe_read(ref int* p):\n\treturn *p\nvoid observe(optref int* p):\n\tdefer p || probe_read(p)\nint main():\n\tobserve(0)\n\treturn 0\n", c"presence check")


# A default-only switch has no unmatched edge: it exposes missing jump cleanup
# that a loop zero-iteration edge can otherwise mask during state joins.
void test_safe_extension_jump_scope_escape():
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\town int* local = new int\n\t\t\tsaved = local\n\t\t\tbreak\n\tif saved: return *saved\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\tint local = 7\n\t\t\tsaved = &local\n\t\t\tbreak\n\tif saved: return *saved\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\tif 1:\n\t\t\t\town int* local = new int\n\t\t\t\tsaved = local\n\t\t\t\tbreak\n\tif saved: return *saved\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\tswitch 2:\n\t\t\t\tdefault:\n\t\t\t\t\town int* local = new int\n\t\t\t\t\tsaved = local\n\t\t\t\t\tbreak\n\t\t\tif saved: return *saved\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tint n = 2\n\twhile n:\n\t\tswitch 1:\n\t\t\tdefault:\n\t\t\t\town int* local = new int\n\t\t\t\tsaved = local\n\t\t\t\tbreak\n\t\tif saved: return *saved\n\t\tn = n - 1\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\town int* local = new int\n\t\t\tsaved = local\n\tif saved: return *saved\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\twhile 1:\n\t\town int* local = new int\n\t\tsaved = local\n\t\tbreak\n\tif saved: return *saved\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tint n = 2\n\twhile n:\n\t\tif saved: return *saved\n\t\tswitch 1:\n\t\t\tdefault:\n\t\t\t\town int* local = new int\n\t\t\t\tsaved = local\n\t\t\t\tn = n - 1\n\t\t\t\tcontinue\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\tfor i in range(1):\n\t\t\t\tsaved = &i\n\t\t\t\tbreak\n\t\t\tbreak\n\tif saved: return *saved\n\treturn 0\n", c"safe:")
	safe_extension_case(c"optref int* bad(ref int* source):\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\town int* local = new int\n\t\t\tsaved = local\n\t\t\tbreak\n\treturn saved\nint main():\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\town int* owner = new int\n\t*owner = 7\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\tsaved = owner\n\t\t\tbreak\n\tif saved: return *saved - 7\n\treturn 1\n", 0)
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\town int* owner = new int\n\t\t\t*owner = 7\n\t\t\tswitch 2:\n\t\t\t\tdefault:\n\t\t\t\t\tsaved = owner\n\t\t\t\t\tbreak\n\t\t\tif saved: return *saved - 7\n\treturn 1\n", 0)
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tfor i in range(1):\n\t\tsaved = &i\n\t\tbreak\n\tif saved: return *saved\n\treturn 1\n", 0)


# Reusing a declaration in another iteration must not revive loans into its
# previous allocation; descendants of an escaping optional need invalidation.
void test_safe_extension_iteration_incarnations():
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tint n = 0\n\twhile n < 2:\n\t\town int* local = new int\n\t\tif saved: return *saved\n\t\tsaved = local\n\t\tn = n + 1\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tfor i in range(2):\n\t\town int* local = new int\n\t\tif saved: return *saved\n\t\tsaved = local\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tint n = 0\n\twhile n < 2:\n\t\tint local = n\n\t\tif saved: return *saved\n\t\tsaved = &local\n\t\tn = n + 1\n\t\tcontinue\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\toptref int* copied = 0\n\tint n = 0\n\twhile n < 2:\n\t\town int* local = new int\n\t\tif copied: return *copied\n\t\tsaved = local\n\t\tcopied = saved\n\t\tn = n + 1\n\treturn 0\n", c"safe:")
	safe_extension_case(c"ref int* view(ref int* p):\n\treturn p\nint main():\n\toptref int* saved = 0\n\tint n = 0\n\twhile n < 2:\n\t\town int* local = new int\n\t\tif saved: return *saved\n\t\tsaved = view(local)\n\t\tn = n + 1\n\treturn 0\n", c"safe:")
	safe_extension_case(c"optref int* view(ref int* p):\n\treturn p\nint main():\n\toptref int* saved = 0\n\tint n = 0\n\twhile n < 2:\n\t\town int* local = new int\n\t\tif saved: return *saved\n\t\tsaved = view(local)\n\t\tn = n + 1\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tfor i in range(2):\n\t\tswitch i:\n\t\t\tdefault:\n\t\t\t\town int* local = new int\n\t\t\t\tif saved: return *saved\n\t\t\t\tsaved = local\n\t\t\t\tbreak\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptrefmut int* saved = 0\n\tint n = 0\n\twhile n < 2:\n\t\town int* local = new int\n\t\tif saved: *saved = 7\n\t\tsaved = local\n\t\tn = n + 1\n\treturn 0\n", c"safe:")
	safe_extension_case(c"int main():\n\toptref int* saved = 0\n\tint total = 0\n\tfor i in range(2):\n\t\town int* local = new int\n\t\t*local = 7\n\t\tsaved = local\n\t\tif saved: total = total + *saved\n\t\tsaved = 0\n\treturn total - 14\n", 0)
	safe_extension_case(c"int main():\n\town int* owner = new int\n\t*owner = 7\n\toptref int* saved = 0\n\tint total = 0\n\tfor i in range(2):\n\t\tref int* local = owner\n\t\tsaved = local\n\t\tif saved: total = total + *saved\n\tif saved: return total + *saved - 21\n\treturn 1\n", 0)
