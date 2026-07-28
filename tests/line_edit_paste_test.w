# wbuild: x64
/*
Pure-logic unit tests for lib/line_edit.w's paste-robustness fixes
(ai_tooling_next_steps.md "REPL surface"): the pushback stack that
un-reads probed bytes (le_pushback/le_getchar), the bracketed-paste
end-marker matcher's mismatch pushback (le_paste_match_end), CRLF
normalization during a paste (le_paste_eat_crlf), the byte-exact
auto-indent-seed comparison (le_text_equals, driven through
le_paste_consume), history suppression for mid-paste line fragments
(le_finish_line), completion capacity growth past the old 64-candidate
truncation (le_try_complete), le_search_step's pushback of a
search-ending key, the ESC-sequence probe that keeps an arrow key
during Ctrl-R from half-cancelling into literal "[A" text, and
le_paste_finish's render of a pasted line before it is accepted (a
multi-line paste used to show one bare newline per line).

Canonical-mode terminal input cannot be scripted through a plain pipe
(the documented script -qc limitation), so these tests drive the
tty-only paths through le_getchar's pushback stack instead: preloading
the stack makes it the input source, and every test consumes exactly
what it preloads, so no test ever falls through to a real read of
stdin.
*/
import lib.lib
import lib.assert
import lib.file
import lib.line_edit
import structures.string


# Preload s so consecutive le_getchar() calls deliver its bytes front to
# back (the LIFO stack is pushed in reverse).
void letest_preload(char* s):
	int n = strlen(s)
	while (n > 0):
		n = n - 1
		le_pushback(s[n])


# Silence stdout around calls that render (candidate listings,
# le_finish_line's echoes) so the test log stays readable.
int letest_saved_stdout

void letest_silence_stdout():
	letest_saved_stdout = 90
	dup2(1, letest_saved_stdout)
	int devnull = open(c"/dev/null", 1, 0)
	dup2(devnull, 1)
	close(devnull)


void letest_restore_stdout():
	dup2(letest_saved_stdout, 1)
	close(letest_saved_stdout)


# Capture stdout into a pid-scoped file under bin/ (pid-scoped so the
# 32/64-bit twins can't race on it -- the format_test lesson) so a test
# can assert on rendered escape-sequence output.
char* letest_capture_path_cache

char* letest_capture_path():
	if (letest_capture_path_cache == 0):
		mkdir(c"bin", 493)
		string_builder* p = string_new()
		string_append(p, c"bin/line_edit_paste_test_")
		string_append_int(p, getpid())
		string_append(p, c".txt")
		letest_capture_path_cache = p.data
		free(p)
	return letest_capture_path_cache


void letest_capture_start():
	letest_saved_stdout = 90
	dup2(1, letest_saved_stdout)
	int fd = create_file(letest_capture_path(), 420)
	dup2(fd, 1)
	close(fd)


# Restore stdout and return the captured bytes (malloc'd).
char* letest_capture_stop():
	dup2(letest_saved_stdout, 1)
	close(letest_saved_stdout)
	return file_read_text(letest_capture_path())


void test_pushback_pops_in_reverse_push_order():
	assert_equal(0, le_pushback_len)
	le_pushback('b')
	le_pushback('a')
	assert_equal(2, le_pushback_len)
	assert_equal('a', le_getchar())
	assert_equal('b', le_getchar())
	assert_equal(0, le_pushback_len)


void test_preload_delivers_bytes_in_order():
	letest_preload(c"abc")
	assert_equal('a', le_getchar())
	assert_equal('b', le_getchar())
	assert_equal('c', le_getchar())
	assert_equal(0, le_pushback_len)


void test_paste_end_marker_bytes():
	assert_equal('[', le_paste_end_marker(0))
	assert_equal('2', le_paste_end_marker(1))
	assert_equal('0', le_paste_end_marker(2))
	assert_equal('1', le_paste_end_marker(3))
	assert_equal('~', le_paste_end_marker(4))
	assert_equal(-1, le_paste_end_marker(5))
	assert_equal(-1, le_paste_end_marker(-1))


void test_paste_match_end_full_match_consumes_marker():
	letest_preload(c"[201~")
	assert_equal(1, le_paste_match_end())
	assert_equal(0, le_pushback_len)


void test_paste_match_end_mismatch_pushes_probed_bytes_back():
	# A paste byte run that merely starts like the end marker: the probe
	# used to consume and drop "[20X"; now every probed byte re-enters
	# the stream in arrival order, ahead of the untouched "rest".
	letest_preload(c"[20Xrest")
	assert_equal(0, le_paste_match_end())
	assert_equal('[', le_getchar())
	assert_equal('2', le_getchar())
	assert_equal('0', le_getchar())
	assert_equal('X', le_getchar())
	assert_equal('r', le_getchar())
	assert_equal('e', le_getchar())
	assert_equal('s', le_getchar())
	assert_equal('t', le_getchar())
	assert_equal(0, le_pushback_len)


void test_paste_match_end_immediate_mismatch():
	letest_preload(c"A")
	assert_equal(0, le_paste_match_end())
	assert_equal('A', le_getchar())
	assert_equal(0, le_pushback_len)


void test_paste_eat_crlf():
	# CR followed by LF: the pending LF is consumed with it.
	letest_preload(c"\x0a")
	le_paste_eat_crlf(13)
	assert_equal(0, le_pushback_len)
	# CR followed by anything else: that byte is real input, un-read it.
	letest_preload(c"z")
	le_paste_eat_crlf(13)
	assert_equal(1, le_pushback_len)
	assert_equal('z', le_getchar())
	# A bare LF line ending reads nothing at all.
	letest_preload(c"z")
	le_paste_eat_crlf(10)
	assert_equal(1, le_pushback_len)
	assert_equal('z', le_getchar())


void test_text_equals_is_byte_exact():
	assert_equal(1, le_text_equals(c"\x09abc", 1, c"\x09"))
	# Same length, different bytes: the case the old length-only
	# comparison got wrong (typed text silently discarded on paste).
	assert_equal(0, le_text_equals(c"x", 1, c"\x09"))
	assert_equal(0, le_text_equals(c"\x09\x09", 2, c"\x09"))
	assert_equal(0, le_text_equals(c"\x09", 1, c"\x09\x09"))
	assert_equal(1, le_text_equals(c"", 0, c""))


void test_paste_consume_preserves_non_marker_escape_content():
	char* buf = malloc(64)
	le_set_line(buf, 64, c"")
	le_seed_len = 0
	le_paste_active = 0
	# "a", then ESC "[2q" (not the end marker), then the real marker.
	# The ESC itself is dropped (as before), but "[2q" is pasted content
	# the old code dropped along with it.
	letest_preload(c"a\x1b[2q\x1b[201~")
	assert_equal(0, le_paste_consume(buf, 64))
	assert_equal(0, le_paste_active)
	buf[le_len] = 0
	assert_strings_equal(c"a[2q", buf)
	assert_equal(0, le_pushback_len)
	free(buf)


void test_paste_consume_crlf_ends_one_line_without_a_blank_accept():
	char* buf = malloc(64)
	le_set_line(buf, 64, c"")
	le_seed_len = 0
	letest_preload(c"hi\x0d\x0a\x1b[201~")
	# The CR ends the line; the LF is consumed with it.
	assert_equal(1, le_paste_consume(buf, 64))
	assert_equal(1, le_paste_active)
	buf[le_len] = 0
	assert_strings_equal(c"hi", buf)
	# Resume, as line_edit_read would: the next byte is the end marker
	# directly -- no spurious empty accept for the LF half.
	le_set_line(buf, 64, c"")
	assert_equal(0, le_paste_consume(buf, 64))
	assert_equal(0, le_paste_active)
	assert_equal(0, le_len)
	assert_equal(0, le_pushback_len)
	free(buf)


void test_paste_consume_drops_only_the_untouched_seed():
	char* buf = malloc(64)
	# The auto-indent seed, untouched: dropped so it does not double up
	# with the pasted text's own indentation.
	le_set_line(buf, 64, c"\x09")
	le_seed_len = 1
	if (le_seed_text != 0):
		free(le_seed_text)
	le_seed_text = strclone(c"\x09")
	letest_preload(c"x\x1b[201~")
	assert_equal(0, le_paste_consume(buf, 64))
	buf[le_len] = 0
	assert_strings_equal(c"x", buf)

	# Typed text of the same length as the seed: kept (the old
	# length-only comparison discarded it).
	le_set_line(buf, 64, c"q")
	le_seed_len = 1
	letest_preload(c"x\x1b[201~")
	assert_equal(0, le_paste_consume(buf, 64))
	buf[le_len] = 0
	assert_strings_equal(c"qx", buf)
	assert_equal(0, le_pushback_len)
	free(le_seed_text)
	le_seed_text = 0
	le_seed_len = 0
	free(buf)


void test_finish_line_skips_history_while_paste_is_open():
	le_history_count = 0
	char* buf = malloc(64)
	# A mid-paste line fragment (the paste is still open): no history.
	le_set_line(buf, 64, c"pasted fragment")
	le_paste_active = 1
	letest_silence_stdout()
	le_finish_line(buf)
	letest_restore_stdout()
	assert_equal(0, le_history_count)
	# A line finished after the paste closed: recorded as always.
	le_set_line(buf, 64, c"typed line")
	le_paste_active = 0
	letest_silence_stdout()
	le_finish_line(buf)
	letest_restore_stdout()
	assert_equal(1, le_history_count)
	assert_strings_equal(c"typed line", le_history_at(0))
	free(buf)


# Completion hook returning 70 candidates: the first 64 share
# "prefix_aa", the last 6 only "prefix_" -- so a set truncated at the
# old fixed capacity of 64 lists too few names AND computes a common
# prefix ("prefix_aa") longer than the true one ("prefix_"),
# over-inserting bytes not shared by the unseen candidates.
int letest_hook_calls

int letest_complete_hook(char* prefix, char* out, int capacity):
	letest_hook_calls = letest_hook_calls + 1
	int total = 70
	int count = 0
	while ((count < total) && (count < capacity)):
		char* num = itoa(count)
		char* name = 0
		if (count < 64):
			name = strjoin(c"prefix_aa", num)
		else:
			name = strjoin(c"prefix_b", num)
		save_word(out + count * __word_size__, cast(int, name))
		free(num)
		count = count + 1
	return count


int letest_single_hook(char* prefix, char* out, int capacity):
	save_word(out, cast(int, strclone(c"prefix_only")))
	return 1


void test_completion_grows_past_64_candidates():
	char* buf = malloc(256)
	le_set_line(buf, 256, c"prefix_")
	le_complete_hook = cast(int, letest_complete_hook)
	letest_hook_calls = 0
	letest_silence_stdout()
	int r = le_try_complete(buf, 256)
	letest_restore_stdout()
	le_complete_hook = 0
	assert_equal(1, r)
	# The 64-slot first call comes back full (possible truncation), so
	# the editor retries once at 128 slots and sees all 70.
	assert_equal(2, letest_hook_calls)
	# True common prefix of all 70 is exactly what was typed: nothing
	# inserted (the truncated set would have appended "aa").
	buf[le_len] = 0
	assert_strings_equal(c"prefix_", buf)
	free(buf)


void test_completion_single_candidate_still_completes_outright():
	char* buf = malloc(256)
	le_set_line(buf, 256, c"prefix_")
	le_complete_hook = cast(int, letest_single_hook)
	int r = le_try_complete(buf, 256)
	le_complete_hook = 0
	assert_equal(1, r)
	buf[le_len] = 0
	assert_strings_equal(c"prefix_only", buf)
	free(buf)


void test_search_step_pushes_back_the_search_ending_key():
	le_history_count = 0
	le_history_add(c"int alpha = 1")
	char* buf = malloc(64)
	le_set_line(buf, 64, c"")
	le_search_begin(buf)
	# Ctrl-T has no search meaning: it ends the search and must be
	# re-delivered through the pushback stack (the old getchar_pos
	# stepping could un-read the wrong byte once pushback existed).
	assert_equal(0, le_search_step(buf, 64, 20))
	assert_equal(0, le_search_active)
	assert_equal(1, le_pushback_len)
	assert_equal(20, le_getchar())
	buf[le_len] = 0
	assert_strings_equal(c"int alpha = 1", buf)
	free(buf)


void test_paste_finish_renders_the_pasted_line():
	char* buf = malloc(64)
	le_set_line(buf, 64, c"")
	le_seed_len = 0
	le_paste_active = 0
	le_prev_rows = 1
	le_history_count = 0
	# One pasted line ended by an embedded CR; the paste stays open (the
	# end marker arrives later).
	letest_preload(c"pasted()\x0d\x1b[201~")
	assert_equal(1, le_paste_consume(buf, 64))
	assert_equal(1, le_paste_active)
	letest_capture_start()
	int n = le_paste_finish(c"w> ", buf)
	char* out = letest_capture_stop()
	assert_equal(8, n)
	# The completed line is drawn (prompt + pasted text) before the
	# newline -- finishing without the render left only the bare newline.
	assert_equal(1, le_str_contains(out, c"w> pasted()"))
	assert_equal(10, out[strlen(out) - 1])
	# le_finish_line's mid-paste history suppression still applies.
	assert_equal(0, le_history_count)
	free(out)
	# Resume, as the next line_edit_read call would: only the end marker
	# is left, closing the paste.
	le_set_line(buf, 64, c"")
	assert_equal(0, le_paste_consume(buf, 64))
	assert_equal(0, le_paste_active)
	assert_equal(0, le_pushback_len)
	free(buf)


void test_search_step_esc_sequence_ends_search_and_redelivers_it():
	le_history_count = 0
	le_history_add(c"int alpha = 1")
	char* buf = malloc(64)
	le_set_line(buf, 64, c"")
	le_search_begin(buf)
	assert_equal(0, le_search_match)
	# An arrow key arrives as ESC then "[A". The old code cancelled on
	# the bare ESC (restoring the pre-search line) and the residual "[A"
	# was inserted as literal text.
	letest_preload(c"[A")
	assert_equal(0, le_search_step(buf, 64, 27))
	assert_equal(0, le_search_active)
	# Not a cancel: the current match became the live buffer...
	buf[le_len] = 0
	assert_strings_equal(c"int alpha = 1", buf)
	# ...and the whole sequence is re-delivered, ESC first, for the
	# ordinary dispatch loop to handle as one arrow key.
	assert_equal(27, le_getchar())
	assert_equal('[', le_getchar())
	assert_equal('A', le_getchar())
	assert_equal(0, le_pushback_len)
	free(buf)


void test_search_step_lone_esc_still_cancels():
	le_history_count = 0
	le_history_add(c"int alpha = 1")
	char* buf = malloc(64)
	le_set_line(buf, 64, c"typed")
	le_search_begin(buf)
	# ESC followed by ordinary typed input: a lone-ESC cancel. The byte
	# probed to identify the sequence is real input, re-delivered intact.
	letest_preload(c"x")
	assert_equal(0, le_search_step(buf, 64, 27))
	assert_equal(0, le_search_active)
	buf[le_len] = 0
	assert_strings_equal(c"typed", buf)
	assert_equal('x', le_getchar())
	assert_equal(0, le_pushback_len)
	free(buf)


int main():
	test_pushback_pops_in_reverse_push_order()
	test_preload_delivers_bytes_in_order()
	test_paste_end_marker_bytes()
	test_paste_match_end_full_match_consumes_marker()
	test_paste_match_end_mismatch_pushes_probed_bytes_back()
	test_paste_match_end_immediate_mismatch()
	test_paste_eat_crlf()
	test_text_equals_is_byte_exact()
	test_paste_consume_preserves_non_marker_escape_content()
	test_paste_consume_crlf_ends_one_line_without_a_blank_accept()
	test_paste_consume_drops_only_the_untouched_seed()
	test_finish_line_skips_history_while_paste_is_open()
	test_completion_grows_past_64_candidates()
	test_completion_single_candidate_still_completes_outright()
	test_search_step_pushes_back_the_search_ending_key()
	test_paste_finish_renders_the_pasted_line()
	test_search_step_esc_sequence_ends_search_and_redelivers_it()
	test_search_step_lone_esc_still_cancels()
	println(c"line_edit_paste_test passed")
	return 0
