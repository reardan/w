# wbuild: x64 arch=arm64 arch=arm64_darwin
# The addon engine with the script profile (repl/embed.w engine_script,
# docs/projects/scripting.md P2): addon sources compile under
# --profile=script, the host's own binds do not, and a rejected reload
# leaves the running version live. The engine's import roots are two
# small directories the test writes, so an addon import of any other
# module the session has not compiled is refused (W0425); modules the
# engine preloaded stay importable. P2b: the runtime's syscall wrappers
# are not visible to addon code (W0426), debugger is refused (W0427), and
# an addon with its own allowlist (engine_addon_roots) neither imports
# from nor names modules outside it (W0425, W0428).
import lib.testing
import repl.embed


int host_calls


void host_note(int v):
	host_calls = host_calls + v


int profile_test_ready


void profile_test_write(char* path, char* text):
	int fd = create_file(path, 420)
	asserts(path, fd >= 0)
	write(fd, text, strlen(text))
	close(fd)


void profile_test_engine():
	if (profile_test_ready): return;
	mkdir(c"bin", 493)
	mkdir(c"bin/addon_profile_roots", 493)
	mkdir(c"bin/addon_profile_roots/a", 493)
	mkdir(c"bin/addon_profile_roots/b", 493)
	profile_test_write(c"bin/addon_profile_roots/a/ap_alpha.w", c"int ap_alpha_value():\n\treturn 11\n")
	profile_test_write(c"bin/addon_profile_roots/b/ap_beta.w", c"int ap_beta_value():\n\treturn 22\n")
	asserts(c"engine_init", engine_init(c"bin/addon_profile_roots/a:bin/addon_profile_roots/b", engine_script))
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


void test_runtime_wrappers_not_visible():
	profile_test_engine()
	assert_rejected(c"open_addon", c"int f(int x):\n\treturn open(c\"/etc/passwd\", 0, 0)\n", c"script profile: runtime function 'open' is not visible to addon code")
	assert_rejected(c"unlink_addon", c"int f(int x):\n\treturn unlink(c\"bin/nothing\")\n", c"runtime function 'unlink' is not visible")
	assert_rejected(c"kill_addon", c"int f(int x):\n\treturn kill(x, 9)\n", c"runtime function 'kill' is not visible")
	assert_rejected(c"write_addon", c"int f(int x):\n\treturn write(1, c\"x\", 1)\n", c"runtime function 'write' is not visible")
	assert_rejected(c"mmap_addon", c"int f(int x):\n\treturn mmap(0, 4096, 7, 34)\n", c"runtime function 'mmap' is not visible")
	assert_rejected(c"exit_addon", c"int f(int x):\n\texit(x)\n\treturn 0\n", c"runtime function 'exit' is not visible")
	assert_rejected(c"fd_addon", c"int f(int x):\n\tprint_write(x, c\"x\", 1)\n\treturn 0\n", c"runtime function 'print_write' is not visible")
	assert_rejected(c"hook_addon", c"int f(int x):\n\tmalloc_hook_set(x, x, x)\n\treturn 0\n", c"runtime function 'malloc_hook_set' is not visible")
	# taking the address is a use too
	assert_rejected(c"addr_addon", c"int f(int x):\n\tint g = cast(int, open)\n\treturn g\n", c"runtime function 'open' is not visible")
	# alias.member reaches the same symbol
	assert_rejected(c"alias_addon", c"import lib.lib as L\nint f(int x):\n\treturn L.getchar(x)\n", c"runtime function 'getchar' is not visible")
	# the pure runtime stays usable, and a local may reuse a hidden name
	engine_result r = engine_load(c"pure_addon", c"int f(int x):\n\tint open = x + 1\n\tchar* s = itoa(open)\n\tchar* t = strjoin(s, c\"!\")\n\tprintln(t)\n\tint n = strlen(t)\n\tfree(t)\n\treturn n\n")
	assert_equal(engine_ok, r.status)
	assert_equal(3, profile_test_call(c"f", 41))


void test_debugger_rejected():
	profile_test_engine()
	assert_rejected(c"trap_addon", c"int f(int x):\n\tdebugger\n\treturn x\n", c"script profile: debugger statements are not allowed")


void test_per_addon_import_roots():
	profile_test_engine()
	# only_a may import from root a, never from root b
	asserts(c"allowlist", engine_addon_roots(c"only_a", c"bin/addon_profile_roots/a"))
	assert_equal(0, engine_addon_roots(c"only_a", c"bin/addon_profile_roots/missing"))
	engine_result r = engine_load(c"only_a", c"import ap_beta\nint f(int x):\n\treturn x\n")
	assert_equal(engine_error, r.status)
	assert_contains(r.diagnostics, c"script profile: import 'ap_beta' is not in an import root")
	# an addon on the default allowlist (engine_init's roots) imports from b
	assert_equal(engine_ok, engine_load(c"both", c"import ap_beta\nint both_value(int x):\n\treturn ap_beta_value() + x\n").status)
	assert_equal(23, profile_test_call(c"both_value", 1))
	# once compiled, b's module is still not only_a's to name
	r = engine_load(c"only_a", c"int f(int x):\n\treturn ap_beta_value()\n")
	assert_equal(engine_error, r.status)
	assert_contains(r.diagnostics, c"script profile: 'ap_beta_value' is declared in a module outside this addon's import roots")
	# but its own root works, and it may call another addon's own functions
	assert_equal(engine_ok, engine_load(c"only_a", c"import ap_alpha\nint f(int x):\n\treturn ap_alpha_value() + both_value(x)\n").status)
	assert_equal(11 + 22 + 2, profile_test_call(c"f", 2))
	# the allowlist sticks across a reload
	r = engine_reload(c"only_a", c"import ap_alpha\nint f(int x):\n\treturn ap_beta_value()\n")
	assert_equal(engine_error, r.status)
	assert_contains(r.diagnostics, c"outside this addon's import roots")
	assert_equal(35, profile_test_call(c"f", 2))
	# an empty allowlist: no new imports at all
	asserts(c"empty allowlist", engine_addon_roots(c"sealed_addon", c""))
	r = engine_load(c"sealed_addon", c"import ap_alpha\nint f(int x):\n\treturn ap_alpha_value()\n")
	assert_equal(engine_error, r.status)
	assert_contains(r.diagnostics, c"outside this addon's import roots")

# Native run leg; the generated Darwin twin stays compile-only on Linux.
# wbuild: target=addon_profile_darwin_test tag=tests_darwin dep=addon_profile_test_darwin
# wbuild: step="bin/addon_profile_test_darwin" expect_stdout="All tests passed"
