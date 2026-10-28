# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int control_flow_case_number


void control_flow_result(process_result* result, char* diagnostic, int checking, char* path):
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


void control_flow_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1):
	control_flow_case_number = control_flow_case_number + 1
	char* number = itoa(control_flow_case_number)
	char* prefix = c"bin/control_flow_case32_"
	if (__word_size__ == 8): prefix = c"bin/control_flow_case64_"
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
		control_flow_result(checked, diagnostic, 1, full)
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
		control_flow_result(compiled, diagnostic, 0, full)
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


void test_checked_control_flow():
	# range basic
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint total = 0\n\tfor i in range(4):\n\t\ttotal += i\n\treturn total - 6\n", 0)
	# range step
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint total = 0\n\tfor i in range(2, 9, 2):\n\t\ttotal += i\n\treturn total - 20\n", 0)
	# range header
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint bump(refmut int* x):\n\t*x += 1\n\treturn *x\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint n = 0\n\tint total = 0\n\tfor i in range(bump(&n), bump(&n), bump(&n)):\n\t\ttotal += i\n\treturn n + total - 4\n", 0)
	# range exits
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint total = 0\n\tfor i in range(8):\n\t\town int* owner = new int\n\t\tif i == 2: continue\n\t\tif i == 5: break\n\t\t*owner = i\n\t\ttotal += *owner\n\treturn total - 8\n", 0)
	# switch
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint n = 0\n\tfor i in range(4):\n\t\tswitch i:\n\t\t\tcase 0, 1: n += 1\n\t\t\tcase 2:\n\t\t\t\tn += 5\n\t\t\t\tbreak\n\t\t\tdefault: continue\n\t\tn += 1\n\treturn n - 10\n", 0)
	# switch returns
	control_flow_case(c"void checked(ref int* p):\n\tpass\nown int* pick(int n):\n\tswitch n:\n\t\tcase 0, 2: return new int\n\t\tdefault: return new int\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\town int* p = pick(2)\n\treturn *p\n", 0)
	# switch labels
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint bump(refmut int* x):\n\t*x += 1\n\treturn *x\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint n = 0\n\tint result = 0\n\tswitch 2:\n\t\tcase bump(&n), bump(&n), bump(&n): result = 7\n\t\tdefault: result = 11\n\treturn n + result - 9\n", 0)
	# implicit index write
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tfor i in range(2):\n\t\tref int* p = &i\n\t\tint n = *p\n\treturn 0\n", 0)
	# non-int range
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tfor char i in range(2):\n\t\tpass\n\treturn 0\n", c"range variable must")
	# empty switch
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint x = 4\n\tswitch x:\n\treturn x - 4\n", 0)


void test_checked_defer():
	# defer return capture
	control_flow_case(c"int change(refmut int* p):\n\t*p = 9\n\treturn 0\nint captured(refmut int* p):\n\tdefer change(p)\n\treturn *p\nint main():\n\tint x = 2\n\tint old = captured(&x)\n\treturn old + x - 11\n", 0)
	# defer LIFO
	control_flow_case(c"void digit(refmut int* p, int n):\n\t*p = *p * 10 + n\nvoid run(refmut int* p):\n\tdefer digit(p, 1)\n\tdefer digit(p, 2)\nint main():\n\tint x = 0\n\trun(&x)\n\treturn x - 21\n", 0)
	# defer fallthrough owner
	control_flow_case(c"void consume(own int* p):\n\tpass\nvoid run():\n\town int* p = new int\n\tdefer consume(p)\nint main():\n\trun()\n\treturn 0\n", 0)
	# defer captured owner
	control_flow_case(c"int read_value(ref int* p):\n\treturn *p\nown int* run():\n\town int* p = new int\n\tdefer read_value(p)\n\treturn p\nint main():\n\town int* p = run()\n\treturn *p\n", c"moved value")
	# defer duplicate move
	control_flow_case(c"void consume(own int* p):\n\tpass\nint main():\n\town int* p = new int\n\tdefer consume(p)\n\tdefer consume(p)\n\treturn 0\n", c"moved value")
	# defer borrower liveness
	control_flow_case(c"int read_value(ref int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\tref int* r = p\n\tdefer read_value(r)\n\tp = new int\n\treturn 0\n", c"conflicting")
	# defer borrowed result protection
	control_flow_case(c"int change(refmut int* p):\n\t*p = 9\n\treturn 0\nref int* run(refmut int* p):\n\tdefer change(p)\n\treturn p\nint main():\n\tint x = 0\n\tref int* p = run(&x)\n\treturn *p\n", c"conflicting")
	# defer returned shared read
	control_flow_case(c"int read_value(ref int* p):\n\treturn *p\nref int* run(ref int* p):\n\tdefer read_value(p)\n\treturn p\nint main():\n\tint x = 0\n\tref int* p = run(&x)\n\treturn *p\n", 0)
	# nested defer rejected
	control_flow_case(c"int read_value(ref int* p):\n\treturn *p\nint main():\n\tint x = 0\n\tref int* p = &x\n\tif x:\n\t\tdefer read_value(p)\n\treturn 0\n", c"outer lexical block")
	# defer later binding
	control_flow_case(c"int read_value(ref int* p):\n\treturn *p\nint main():\n\tdefer read_value(p)\n\town int* p = new int\n\treturn 0\n", 0)
	# defer before declaration initialization
	control_flow_case(c"int read_value(ref int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\tdefer read_value(p)\n\tif *p:\n\t\town int* q = p\n\t\treturn 0\n\treturn 0\n", c"moved value")


# Coverage-drive additions (docs/projects/line_coverage.md): these pin
# the safe checker's container-iteration and selector rejections, which
# no earlier case exercised.
void test_unsupported_iteration_and_selectors():
	# container iteration over a built-in list is not checked storage:
	# rejected by the iteration guard (compiler/safe.w safe_iteration)
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tlist[int] xs\n\txs.push(1)\n\tfor x in xs:\n\t\tpass\n\treturn 0\n", c"safe: iteration requires a checked shared slice or owned storage")
	# a pointer selector is not scalar (compiler/safe.w safe_control_scalar)
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tchar* msg = \"x\"\n\tswitch msg:\n\t\tdefault: return 1\n\treturn 0\n", c"safe: range and switch expressions require scalar values")
