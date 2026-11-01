# wbuild: x64
/*
The script profile in the in-process engine (docs/projects/scripting.md
§5.2): a host sets script_profile_mode before it compiles an addon entry
and clears it afterwards. The profile applies to entries compiled while
it is set, never to the runtime and preloaded modules repl_init compiled,
and a rejected entry rolls back like any compile error.
*/
import lib.testing
import repl.core


void test_script_profile_toggles_between_entries():
	repl_init()
	script_profile_mode = 1
	repl_result r = repl_eval(c"int addon_raw():\n\treturn syscall(20, 0, 0, 0)\n")
	assert_equal(0, r.status)
	r = repl_eval(c"int addon_poke(int a):\n\tint* p = cast(int*, a)\n\treturn p[0]\n")
	assert_equal(0, r.status)
	r = repl_eval(c"int addon_block():\n\tint x = 1\n\tunsafe:\n\t\tx = 2\n\treturn x\n")
	assert_equal(0, r.status)
	r = repl_eval(c"int addon_thread(int a):\n\treturn thread_create(addon_thread, a)\n")
	assert_equal(0, r.status)
	# Outside every import root (there are none here) nothing new imports
	r = repl_eval(c"import lib.file\n")
	assert_equal(0, r.status)
	# A module repl_init already compiled is a no-op import, still allowed
	r = repl_eval(c"import lib.assert\n")
	assert_equal(1, r.status)
	# Ordinary addon code compiles and runs; the runtime it calls (lists,
	# f-strings) was compiled as trusted imports
	r = repl_eval(c"int addon_sum(int n):\n\tlist[int] l = new list[int]\n\tfor i in range(n): l.push(i)\n\tint total = 0\n\tfor v in l: total = total + v\n\treturn total\n")
	assert_equal(1, r.status)
	r = repl_eval(c"addon_sum(5)")
	assert_equal(1, r.status)
	assert_equal(10, r.value)
	r = repl_eval(c"string addon_text = f\"{addon_sum(3)}\"")
	assert_equal(1, r.status)
	# The host turns the profile off for its own entries
	script_profile_mode = 0
	r = repl_eval(c"int host_pid():\n\treturn syscall(20, 0, 0, 0)\n")
	assert_equal(1, r.status)
	r = repl_eval(c"int host_peek(int* p):\n\tchar* bytes = cast(char*, p)\n\treturn bytes[0]\n")
	assert_equal(1, r.status)
	# ... and back on for the next addon, which may call what the host
	# defined: gating is per construct, not per callee
	script_profile_mode = 1
	r = repl_eval(c"int addon_calls_host = host_pid() + 1")
	assert_equal(1, r.status)
	r = repl_eval(c"int addon_again():\n\treturn syscall(20, 0, 0, 0)\n")
	assert_equal(0, r.status)
	script_profile_mode = 0
	repl_cleanup()
