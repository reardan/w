# wbuild: x64
# wbuild: deps=examples/scripting/
# wbuild: step="env W_ADDON_CHECKED=1 bin/addon_host_test --filter provenance,bind_and_load" expect_stdout="All tests passed"
# wbuild: step="bin/wv2 x64 examples/scripting/addon_host.w -o bin/addon_host_example"
# wbuild: step="bin/addon_host_example examples/scripting/addon_v1.w examples/scripting/addon_v2.w examples/scripting/addon_bad.w" expect_stdout="addon host OK" expect_stdout="demo:2: error: Cannot find symbol: 'no_such_symbol'" expect_stdout="function on_recurse"
# The addon engine API (repl/embed.w, docs/projects/scripting.md Phase E):
# bind, load, reload with repatching, rejected reloads with captured
# diagnostics, fault and stack-overflow recovery, generation rollback,
# provenance off by default. One engine per process; every test uses its
# own addon names. The engine compiles lib/ and structures/ from source at
# run time, found from the working directory (the repository root under
# wexec). The extra steps build and run examples/scripting/addon_host.w.
import lib.testing
import repl.embed
import lib.env


int host_calls
int host_value


void host_note(int v):
	host_calls = host_calls + 1
	host_value = v


int host_twice(int v):
	return v * 2


int addon_test_ready


void assert_true(int condition):
	asserts(c"expected true", condition)


# W_ADDON_CHECKED=1 (the extra step below) starts the engine with
# engine_checked, which keeps allocation provenance on.
int addon_test_checked():
	char* v = env_get(c"W_ADDON_CHECKED")
	return (v != 0) && (strcmp(v, c"1") == 0)


void addon_test_engine():
	if (addon_test_ready): return;
	int flags = 0
	if (addon_test_checked()): flags = engine_checked
	asserts(c"engine_init", engine_init(0, flags))
	asserts(c"bind host_note", engine_bind(c"host_note", c"fn(int) -> void", cast(int, host_note)))
	asserts(c"bind host_twice", engine_bind(c"host_twice", c"fn(int) -> int", cast(int, host_twice)))
	addon_test_ready = 1


# Call a session function that must not fault.
int addon_test_call(char* name, int arg):
	int ok = 0
	int address = engine_symbol(name)
	asserts(name, address != 0)
	int v = engine_call1(address, arg, &ok)
	asserts(c"call returned", ok == 1)
	return v


int addon_test_global(char* name):
	int at = engine_symbol(name)
	asserts(name, at != 0)
	return load_word(cast(char*, at))


void test_provenance_off_by_default():
	addon_test_engine()
	assert_equal(addon_test_checked(), engine_provenance_enabled())


void test_bind_and_load():
	addon_test_engine()
	engine_result r = engine_load(c"bind_addon", c"int ba_seen\nint ba_tick(int f):\n\tba_seen = ba_seen + 1\n\thost_note(f + 100)\n\treturn host_twice(f)\n")
	assert_equal(engine_ok, r.status)
	assert_equal(0, r.errors)
	assert_strings_equal(c"", r.diagnostics)
	int calls = host_calls
	assert_equal(42, addon_test_call(c"ba_tick", 21))
	assert_equal(calls + 1, host_calls)
	assert_equal(121, host_value)
	assert_equal(1, addon_test_global(c"ba_seen"))
	assert_equal(engine_symbol(c"ba_tick"), engine_addon_symbol(c"bind_addon", c"ba_tick"))
	# a bind with a bad signature or an empty address is refused
	assert_equal(0, engine_bind(c"bad_sig", c"int", cast(int, host_note)))
	assert_equal(0, engine_bind(c"bad_addr", c"fn() -> void", 0))
	assert_equal(0, engine_bind(c"bad name", c"fn() -> void", cast(int, host_note)))


void test_load_error_diagnostics_captured():
	addon_test_engine()
	int pos = codepos
	engine_result r = engine_load(c"broken_addon", c"int bk_fn(int f):\n\treturn f + bk_missing\n")
	assert_equal(engine_error, r.status)
	assert_equal(1, r.errors)
	assert_contains(r.diagnostics, c"\"file\": \"broken_addon\"")
	assert_contains(r.diagnostics, c"\"line\": 2")
	assert_contains(r.diagnostics, c"Cannot find symbol: 'bk_missing'")
	assert_equal(0, engine_symbol(c"bk_fn"))
	assert_equal(pos, codepos)
	# the name was never loaded, so it can be loaded fresh
	engine_result ok = engine_load(c"broken_addon", c"int bk_fn(int f):\n\treturn f + 1\n")
	assert_equal(engine_ok, ok.status)
	assert_equal(8, addon_test_call(c"bk_fn", 7))


void test_reload_repatches_callers():
	addon_test_engine()
	# rp_base's rp_summary calls rp_value; rp_over (loaded later) redefines
	# rp_value, and late binding repatches rp_summary to it
	assert_equal(engine_ok, engine_load(c"rp_base", c"int rp_value(int f):\n\treturn f + 1\n\nint rp_summary(int x):\n\treturn rp_value(1000)\n").status)
	assert_equal(1001, addon_test_call(c"rp_summary", 0))
	assert_equal(engine_ok, engine_load(c"rp_over", c"int rp_value(int f):\n\treturn f + 2\n").status)
	assert_equal(1002, addon_test_call(c"rp_summary", 0))
	# reloading rp_over releases its old rp_value (rp_summary's site is
	# pointed back at rp_base's, then at the new one)
	int pos = codepos
	for i in range(10): assert_equal(engine_ok, engine_reload(c"rp_over", c"int rp_value(int f):\n\treturn f + 3\n").status)
	assert_equal(pos, codepos)
	assert_equal(1003, addon_test_call(c"rp_summary", 0))
	# engine_load of a loaded name is a reload
	assert_equal(engine_ok, engine_load(c"rp_over", c"int rp_value(int f):\n\treturn f + 4\n").status)
	assert_equal(1004, addon_test_call(c"rp_summary", 0))
	# each addon's own definition stays reachable
	assert_true(engine_addon_symbol(c"rp_base", c"rp_value") != engine_addon_symbol(c"rp_over", c"rp_value"))


void test_reload_resets_state_and_replays_later_units():
	addon_test_engine()
	assert_equal(engine_ok, engine_load(c"rs_first", c"int rs_count\nint rs_bump(int x):\n\trs_count = rs_count + x\n\treturn rs_count\n").status)
	assert_equal(engine_ok, engine_load(c"rs_second", c"int rs_use(int x):\n\treturn rs_bump(x) * 10\n").status)
	assert_equal(50, addon_test_call(c"rs_use", 5))
	assert_equal(5, addon_test_global(c"rs_count"))
	# reloading rs_first (same source) resets its globals and recompiles
	# rs_second after it
	engine_result r = engine_reload(c"rs_first", 0)
	assert_equal(engine_ok, r.status)
	assert_equal(0, addon_test_global(c"rs_count"))
	assert_equal(10, addon_test_call(c"rs_use", 1))
	assert_true(engine_addon_symbol(c"rs_second", c"rs_use") != 0)


void test_rejected_reload_keeps_running_version_and_state():
	addon_test_engine()
	assert_equal(engine_ok, engine_load(c"rj_addon", c"int rj_state\nint rj_tick(int f):\n\trj_state = rj_state + 1\n\treturn f * 2\n").status)
	addon_test_call(c"rj_tick", 1)
	addon_test_call(c"rj_tick", 1)
	int pos = codepos
	engine_result r = engine_reload(c"rj_addon", c"int rj_state\nint rj_tick(int f):\n\treturn f * rj_nope\n")
	assert_equal(engine_error, r.status)
	assert_equal(1, r.errors)
	assert_contains(r.diagnostics, c"\"file\": \"rj_addon\"")
	assert_contains(r.diagnostics, c"Cannot find symbol: 'rj_nope'")
	assert_equal(pos, codepos)
	assert_equal(2, addon_test_global(c"rj_state"))
	assert_equal(10, addon_test_call(c"rj_tick", 5))


void test_reload_with_faulting_top_level_falls_back():
	addon_test_engine()
	assert_equal(engine_ok, engine_load(c"ff_addon", c"int ff_fn(int x):\n\treturn x + 1\n").status)
	engine_result r = engine_reload(c"ff_addon", c"int ff_fn(int x):\n\treturn x + 2\n\nint* ff_p = cast(int*, 0)\nff_p[0] = 1\n")
	assert_equal(engine_faulted, r.status)
	assert_contains(engine_fault_text, c"SIGSEGV in addon 'ff_addon' function <top level>")
	assert_equal(2, addon_test_call(c"ff_fn", 1))


void test_segfault_recovery():
	addon_test_engine()
	assert_equal(engine_ok, engine_load(c"sf_addon", c"int sf_crash(int x):\n\tint* p = cast(int*, 0)\n\treturn p[x]\n\nint sf_lib(int x):\n\treturn strlen(cast(char*, 0))\n\nint sf_div(int x):\n\treturn 10 / x\n").status)
	int ok = 1
	assert_equal(0, engine_call1(engine_symbol(c"sf_crash"), 0, &ok))
	assert_equal(0, ok)
	assert_contains(engine_fault_text, c"SIGSEGV in addon 'sf_addon' function sf_crash")
	# a fault in a library routine names the addon frame that called it
	engine_call1(engine_symbol(c"sf_lib"), 0, &ok)
	assert_equal(0, ok)
	assert_contains(engine_fault_text, c"in addon 'sf_addon' function sf_lib (in strlen)")
	engine_call1(engine_symbol(c"sf_div"), 0, &ok)
	assert_equal(0, ok)
	assert_contains(engine_fault_text, c"SIGFPE in addon 'sf_addon' function sf_div")
	# the engine keeps working
	assert_equal(5, addon_test_call(c"sf_div", 2))


void test_stack_overflow_recovery():
	addon_test_engine()
	assert_equal(engine_ok, engine_load(c"so_addon", c"int so_deep(int n):\n\tif (n == 0): return 0\n\treturn so_deep(n - 1) + 1\n").status)
	int ok = 1
	engine_call1(engine_symbol(c"so_deep"), 100000000, &ok)
	assert_equal(0, ok)
	assert_contains(engine_fault_text, c"SIGSEGV in addon 'so_addon' function so_deep")
	# twice: the alternate stack is usable again after the long jump
	engine_call1(engine_symbol(c"so_deep"), 100000000, &ok)
	assert_equal(0, ok)
	assert_equal(1000, addon_test_call(c"so_deep", 1000))


int host_reenter(int x):
	int ok = 1
	engine_call1(engine_symbol(c"ne_crash"), x, &ok)
	asserts(c"inner fault caught", ok == 0)
	return 7


void test_nested_calls_keep_outer_window():
	addon_test_engine()
	asserts(c"bind host_reenter", engine_bind(c"host_reenter", c"fn(int) -> int", cast(int, host_reenter)))
	assert_equal(engine_ok, engine_load(c"ne_addon", c"int ne_crash(int x):\n\tint* p = cast(int*, 0)\n\treturn p[x]\n\nint ne_outer(int x):\n\treturn host_reenter(x) + 1\n").status)
	assert_equal(8, addon_test_call(c"ne_outer", 0))
	# the outer window still catches a fault after the nested call
	int ok = 1
	engine_call1(engine_symbol(c"ne_crash"), 0, &ok)
	assert_equal(0, ok)


void test_generation_rollback():
	addon_test_engine()
	assert_equal(engine_ok, engine_load(c"gr_base", c"int gr_value(int f):\n\treturn f + 1\n\nint gr_summary(int x):\n\treturn gr_value(x)\n").status)
	engine_generation* g = engine_checkpoint()
	int pos = codepos
	int tab = table_pos
	assert_equal(engine_ok, engine_load(c"gr_over", c"int gr_value(int f):\n\treturn f + 50\n").status)
	assert_equal(engine_ok, engine_load(c"gr_more", c"int gr_extra(int f):\n\treturn f * 3\n").status)
	assert_equal(60, addon_test_call(c"gr_summary", 10))
	engine_rollback(g)
	assert_equal(pos, codepos)
	assert_equal(tab, table_pos)
	assert_equal(0, engine_symbol(c"gr_extra"))
	assert_equal(0, engine_addon_symbol(c"gr_over", c"gr_value"))
	# gr_summary's call site points at gr_base's gr_value again, even once
	# new code overwrites the released region
	assert_equal(11, addon_test_call(c"gr_summary", 10))
	assert_equal(engine_ok, engine_load(c"gr_filler", c"int gr_f1(int a):\n\treturn a + a + a + a + a + a + a + a\n\nint gr_f2(int a):\n\treturn gr_f1(a) * gr_f1(a + 1)\n").status)
	assert_equal(11, addon_test_call(c"gr_summary", 10))
	# the same generation can be rolled back to again
	engine_rollback(g)
	assert_equal(pos, codepos)
	engine_generation_free(g)
