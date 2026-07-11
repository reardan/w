/*
Myers line diff + unified-format ("diff -u" style) renderer.

Algorithm: the classic Myers (1986) greedy shortest-edit-script search
(see also James Coglan's "The Myers diff algorithm" write-up). Time is
O(ND) where N = old_lines.length + new_lines.length and D is the edit
distance between the two inputs. Backtracking uses a full saved trace
of the V arrays, one snapshot per explored "d" -- O(D*N) auxiliary
space -- rather than the linear-space (Hirschberg-style) divide-and-
conquer refinement. That refinement matters at the scale of whole
source trees; it is not needed here, and this is the variant most
"Myers diff" reference implementations ship.

Comparison is line-based and byte-exact: no encoding is interpreted, a
"line" is whatever bytes fall between '\n' bytes (or between a '\n'
and the start/end of the buffer). A file's last line is compared
including whether it is followed by a trailing newline, so "foo\n" and
"foo" (no trailing newline) are NOT equal lines even though the split
text matches -- this mirrors real diff/patch behavior and is what lets
the unified renderer emit the standard
"\ No newline at end of file" marker.

Grouping non-equal lines into hunks with surrounding context (and
merging hunks whose contexts would overlap) ports the well-tested
algorithm behind Python's difflib.SequenceMatcher.get_grouped_opcodes.

Dual-use note: this module does not depend on cas.w or dag.w and adds
nothing to the seed's import graph (see docs/projects/version_control.md).
*/
import lib.lib
import lib.math
import lib.stream
import structures.string


int DIFF_EQUAL():
	return 0


int DIFF_DELETE():
	return 1


int DIFF_INSERT():
	return 2


int diff_default_context():
	return 3


# One rendered line of a hunk: EQUAL (context, present in both files),
# DELETE (old only) or INSERT (new only). 'text' borrows the pointer
# from the caller's line array -- callers must keep old_lines/new_lines
# alive for as long as any diff_result built from them is in use.
struct diff_line:
	int kind
	char* text
	int no_newline


struct diff_hunk:
	int old_start
	int old_len
	int new_start
	int new_len
	list[diff_line*] lines


struct diff_result:
	list[diff_hunk*] hunks


int diff_is_identical(diff_result* result):
	return result.hunks.length == 0


# --- splitting input text into lines --------------------------------------

# True when 'text' is non-empty and its last byte is not '\n': the
# file's last line has no trailing newline.
int diff_missing_newline(char* text):
	int n = strlen(text)
	if (n == 0):
		return 0
	if (text[n - 1] == 10):
		return 0
	return 1


# Splits 'text' into lines with the trailing '\n' of each stripped. An
# empty string yields zero lines; a string ending in '\n' does not
# yield a trailing empty line (matching how files are normally read).
list[char*] diff_split_lines(char* text):
	list[char*] lines = new list[char*]
	int n = strlen(text)
	string_builder* line = string_new()
	int i = 0
	while (i < n):
		char c = text[i]
		if (c == 10):
			lines.push(strclone(line.data))
			string_clear(line)
		else:
			string_append_char(line, c)
		i = i + 1
	if (line.length > 0):
		lines.push(strclone(line.data))
	string_free(line)
	return lines


struct diff_input:
	list[char*] lines
	int no_newline


diff_input* diff_read_text(char* text):
	diff_input* input = new diff_input()
	input.lines = diff_split_lines(text)
	input.no_newline = diff_missing_newline(text)
	return input


# --- Myers edit script -----------------------------------------------------

struct diff_op:
	int kind
	int old_index
	int new_index


# True when old_lines[i] and new_lines[j] are byte-identical *lines of
# the file*, which means accounting for a missing trailing newline at
# end of file: a final line without '\n' is a different byte sequence
# than the same text followed by '\n', even though the split text is
# equal.
int diff_lines_equal(list[char*] old_lines, int old_no_nl, list[char*] new_lines, int new_no_nl, int i, int j):
	if (strcmp(old_lines[i], new_lines[j]) != 0):
		return 0
	int old_last = i == (old_lines.length - 1)
	int new_last = j == (new_lines.length - 1)
	if (old_last && new_last):
		if (old_no_nl == new_no_nl):
			return 1
		return 0
	if (old_last):
		if (old_no_nl == 0):
			return 1
		return 0
	if (new_last):
		if (new_no_nl == 0):
			return 1
		return 0
	return 1


# Returns the flat list of per-line ops (DIFF_EQUAL/DIFF_DELETE/
# DIFF_INSERT) that transforms old_lines into new_lines, in order.
list[diff_op*] diff_myers_ops(list[char*] old_lines, int old_no_nl, list[char*] new_lines, int new_no_nl):
	list[diff_op*] ops = new list[diff_op*]
	int n = old_lines.length
	int m = new_lines.length
	if ((n == 0) && (m == 0)):
		return ops

	int max_d = n + m
	int offset = max_d
	int width = 2 * max_d + 1

	list[int] v = new list[int]
	for int i in range(width):
		v.push(0)
	v[offset + 1] = 0

	list[list[int]] trace = new list[list[int]]
	int found_d = -1

	for int d in range(max_d + 1):
		list[int] snapshot = new list[int]
		for int i in range(width):
			snapshot.push(v[i])
		trace.push(snapshot)

		int k = 0 - d
		while (k <= d):
			int x = 0
			int go_down = 0
			if (k == (0 - d)):
				go_down = 1
			else if (k == d):
				go_down = 0
			else if (v[offset + k - 1] < v[offset + k + 1]):
				go_down = 1
			if (go_down):
				x = v[offset + k + 1]
			else:
				x = v[offset + k - 1] + 1
			int y = x - k
			while ((x < n) && (y < m) && diff_lines_equal(old_lines, old_no_nl, new_lines, new_no_nl, x, y)):
				x = x + 1
				y = y + 1
			v[offset + k] = x
			if ((x >= n) && (y >= m)):
				found_d = d
			k = k + 2

		if (found_d >= 0):
			break

	# Backtrack from (n, m) to (0, 0) through the saved trace, collecting
	# ops in reverse order, then reverse them back into forward order.
	list[diff_op*] rev = new list[diff_op*]
	int x = n
	int y = m
	int d = found_d
	while (d >= 0):
		list[int] tv = trace[d]
		int k = x - y
		int prev_k = 0
		int go_down = 0
		if (k == (0 - d)):
			go_down = 1
		else if (k == d):
			go_down = 0
		else if (tv[offset + k - 1] < tv[offset + k + 1]):
			go_down = 1
		if (go_down):
			prev_k = k + 1
		else:
			prev_k = k - 1
		int prev_x = tv[offset + prev_k]
		int prev_y = prev_x - prev_k

		while ((x > prev_x) && (y > prev_y)):
			diff_op* eq = new diff_op()
			eq.kind = DIFF_EQUAL()
			eq.old_index = x - 1
			eq.new_index = y - 1
			rev.push(eq)
			x = x - 1
			y = y - 1

		if (d > 0):
			diff_op* step = new diff_op()
			if (x == prev_x):
				step.kind = DIFF_INSERT()
				step.old_index = -1
				step.new_index = prev_y
			else:
				step.kind = DIFF_DELETE()
				step.old_index = prev_x
				step.new_index = -1
			rev.push(step)

		x = prev_x
		y = prev_y
		d = d - 1

	int idx = rev.length - 1
	while (idx >= 0):
		ops.push(rev[idx])
		idx = idx - 1
	return ops


# --- grouping into hunks with context --------------------------------------

# A coalesced run of same-kind ops: old range [old_start,old_end) maps
# to new range [new_start,new_end). For DIFF_DELETE, new_start==new_end
# (the position between the surrounding new-file lines); symmetrically
# for DIFF_INSERT.
struct diff_range_op:
	int kind
	int old_start
	int old_end
	int new_start
	int new_end


list[diff_range_op*] diff_coalesce_ops(list[diff_op*] ops):
	list[diff_range_op*] result = new list[diff_range_op*]
	int old_pos = 0
	int new_pos = 0
	int i = 0
	while (i < ops.length):
		int kind = ops[i].kind
		int old_start = old_pos
		int new_start = new_pos
		int j = i
		while ((j < ops.length) && (ops[j].kind == kind)):
			if (kind == DIFF_EQUAL()):
				old_pos = old_pos + 1
				new_pos = new_pos + 1
			else if (kind == DIFF_DELETE()):
				old_pos = old_pos + 1
			else:
				new_pos = new_pos + 1
			j = j + 1
		diff_range_op* r = new diff_range_op()
		r.kind = kind
		r.old_start = old_start
		r.old_end = old_pos
		r.new_start = new_start
		r.new_end = new_pos
		result.push(r)
		i = j
	return result


# 1 when 'index' is the last line of the file that 'lines'/'no_nl'
# describe, and that file has no trailing newline.
int diff_missing_at(list[char*] lines, int no_nl, int index):
	if (no_nl == 0):
		return 0
	if (index != (lines.length - 1)):
		return 0
	return 1


diff_hunk* diff_group_to_hunk(list[diff_range_op*] group, list[char*] old_lines, int old_no_nl, list[char*] new_lines, int new_no_nl):
	diff_hunk* hunk = new diff_hunk()
	hunk.lines = new list[diff_line*]
	diff_range_op* first = group[0]
	diff_range_op* last = group[group.length - 1]
	hunk.old_start = first.old_start
	hunk.new_start = first.new_start
	hunk.old_len = last.old_end - first.old_start
	hunk.new_len = last.new_end - first.new_start

	for diff_range_op* code in group:
		if (code.kind == DIFF_EQUAL()):
			int i = code.old_start
			while (i < code.old_end):
				diff_line* dl = new diff_line()
				dl.kind = DIFF_EQUAL()
				dl.text = old_lines[i]
				dl.no_newline = diff_missing_at(old_lines, old_no_nl, i)
				hunk.lines.push(dl)
				i = i + 1
		else if (code.kind == DIFF_DELETE()):
			int i = code.old_start
			while (i < code.old_end):
				diff_line* dl = new diff_line()
				dl.kind = DIFF_DELETE()
				dl.text = old_lines[i]
				dl.no_newline = diff_missing_at(old_lines, old_no_nl, i)
				hunk.lines.push(dl)
				i = i + 1
		else:
			int j = code.new_start
			while (j < code.new_end):
				diff_line* dl = new diff_line()
				dl.kind = DIFF_INSERT()
				dl.text = new_lines[j]
				dl.no_newline = diff_missing_at(new_lines, new_no_nl, j)
				hunk.lines.push(dl)
				j = j + 1
	return hunk


# Builds the full diff between two already-split inputs: the Myers edit
# script, coalesced into equal/delete/insert ranges, trimmed to
# 'context' lines of surrounding equal text and merged into hunks
# (adjacent changes within 2*context lines of each other share a hunk)
# -- ports Python difflib.SequenceMatcher.get_grouped_opcodes.
diff_result* diff_lines(list[char*] old_lines, int old_no_nl, list[char*] new_lines, int new_no_nl, int context):
	diff_result* result = new diff_result()
	result.hunks = new list[diff_hunk*]

	list[diff_op*] ops = diff_myers_ops(old_lines, old_no_nl, new_lines, new_no_nl)
	list[diff_range_op*] codes = diff_coalesce_ops(ops)
	if (codes.length == 0):
		return result

	if (codes[0].kind == DIFF_EQUAL()):
		diff_range_op* first = codes[0]
		first.old_start = max(first.old_start, first.old_end - context)
		first.new_start = max(first.new_start, first.new_end - context)
	int last_i = codes.length - 1
	if (codes[last_i].kind == DIFF_EQUAL()):
		diff_range_op* last = codes[last_i]
		last.old_end = min(last.old_end, last.old_start + context)
		last.new_end = min(last.new_end, last.new_start + context)

	int nn = context + context
	list[diff_range_op*] group = new list[diff_range_op*]
	for diff_range_op* code in codes:
		int is_wide_equal = 0
		if ((code.kind == DIFF_EQUAL()) && ((code.old_end - code.old_start) > nn)):
			is_wide_equal = 1
		if (is_wide_equal):
			diff_range_op* head = new diff_range_op()
			head.kind = DIFF_EQUAL()
			head.old_start = code.old_start
			head.old_end = min(code.old_end, code.old_start + context)
			head.new_start = code.new_start
			head.new_end = min(code.new_end, code.new_start + context)
			group.push(head)
			result.hunks.push(diff_group_to_hunk(group, old_lines, old_no_nl, new_lines, new_no_nl))
			group = new list[diff_range_op*]

			diff_range_op* tail = new diff_range_op()
			tail.kind = DIFF_EQUAL()
			tail.old_start = max(code.old_start, code.old_end - context)
			tail.old_end = code.old_end
			tail.new_start = max(code.new_start, code.new_end - context)
			tail.new_end = code.new_end
			group.push(tail)
		else:
			group.push(code)

	int emit_last = 1
	if (group.length == 0):
		emit_last = 0
	else if ((group.length == 1) && (group[0].kind == DIFF_EQUAL())):
		emit_last = 0
	if (emit_last):
		result.hunks.push(diff_group_to_hunk(group, old_lines, old_no_nl, new_lines, new_no_nl))

	return result


# Convenience entry point: splits both texts and diffs them.
diff_result* diff_text(char* old_text, char* new_text, int context):
	diff_input* old_input = diff_read_text(old_text)
	diff_input* new_input = diff_read_text(new_text)
	return diff_lines(old_input.lines, old_input.no_newline, new_input.lines, new_input.no_newline, context)


# --- applying hunks (reconstruction) ---------------------------------------

# Result of replaying a diff_result over the old lines it was computed
# from: exactly the new file's lines. This is the property merge3.w
# will build three-way merges on top of, so it is a first-class library
# function rather than a test-only helper.
struct diff_apply_result:
	list[char*] lines
	int no_newline


diff_apply_result* diff_apply(list[char*] old_lines, int old_no_nl, diff_result* result):
	diff_apply_result* out = new diff_apply_result()
	out.lines = new list[char*]
	out.no_newline = old_no_nl

	int old_pos = 0
	for diff_hunk* hunk in result.hunks:
		while (old_pos < hunk.old_start):
			out.lines.push(old_lines[old_pos])
			out.no_newline = diff_missing_at(old_lines, old_no_nl, old_pos)
			old_pos = old_pos + 1
		for diff_line* dl in hunk.lines:
			if (dl.kind == DIFF_DELETE()):
				old_pos = old_pos + 1
			else:
				out.lines.push(dl.text)
				out.no_newline = dl.no_newline
				if (dl.kind == DIFF_EQUAL()):
					old_pos = old_pos + 1

	while (old_pos < old_lines.length):
		out.lines.push(old_lines[old_pos])
		out.no_newline = diff_missing_at(old_lines, old_no_nl, old_pos)
		old_pos = old_pos + 1

	return out


# Rejoins a line list into raw text, the inverse of diff_split_lines:
# every line but (optionally) the last is followed by '\n'.
char* diff_join_lines(list[char*] lines, int no_newline):
	string_builder* s = string_new()
	int i = 0
	while (i < lines.length):
		string_append(s, lines[i])
		int is_last = i == (lines.length - 1)
		int suppress_newline = 0
		if (is_last && (no_newline != 0)):
			suppress_newline = 1
		if (suppress_newline == 0):
			string_append_char(s, 10)
		i = i + 1
	char* text = s.data
	free(s)
	return text


# --- unified-format rendering -----------------------------------------------

# Formats one hunk-header range: 1-based start (or the 0-based position
# before the gap when len == 0), and the length suffix is omitted when
# len == 1 -- exactly GNU diff's convention.
char* diff_format_range(int start0, int len):
	string_builder* s = string_new()
	int shown_start = start0
	if (len > 0):
		shown_start = start0 + 1
	string_append_int(s, shown_start)
	if (len != 1):
		string_append(s, c",")
		string_append_int(s, len)
	char* text = s.data
	free(s)
	return text


# Renders 'result' as unified-diff text (empty string when identical):
#   --- old_label
#   +++ new_label
#   @@ -old_start,old_len +new_start,new_len @@
#    context line
#   -deleted line
#   +inserted line
#   \ No newline at end of file
char* diff_render_unified_text(char* old_label, char* new_label, diff_result* result):
	string_builder* s = string_new()
	if (result.hunks.length > 0):
		string_append(s, c"--- ")
		string_append(s, old_label)
		string_append_char(s, 10)
		string_append(s, c"+++ ")
		string_append(s, new_label)
		string_append_char(s, 10)

		for diff_hunk* hunk in result.hunks:
			string_append(s, c"@@ -")
			char* old_range = diff_format_range(hunk.old_start, hunk.old_len)
			string_append(s, old_range)
			free(old_range)
			string_append(s, c" +")
			char* new_range = diff_format_range(hunk.new_start, hunk.new_len)
			string_append(s, new_range)
			free(new_range)
			string_append(s, c" @@")
			string_append_char(s, 10)

			for diff_line* dl in hunk.lines:
				if (dl.kind == DIFF_EQUAL()):
					string_append_char(s, ' ')
				else if (dl.kind == DIFF_DELETE()):
					string_append_char(s, '-')
				else:
					string_append_char(s, '+')
				string_append(s, dl.text)
				string_append_char(s, 10)
				if (dl.no_newline != 0):
					string_append(s, c"\\ No newline at end of file")
					string_append_char(s, 10)

	char* text = s.data
	free(s)
	return text


void diff_render_unified(wstream* out, char* old_label, char* new_label, diff_result* result):
	char* text = diff_render_unified_text(old_label, new_label, result)
	stream_write_cstr(out, text)
	free(text)
