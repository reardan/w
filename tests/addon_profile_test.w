# wbuild: x64
# The addon engine with the script profile (repl/embed.w engine_script,
# docs/projects/scripting.md P2): addon sources compile under
# --profile=script, the host's own binds do not, and a rejected reload
# leaves the running version live. No import root is passed, so an addon
# import of a module the session has not compiled is refused (W0425);
# modules the engine preloaded stay importable.
import lib.testing
import repl.embed


int host_calls


void host_note(int v):
	host_calls = host_calls + v


int profile_test_ready


void profile_test_engine():
	if (profile_test_ready): return;
	asserts(c"engine_init", engine_init(0, engine_script))
	asserts(c"bind host_note", engine_bind(c"host_note", c"fn(int) -> void", cast(int, host_note)))
	profile_test_ready = 1


int profile_test_call(char* name, int arg):
	int ok = 0
	int address = engine_symbol(name)
	asserts(name, address != 0)
	int v = engine_call1(address, arg, &ok)
	asserts(c"call returned", ok == 1)
	return v


void assert_rejected(char* addon, char* text, char* message):
	engine_result r = engine_load(addon, text)
	assert_equal(engine_error, r.status)
	assert_contains(r.diagnostics, message)
	assert_equal(0, engine_addon_symbol(addon, c"f"))


void test_plain_addon_loads():
	profile_test_engine()
	engine_result r = engine_load(c"plain", c"int pl_total\nint f(int x):\n\tpl_total = pl_total + x\n\thost_note(x)\n\treturn pl_total * 2\n")
	assert_equal(engine_ok, r.status)
	int before = host_calls
	assert_equal(10, profile_test_call(c"f", 5))
	assert_equal(before + 5, host_calls)


void test_pointer_cast_rejected():
	profile_test_engine()
	assert_rejected(c"cast_addon", c"int f(int x):\n\tint* p = cast(int*, x)\n\treturn p[0]\n", c"script profile: cast to a pointer type is not allowed")


void test_asm_rejected():
	profile_test_engine()
	assert_rejected(c"asm_addon", c"int f():\n\tasm x86:\n\t\t\"mov eax, 42\"\n\t\t\"ret\"\n\treturn 42\n", c"script profile: asm blocks are not allowed")


void test_syscall_builtin_rejected():
	profile_test_engine()
	assert_rejected(c"sys_addon", c"int f(int x):\n\treturn syscall(39, 0, 0, 0)\n", c"script profile: built-in 'syscall' is not allowed")


void test_import_outside_roots_rejected():
	profile_test_engine()
	assert_rejected(c"import_addon", c"import lib.file\nint f(int x):\n\treturn x\n", c"is not in an import root")


void test_rejected_reload_keeps_running_version():
	profile_test_engine()
	assert_equal(engine_ok, engine_load(c"keep", c"int kp(int x):\n\treturn x + 1\n").status)
	engine_result r = engine_reload(c"keep", c"int kp(int x):\n\tchar* p = cast(char*, x)\n\treturn p[0]\n")
	assert_equal(engine_error, r.status)
	assert_contains(r.diagnostics, c"script profile")
	assert_equal(8, profile_test_call(c"kp", 7))
	assert_equal(engine_ok, engine_reload(c"keep", c"int kp(int x):\n\treturn x + 2\n").status)
	assert_equal(9, profile_test_call(c"kp", 7))
