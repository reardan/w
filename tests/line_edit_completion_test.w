/*
Pure-logic unit tests for two of wave 3a's #276 P2 REPL editor features
(lib/line_edit.w): the Tab-completion helpers (identifier-boundary
scanning, common-prefix computation) and the Ctrl-R incremental
reverse-search state machine. Both are driven here exactly the way
line_edit_read's key dispatch drives them (le_try_complete,
le_search_step) -- just without a tty or getchar(), so this runs the
same everywhere.

Bracketed paste and the actual keystroke-by-keystroke tty behavior of
Tab/Ctrl-R are covered by the script(1)-driven repl_test/repl_test_x64
cases in build.base.json; Ctrl-R itself cannot be scripted that way
because script -qc delivers piped stdin in one burst, racing ahead of
repl_init()'s startup -- the kernel's still-canonical line discipline at
that instant treats Ctrl-R as VREPRINT and silently drops the byte before
the process ever sees it. That is a test-harness limitation, not a bug in
the feature: this file's test_reverse_search_state below drives the exact
same state transitions le_search_step performs per keystroke, and the
marker-synchronized pty harness (tools/pty_test.py running
tests/repl_pty_ctrl_r.pty, build.base.json's repl_pty_test target)
scripts the tty integration end to end. This file also asserts
le_render_search's climb over a wrapped previous render, via a
capture-stdout-to-file seam.
*/
import lib.lib
import lib.assert
import lib.file
import lib.line_edit
import structures.string


void test_ident_char():
	assert_equal(1, le_is_ident_char('a'))
	assert_equal(1, le_is_ident_char('Z'))
	assert_equal(1, le_is_ident_char('5'))
	assert_equal(1, le_is_ident_char('_'))
	assert_equal(0, le_is_ident_char(' '))
	assert_equal(0, le_is_ident_char('('))
	assert_equal(0, le_is_ident_char('.'))


void test_ident_start():
	char* s = c"foo.bar_baz"
	# The identifier ending at the string's end starts right after the '.'
	assert_equal(4, le_ident_start(s, 11))
	# Ending mid-word
	assert_equal(4, le_ident_start(s, 7))
	# Nothing identifier-like to the left of position 0
	assert_equal(0, le_ident_start(s, 0))
	assert_equal(0, le_ident_start(c"myvar", 5))


void test_candidates_common_len():
	char* out = malloc(4 * __word_size__)
	save_word(out + 0 * __word_size__, cast(int, c"printf1"))
	save_word(out + 1 * __word_size__, cast(int, c"printf2"))
	assert_equal(6, le_candidates_common_len(out, 2)) /* "printf" */

	save_word(out + 2 * __word_size__, cast(int, c"print_error"))
	assert_equal(5, le_candidates_common_len(out, 3)) /* "print" */

	assert_equal(0, le_candidates_common_len(out, 0))

	save_word(out + 3 * __word_size__, cast(int, c"printf1"))
	assert_equal(7, le_candidates_common_len(out, 1)) /* the whole name */
	free(out)


void test_str_contains():
	assert_equal(1, le_str_contains(c"int ctrlr_probe = 77", c"ctrlr_probe"))
	assert_equal(1, le_str_contains(c"int ctrlr_probe = 77", c""))
	assert_equal(0, le_str_contains(c"int ctrlr_probe = 77", c"nope"))
	assert_equal(1, le_str_contains(c"abc", c"abc"))
	assert_equal(0, le_str_contains(c"ab", c"abc"))


# Capture stdout into a pid-scoped file under bin/ (pid-scoped so the
# 32/64-bit twins can't race on it) to assert on rendered escape output.
char* lect_capture_path_cache
int lect_saved_stdout

char* lect_capture_path():
	if (lect_capture_path_cache == 0):
		mkdir(c"bin", 493)
		string_builder* p = string_new()
		string_append(p, c"bin/line_edit_completion_test_")
		string_append_int(p, getpid())
		string_append(p, c".txt")
		lect_capture_path_cache = p.data
		free(p)
	return lect_capture_path_cache


void lect_capture_start():
	lect_saved_stdout = 90
	dup2(1, lect_saved_stdout)
	int fd = create_file(lect_capture_path(), 420)
	dup2(fd, 1)
	close(fd)


char* lect_capture_stop():
	dup2(lect_saved_stdout, 1)
	close(lect_saved_stdout)
	return file_read_text(lect_capture_path())


# le_render_search used to repaint from the cursor's row only: starting
# a search while the edited line wrapped left the wrapped rows above the
# cursor on screen as stale text. It now climbs le_prev_rows first, the
# way le_render does.
void test_render_search_climbs_wrapped_rows():
	le_history_count = 0
	le_history_add(c"int wrapped = 1")
	char* buf = malloc(64)
	buf[0] = 0
	le_search_begin(buf)
	le_prev_rows = 3
	lect_capture_start()
	le_render_search()
	char* out = lect_capture_stop()
	# Climb the two extra rows the wrapped line occupied ("\x1b[2A"),
	# then CR + clear-to-end-of-screen repaints the whole block.
	assert_equal(27, out[0])
	assert_equal('[', out[1])
	assert_equal('2', out[2])
	assert_equal('A', out[3])
	assert_equal(13, out[4])
	assert_equal(1, le_str_contains(out, c"(reverse-i-search)'': int wrapped = 1"))
	assert_equal(1, le_prev_rows)
	free(out)
	# The search row itself stays single-row: a second render (or an
	# unwrapped previous line) climbs nothing.
	lect_capture_start()
	le_render_search()
	out = lect_capture_stop()
	assert_equal(13, out[0])
	le_search_end_state()
	free(out)
	free(buf)


# Drives the same le_search_begin/le_search_refine/le_search_older/
# le_search_backspace calls le_search_step makes per keystroke, without
# needing a tty or getchar() at all.
void test_reverse_search_state():
	le_history_count = 0
	le_history_add(c"int alpha = 1")
	le_history_add(c"int beta = 2")
	le_history_add(c"int alpha_beta = 3")

	char* buf = malloc(64)
	buf[0] = 0
	le_search_begin(buf)
	# Empty query: matches the newest entry
	assert_equal(2, le_search_match)
	assert_strings_equal(c"int alpha_beta = 3", le_history_at(le_search_match))

	# Type "alpha": still the newest entry (it contains "alpha" too)
	le_search_query[0] = 'a'
	le_search_query[1] = 'l'
	le_search_query[2] = 'p'
	le_search_query[3] = 'h'
	le_search_query[4] = 'a'
	le_search_query[5] = 0
	le_search_qlen = 5
	le_search_refine()
	assert_equal(2, le_search_match)

	# Ctrl-R again: the only older match is entry 0
	le_search_older()
	assert_equal(0, le_search_match)
	assert_strings_equal(c"int alpha = 1", le_history_at(le_search_match))

	# One more Ctrl-R: nothing older than entry 0 matches "alpha"
	le_search_older()
	assert_equal(-1, le_search_match)

	# Backspace to "alph": restarts from the newest entry again
	le_search_backspace()
	assert_equal(4, le_search_qlen)
	assert_equal(2, le_search_match)
	assert_strings_equal(c"int alpha_beta = 3", le_history_at(le_search_match))

	le_search_end_state()
	assert_equal(0, le_search_active)
	free(buf)


int main():
	test_ident_char()
	test_ident_start()
	test_candidates_common_len()
	test_str_contains()
	test_render_search_climbs_wrapped_rows()
	test_reverse_search_state()
	println(c"line_edit_completion_test passed")
	return 0
