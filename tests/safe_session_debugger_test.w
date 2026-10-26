# wbuild: x64 timeout=600000
# Checked debugger evaluation (#713): at a stop, print, conditions and
# 'repl' entries see the checked locals the checker proves usable there as
# read-only shared views: owners and references as 'ref T*', optional ones
# as 'optref T*' (presence check still required), inline slices as
# 'ref T[]', borrowed records as 'ref[..] R' (a shared twin of R's
# template when R has exclusive fields) and owners carrying borrowed groups
# as 'ref R*' (labels dropped), in the innermost frame and in outer frames
# suspended in a call. Moved owners (including those moved into the call in
# progress), borrows past their last use, locals lent exclusively to the
# call in progress, writes through views, moves out of a view and raw 'set'
# writes are rejected explicitly. The 32-bit test drives a
# 32-bit wdbg and the x64 twin a 64-bit one.
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


process_result* safe_dbg_run_fixture(char* fixture, char* input):
	char** args = strv_new(3)
	strv_set(args, 0, safe_dbg_build())
	strv_set(args, 1, fixture)
	process_result* result = process_run(args[0], args, 0, input, 300000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


process_result* safe_dbg_run(char* input):
	return safe_dbg_run_fixture(c"tests/safe_session_debugger_fixture.w", input)


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
	process_result* r = safe_dbg_run(c"p r.value + plain\np p.value\nrepl\nr = p\nr.value + 1000\n:end\nb safe_session_debugger_fixture.w:14\ncondition 1 b.value + i == 43\nrepl\nstep(r, 2) + 500\np b.value + i + 100\nc\n:end\nc\np i\np b.value + i\nd 1\nc\np sum\np r.value\np p.value\np consume(p)\nset p 0\nc\np b.value\nup\np p.value\nc\np p.value\np total\nc\n")
	assert_equal(0, r.status)
	list[char*] out = new list[char*]
	out.push(c"= 48")
	out.push(c"= 41")
	out.push(c"1041")
	# A stop nested inside an entry evaluates in the inner frame, then the
	# entry finishes.
	out.push(c"condition: b.value + i == 43, hits: 1")
	out.push(c"= 143")
	out.push(c"= 543")
	out.push(c"condition: b.value + i == 43, hits: 4")
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
	# 'up' from consume: main is suspended in the call that moved p.
	err.push(c"this checked local is not definitely initialized and live at this debugger stop")
	err.push(c"this checked local is not definitely initialized and live at this debugger stop")
	safe_dbg_expect_order(r.stderr_text, err)
	out.free()
	err.free()
	process_result_free(r)


# Outer frames suspended in a call, optional owners and references, and
# inline slices (tests/safe_session_debugger_views_fixture.w).
void test_checked_views_of_frames_optionals_and_slices():
	string_builder* in = string_new()
	# bump(p): main lends p exclusively to the call.
	string_append(in, c"up\np q.value + r.value\np p.value\np all[1] + all.length\np some.value\np present(some) + present(none) + 1000\np h.tag\nc\n")
	# bump(w): the reborrow and its root are both lent.
	string_append(in, c"up\np w.value\np p.value\np q.value\nc\n")
	# peek(r, h.tag): r is in use by the call; w is past its last use.
	string_append(in, c"up\np r.value + p.value + q.value\np w.value\nc\n")
	# maybe(look): an optional reference parameter.
	string_append(in, c"p m.value\np present(m)\nrepl\nint seen = 0\nif (m): seen = m.value + 100\nseen\n:end\nc\n")
	# slice_sum(tail): a shared slice parameter; main's refmut slice is
	# viewed as shared.
	string_append(in, c"p s[0] + s.length\nrepl\ns[0] = 5\n:end\nup\np tail[1] + tail.length\np all[2]\nc\n")
	process_result* r = safe_dbg_run_fixture(c"tests/safe_session_debugger_views_fixture.w", in.data)
	string_free(in)
	assert_equal(0, r.status)
	list[char*] out = new list[char*]
	out.push(c"= 40")
	out.push(c"= 5")
	out.push(c"= 1030")
	# h is a lifetime-labeled borrowed record, viewed as 'ref[a] Holder'.
	out.push(c"= 5")
	out.push(c"bump(w)")
	out.push(c"= 20")
	out.push(c"= 52")
	out.push(c"= 12")
	out.push(c"= 112")
	out.push(c"= 9")
	out.push(c"= 10")
	out.push(c"= 3")
	out.push(c"debuggee main returned 0")
	safe_dbg_expect_order(r.stdout_text, out)
	list[char*] err = new list[char*]
	err.push(c"this checked local is lent exclusively to the call this frame is suspended in")
	err.push(c"optional reference requires a presence check")
	err.push(c"this checked local is lent exclusively to the call this frame is suspended in")
	err.push(c"this checked local is lent exclusively to the call this frame is suspended in")
	err.push(c"this checked local is not definitely initialized and live at this debugger stop")
	err.push(c"optional reference requires a presence check")
	err.push(c"write through a shared reference")
	safe_dbg_expect_order(r.stderr_text, err)
	out.free()
	err.free()
	process_result_free(r)


# Borrowed records, owners carrying borrowed groups and labeled locals
# (tests/safe_session_debugger_aggregates_fixture.w): viewable while live,
# hidden past their last use; records with exclusive fields through a
# shared twin of their template.
void test_checked_views_of_aggregates():
	string_builder* in = string_new()
	string_append(in, c"p h.tag + holder_sum(h)\np pair_sum(pair)\np stored_sum(stored)\np r.value\n")
	# Records with exclusive fields (e, and n through its nested record)
	# are viewed through shared twins: reads work, a mutable borrow or a
	# field write is rejected.
	string_append(in, c"p peek(e.item) + e.amount\np n.extra + n.inner.amount + peek(n.inner.item)\np add(e)\n")
	string_append(in, c"repl\nh.tag = 9\ne.amount = 9\nn.inner.amount = 9\n:end\nset h 0\nset e 0\nc\n")
	# Past the last uses of h, pair and stored, after p was mutated.
	string_append(in, c"p h.tag\np stored_sum(stored)\np pair_sum(pair)\nc\n")
	# A record parameter of the innermost frame.
	string_append(in, c"p h.tag + holder_sum(h)\nc\n")
	process_result* r = safe_dbg_run_fixture(c"tests/safe_session_debugger_aggregates_fixture.w", in.data)
	string_free(in)
	assert_equal(0, r.status)
	list[char*] out = new list[char*]
	out.push(c"= 16")
	out.push(c"= 30")
	out.push(c"= 120")
	out.push(c"= 20")
	out.push(c"= 5 ")
	out.push(c"= 14 ")
	out.push(c"set: checked variables cannot be written by the debugger")
	out.push(c"set: checked variables cannot be written by the debugger")
	out.push(c"= 32")
	out.push(c"debuggee main returned 0")
	safe_dbg_expect_order(r.stdout_text, out)
	list[char*] err = new list[char*]
	err.push(c"safe: cannot make a mutable borrow from a shared reference")
	err.push(c"write through a shared reference")
	err.push(c"write through a shared reference")
	err.push(c"write through a shared reference")
	err.push(c"this checked local is not definitely initialized and live at this debugger stop")
	err.push(c"this checked local is not definitely initialized and live at this debugger stop")
	err.push(c"this checked local is not definitely initialized and live at this debugger stop")
	safe_dbg_expect_order(r.stderr_text, err)
	out.free()
	err.free()
	process_result_free(r)
