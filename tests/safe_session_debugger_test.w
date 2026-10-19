# wbuild: x64 timeout=600000
# Checked debugger evaluation (#713): at a stop, print, conditions and
# 'repl' entries see the checked locals the checker proves usable there as
# read-only shared borrows; moved owners, borrows past their last use,
# outer frames, moves out of a view and raw 'set' writes are rejected
# explicitly. The 32-bit test drives a 32-bit wdbg and the x64 twin a
# 64-bit one.
import lib.testing
import lib.process
import lib.str


char* safe_dbg_binary


char* safe_dbg_build():
	if (safe_dbg_binary != 0): return safe_dbg_binary
	safe_dbg_binary = strjoin(c"bin/safe_session_wdbg", itoa(__word_size__ * 8))
	char** args = strv_new(5)
	strv_set(args, 0, c"bin/wv2")
	int at = 1
	if (__word_size__ == 8):
		strv_set(args, 1, c"x64")
		at = 2
	strv_set(args, at, c"debugger/debugger.w")
	strv_set(args, at + 1, c"-o")
	strv_set(args, at + 2, safe_dbg_binary)
	process_result* built = process_run(args[0], args, 0, 0, 600000)
	assert1(built != 0)
	if (built.status != 0): println(built.stderr_text)
	assert_equal(0, built.status)
	process_result_free(built)
	free(cast(void*, args))
	return safe_dbg_binary


process_result* safe_dbg_run(char* input):
	char** args = strv_new(3)
	strv_set(args, 0, safe_dbg_build())
	strv_set(args, 1, c"tests/safe_session_debugger_fixture.w")
	process_result* result = process_run(args[0], args, 0, input, 300000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


void safe_dbg_expect_order(char* text, list[char*] needles):
	int at = 0
	for i in range(needles.length):
		int found = index_of(text + at, needles[i])
		if (found < 0):
			print(c"missing in order: ")
			println(needles[i])
			println(text)
		assert1(found >= 0)
		at = at + found + strlen(needles[i])


void test_checked_locals_at_stops():
	process_result* r = safe_dbg_run(c"p r.value + plain\np p.value\nrepl\nr = p\nr.value + 1000\n:end\nb safe_session_debugger_fixture.w:14\ncondition 1 b.value + i == 43\nc\np i\np b.value + i\nd 1\nc\np sum\np r.value\np p.value\np consume(p)\nset p 0\nc\np b.value\nup\np p.value\nc\np p.value\np total\nc\n")
	assert_equal(0, r.status)
	list[char*] out = new list[char*]
	out.push(c"= 48")
	out.push(c"= 41")
	out.push(c"1041")
	out.push(c"condition: b.value + i == 43, hits: 3")
	out.push(c"i = 2")
	out.push(c"= 43")
	out.push(c"sum = 170")
	out.push(c"= 41")
	out.push(c"set: checked variables cannot be written by the debugger")
	out.push(c"= 41")
	out.push(c"total = 41")
	out.push(c"debuggee main returned 0")
	safe_dbg_expect_order(r.stdout_text, out)
	list[char*] err = new list[char*]
	err.push(c"checked debugger locals are read-only views at a stop")
	err.push(c"this checked local is not definitely initialized and live at this debugger stop")
	err.push(c"owner requires new storage or an ownership transfer")
	err.push(c"checked locals are only available in the innermost frame of an analyzed function")
	err.push(c"this checked local is not definitely initialized and live at this debugger stop")
	safe_dbg_expect_order(r.stderr_text, err)
	out.free()
	err.free()
	process_result_free(r)
