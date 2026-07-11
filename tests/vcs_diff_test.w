# wbuild: x64
import lib.testing
import structures.string
import libs.extras.vcs.diff


# The property that matters for merge3.w later (docs/projects/
# version_control.md, Wave 4): applying a diff_result's hunks to the old
# text must reconstruct the new text exactly, byte for byte (including
# trailing-newline presence).
void assert_reconstructs(char* old_text, char* new_text, int context):
	diff_input* old_input = diff_read_text(old_text)
	diff_input* new_input = diff_read_text(new_text)
	diff_result* result = diff_lines(old_input.lines, old_input.no_newline, new_input.lines, new_input.no_newline, context)
	diff_apply_result* applied = diff_apply(old_input.lines, old_input.no_newline, result)
	char* reconstructed = diff_join_lines(applied.lines, applied.no_newline)
	assert_strings_equal(new_text, reconstructed)
	free(reconstructed)


void assert_reconstructs_default(char* old_text, char* new_text):
	assert_reconstructs(old_text, new_text, diff_default_context())


# --- identical inputs -------------------------------------------------------

void test_diff_identical_empty():
	diff_result* result = diff_text(c"", c"", diff_default_context())
	assert_equal(1, diff_is_identical(result))
	assert_equal(0, result.hunks.length)
	assert_reconstructs_default(c"", c"")


void test_diff_identical_content():
	char* text = c"alpha\nbeta\ngamma\n"
	diff_result* result = diff_text(text, text, diff_default_context())
	assert_equal(1, diff_is_identical(result))
	assert_strings_equal(c"", diff_render_unified_text(c"a", c"b", result))
	assert_reconstructs_default(text, text)


# --- pure insertion / deletion ----------------------------------------------

void test_diff_pure_insertion_into_empty():
	char* old_text = c""
	char* new_text = c"one\ntwo\n"
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	assert_equal(0, diff_is_identical(result))
	assert_equal(1, result.hunks.length)
	diff_hunk* hunk = result.hunks[0]
	assert_equal(0, hunk.old_start)
	assert_equal(0, hunk.old_len)
	assert_equal(0, hunk.new_start)
	assert_equal(2, hunk.new_len)
	assert_reconstructs_default(old_text, new_text)


void test_diff_pure_deletion_to_empty():
	char* old_text = c"one\ntwo\nthree\n"
	char* new_text = c""
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	assert_equal(0, diff_is_identical(result))
	assert_equal(1, result.hunks.length)
	diff_hunk* hunk = result.hunks[0]
	assert_equal(3, hunk.old_len)
	assert_equal(0, hunk.new_len)
	assert_reconstructs_default(old_text, new_text)


void test_diff_append_lines():
	# The 3-line unchanged prefix is exactly the default context, so the
	# whole old file appears as leading context rather than being
	# trimmed away.
	char* old_text = c"a\nb\nc\n"
	char* new_text = c"a\nb\nc\nd\ne\n"
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	assert_equal(1, result.hunks.length)
	diff_hunk* hunk = result.hunks[0]
	assert_equal(0, hunk.old_start)
	assert_equal(3, hunk.old_len)
	assert_equal(0, hunk.new_start)
	assert_equal(5, hunk.new_len)
	assert_reconstructs_default(old_text, new_text)


void test_diff_append_lines_far_from_start():
	# With a longer unchanged prefix, the leading context is trimmed to
	# exactly 'context' lines and the hunk starts partway through the
	# old file.
	char* old_text = c"a\nb\nc\nd\ne\nf\ng\n"
	char* new_text = c"a\nb\nc\nd\ne\nf\ng\nh\ni\n"
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	assert_equal(1, result.hunks.length)
	diff_hunk* hunk = result.hunks[0]
	assert_equal(4, hunk.old_start)
	assert_equal(3, hunk.old_len)
	assert_equal(4, hunk.new_start)
	assert_equal(5, hunk.new_len)
	assert_reconstructs_default(old_text, new_text)


# --- mid-file edits ----------------------------------------------------------

void test_diff_mid_file_edit():
	char* old_text = c"alpha\nbeta\ngamma\ndelta\n"
	char* new_text = c"alpha\nBETA\ngamma\ndelta\nepsilon\n"
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	assert_equal(1, result.hunks.length)
	diff_hunk* hunk = result.hunks[0]
	assert_equal(0, hunk.old_start)
	assert_equal(4, hunk.old_len)
	assert_equal(0, hunk.new_start)
	assert_equal(5, hunk.new_len)
	assert_reconstructs_default(old_text, new_text)


void test_diff_completely_different():
	char* old_text = c"one\ntwo\nthree\n"
	char* new_text = c"uno\ndos\ntres\ncuatro\n"
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	assert_equal(1, result.hunks.length)
	diff_hunk* hunk = result.hunks[0]
	assert_equal(3, hunk.old_len)
	assert_equal(4, hunk.new_len)
	assert_reconstructs_default(old_text, new_text)


# --- hunk merging under context ----------------------------------------------

# Builds "1\n2\n...\nn\n" with 1-based line numbers as text, replacing the
# (1-based) lines in 'changed' with "CHANGED<n>".
char* vcs_diff_test_numbered_lines(int n, list[int] changed):
	string_builder* s = string_new()
	for int i in range(n):
		int line_no = i + 1
		int is_changed = 0
		for int c in changed:
			if (c == line_no):
				is_changed = 1
		if (is_changed):
			string_append(s, c"CHANGED")
		string_append_int(s, line_no)
		string_append_char(s, 10)
	char* text = s.data
	free(s)
	return text


void test_diff_adjacent_changes_merge_into_one_hunk():
	# Two single-line changes 6 lines apart (default context = 3, so the
	# gap of 5 unchanged lines between them is <= 2*context): GNU diff
	# merges these into a single hunk, and so should we.
	char* old_text = vcs_diff_test_numbered_lines(20, list[int]{})
	char* new_text = vcs_diff_test_numbered_lines(20, list[int]{3, 9})
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	assert_equal(1, result.hunks.length)
	assert_reconstructs_default(old_text, new_text)


void test_diff_far_changes_stay_in_separate_hunks():
	# Two single-line changes far enough apart that their contexts do not
	# overlap: two distinct hunks.
	char* old_text = vcs_diff_test_numbered_lines(50, list[int]{})
	char* new_text = vcs_diff_test_numbered_lines(50, list[int]{3, 41})
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	assert_equal(2, result.hunks.length)
	assert_reconstructs_default(old_text, new_text)


# --- no-trailing-newline edges -----------------------------------------------

void test_diff_old_missing_trailing_newline():
	char* old_text = c"foo\nbar"
	char* new_text = c"foo\nbar\n"
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	assert_equal(0, diff_is_identical(result))
	assert_reconstructs_default(old_text, new_text)
	char* rendered = diff_render_unified_text(c"old", c"new", result)
	assert_strings_equal(c"--- old\n+++ new\n@@ -1,2 +1,2 @@\n foo\n-bar\n\\ No newline at end of file\n+bar\n", rendered)


void test_diff_new_missing_trailing_newline():
	char* old_text = c"foo\nbar\n"
	char* new_text = c"foo\nbar"
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	assert_equal(0, diff_is_identical(result))
	assert_reconstructs_default(old_text, new_text)
	char* rendered = diff_render_unified_text(c"old", c"new", result)
	assert_strings_equal(c"--- old\n+++ new\n@@ -1,2 +1,2 @@\n foo\n-bar\n+bar\n\\ No newline at end of file\n", rendered)


void test_diff_both_missing_trailing_newline_are_identical():
	# Same text, both missing the final newline: truly identical files.
	char* text = c"foo\nbar"
	diff_result* result = diff_text(text, text, diff_default_context())
	assert_equal(1, diff_is_identical(result))
	assert_reconstructs_default(text, text)


void test_diff_missing_newline_helper():
	assert_equal(0, diff_missing_newline(c""))
	assert_equal(0, diff_missing_newline(c"a\n"))
	assert_equal(1, diff_missing_newline(c"a"))
	assert_equal(1, diff_missing_newline(c"a\nb"))


void test_diff_split_lines_helper():
	list[char*] lines = diff_split_lines(c"a\nb\nc")
	assert_equal(3, lines.length)
	assert_strings_equal(c"a", lines[0])
	assert_strings_equal(c"b", lines[1])
	assert_strings_equal(c"c", lines[2])

	list[char*] empty_lines = diff_split_lines(c"")
	assert_equal(0, empty_lines.length)

	list[char*] trailing = diff_split_lines(c"a\nb\n")
	assert_equal(2, trailing.length)


# --- unified rendering: small, stable golden cases ---------------------------

void test_diff_unified_rendering_golden_replace():
	char* old_text = c"one\ntwo\nthree\n"
	char* new_text = c"one\nTWO\nthree\n"
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	char* rendered = diff_render_unified_text(c"a.txt", c"b.txt", result)
	assert_strings_equal(c"--- a.txt\n+++ b.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n", rendered)


void test_diff_unified_rendering_golden_insert_at_start():
	char* old_text = c"one\ntwo\n"
	char* new_text = c"zero\none\ntwo\n"
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	char* rendered = diff_render_unified_text(c"a.txt", c"b.txt", result)
	assert_strings_equal(c"--- a.txt\n+++ b.txt\n@@ -1,2 +1,3 @@\n+zero\n one\n two\n", rendered)


void test_diff_unified_rendering_golden_pure_insertion_header():
	# old_len == 0: the header's old side shows the 0-based gap position,
	# not a 1-based line number (GNU diff convention).
	char* old_text = c""
	char* new_text = c"only\n"
	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	char* rendered = diff_render_unified_text(c"a.txt", c"b.txt", result)
	assert_strings_equal(c"--- a.txt\n+++ b.txt\n@@ -0,0 +1 @@\n+only\n", rendered)


void test_diff_unified_rendering_golden_identical_is_empty():
	char* text = c"same\n"
	diff_result* result = diff_text(text, text, diff_default_context())
	char* rendered = diff_render_unified_text(c"a.txt", c"b.txt", result)
	assert_strings_equal(c"", rendered)


void test_diff_format_range_helper():
	char* single = diff_format_range(0, 1)
	assert_strings_equal(c"1", single)
	char* multi = diff_format_range(0, 3)
	assert_strings_equal(c"1,3", multi)
	char* zero_len = diff_format_range(5, 0)
	assert_strings_equal(c"5,0", zero_len)
