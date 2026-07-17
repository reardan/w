# wbuild: x64
/*
Tests for libs/extras/vcs/merge3.w (issue #252 wave 4): clean disjoint
merges, identical-change coalescing, conflicting overlapping changes
(with exact 7-character git-compatible markers), ours-only/theirs-only
edges, empty-file edges, conflict counting, and the trailing-newline
edge case merge3_merge's header comment calls out explicitly.
*/
import lib.testing
import structures.string
import libs.extras.vcs.diff
import libs.extras.vcs.merge3


void assert_merge_text(char* want_text, int want_conflicts, char* base, char* ours, char* theirs):
	merge3_text_result* r = merge3_merge_text(base, ours, theirs, 0, 0)
	assert_strings_equal(want_text, r.text)
	assert_equal(want_conflicts, r.conflicts)
	free(r.text)
	free(r)


int wvct_contains(char* haystack, char* needle):
	int hl = strlen(haystack)
	int nl = strlen(needle)
	if (nl == 0):
		return 1
	int i = 0
	while ((i + nl) <= hl):
		int j = 0
		while ((j < nl) && (haystack[i + j] == needle[j])):
			j = j + 1
		if (j == nl):
			return 1
		i = i + 1
	return 0


void wvct_assert_conflict_labels(char* text):
	assert1(wvct_contains(text, c"<<<<<<< feature"))
	assert1(wvct_contains(text, c">>>>>>> main"))


# --- clean, non-overlapping changes -----------------------------------------


void test_disjoint_changes_apply_cleanly():
	# ours touches the first line, theirs touches the last -- no overlap.
	assert_merge_text(c"A\nb\nC\n", 0, c"a\nb\nc\n", c"A\nb\nc\n", c"a\nb\nC\n")


void test_ours_only_change_theirs_unchanged():
	assert_merge_text(c"x\ny\nZ\n", 0, c"x\ny\nz\n", c"x\ny\nZ\n", c"x\ny\nz\n")


void test_theirs_only_change_ours_unchanged():
	assert_merge_text(c"x\ny\nZ\n", 0, c"x\ny\nz\n", c"x\ny\nz\n", c"x\ny\nZ\n")


void test_ours_insertion_theirs_deletion_disjoint():
	char* base = c"a\nb\nc\nd\ne\n"
	# ours inserts after "a"; theirs deletes "e" from the end -- disjoint
	# regions, both apply.
	char* ours = c"a\nNEW\nb\nc\nd\ne\n"
	char* theirs = c"a\nb\nc\nd\n"
	assert_merge_text(c"a\nNEW\nb\nc\nd\n", 0, base, ours, theirs)


void test_both_sides_unchanged_is_identical_to_base():
	assert_merge_text(c"same\ntext\n", 0, c"same\ntext\n", c"same\ntext\n", c"same\ntext\n")


# --- identical changes coalesce ---------------------------------------------


void test_identical_line_change_coalesces():
	assert_merge_text(c"a\nX\nc\n", 0, c"a\nb\nc\n", c"a\nX\nc\n", c"a\nX\nc\n")


void test_identical_insertion_coalesces():
	char* base = c"a\nb\n"
	char* changed = c"a\nNEW\nb\n"
	assert_merge_text(changed, 0, base, changed, changed)


void test_both_sides_delete_same_content_coalesces():
	# Both delete "b" -- agree, not a conflict.
	assert_merge_text(c"a\nc\n", 0, c"a\nb\nc\n", c"a\nc\n", c"a\nc\n")


# --- overlapping, differing changes: conflicts ------------------------------


void test_conflicting_line_change_uses_standard_markers():
	char* want = c"a\n<<<<<<< ours\nX\n=======\nY\n>>>>>>> theirs\nc\n"
	assert_merge_text(want, 1, c"a\nb\nc\n", c"a\nX\nc\n", c"a\nY\nc\n")


void test_conflict_markers_are_exactly_seven_characters():
	merge3_text_result* r = merge3_merge_text(c"a\nb\nc\n", c"a\nX\nc\n", c"a\nY\nc\n", 0, 0)
	list[char*] lines = diff_split_lines(r.text)
	# lines: "a", "<<<<<<< ours", "X", "=======", "Y", ">>>>>>> theirs", "c"
	assert_equal(7, lines.length)
	assert_strings_equal(c"<<<<<<< ours", lines[1])
	assert_strings_equal(c"=======", lines[3])
	assert_strings_equal(c">>>>>>> theirs", lines[5])
	# The marker prefixes themselves (before any label) are exactly 7
	# characters -- git's own convention.
	assert_equal(7, strlen(c"<<<<<<<"))
	assert_equal(7, strlen(c"======="))
	assert_equal(7, strlen(c">>>>>>>"))
	for char* l in lines:
		free(l)
	list_free[char*](lines)
	free(r.text)
	free(r)


void test_conflict_custom_labels():
	merge3_text_result* r = merge3_merge_text(c"a\nb\nc\n", c"a\nX\nc\n", c"a\nY\nc\n", c"feature", c"main")
	wvct_assert_conflict_labels(r.text)
	free(r.text)
	free(r)


void test_two_separate_conflicts_counted_separately():
	char* base = c"1\n2\n3\n4\n5\n"
	char* ours = c"ONE\n2\n3\n4\nFIVE\n"
	char* theirs = c"UNO\n2\n3\n4\nCINCO\n"
	merge3_text_result* r = merge3_merge_text(base, ours, theirs, 0, 0)
	assert_equal(2, r.conflicts)
	assert1(wvct_contains(r.text, c"<<<<<<< ours\nONE\n=======\nUNO\n>>>>>>> theirs"))
	assert1(wvct_contains(r.text, c"<<<<<<< ours\nFIVE\n=======\nCINCO\n>>>>>>> theirs"))
	free(r.text)
	free(r)


void test_adjacent_conflicting_changes_form_one_conflict():
	# Both sides touch consecutive lines 2 and 3 differently -- this is
	# ONE conflicting gap (a "conflict" is a region, not a line), not two.
	char* base = c"1\n2\n3\n4\n"
	char* ours = c"1\nA\nB\n4\n"
	char* theirs = c"1\nC\nD\n4\n"
	merge3_text_result* r = merge3_merge_text(base, ours, theirs, 0, 0)
	assert_equal(1, r.conflicts)
	free(r.text)
	free(r)


# --- ours-only / theirs-only / empty-file edges -----------------------------


void test_empty_base_ours_adds_theirs_unchanged():
	assert_merge_text(c"hello\n", 0, c"", c"hello\n", c"")


void test_empty_base_theirs_adds_ours_unchanged():
	assert_merge_text(c"hello\n", 0, c"", c"", c"hello\n")


void test_empty_base_both_add_identical_content():
	assert_merge_text(c"same\n", 0, c"", c"same\n", c"same\n")


void test_empty_base_both_add_different_content_conflicts():
	merge3_text_result* r = merge3_merge_text(c"", c"ours-text\n", c"theirs-text\n", 0, 0)
	assert_equal(1, r.conflicts)
	assert1(wvct_contains(r.text, c"<<<<<<< ours\nours-text\n=======\ntheirs-text\n>>>>>>> theirs\n"))
	free(r.text)
	free(r)


void test_ours_deletes_everything_theirs_unchanged():
	assert_merge_text(c"", 0, c"a\nb\nc\n", c"", c"a\nb\nc\n")


void test_theirs_deletes_everything_ours_unchanged():
	assert_merge_text(c"", 0, c"a\nb\nc\n", c"a\nb\nc\n", c"")


void test_all_three_empty():
	assert_merge_text(c"", 0, c"", c"", c"")


void test_all_three_identical_nonempty():
	char* text = c"unchanged\neverywhere\n"
	assert_merge_text(text, 0, text, text, text)


# --- trailing-newline edge case (merge3.w's own header-comment example) ----


void test_only_ours_drops_trailing_newline():
	# ours removes the trailing newline from the last line, theirs is
	# byte-identical to base (including the trailing newline) -- this is
	# a real, non-conflicting "only ours changed" edit that a pure
	# line-content compare (ignoring no_newline) would have missed.
	merge3_text_result* r = merge3_merge_text(c"a\nb\n", c"a\nb", c"a\nb\n", 0, 0)
	assert_strings_equal(c"a\nb", r.text)
	assert_equal(0, r.conflicts)
	free(r.text)
	free(r)


void test_both_sides_drop_trailing_newline_identically_coalesces():
	assert_merge_text(c"a\nb", 0, c"a\nb\n", c"a\nb", c"a\nb")
