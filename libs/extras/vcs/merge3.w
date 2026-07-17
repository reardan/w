/*
Three-way line merge with git-compatible conflict markers (VCS wave 4,
issue #252; design: docs/projects/version_control.md, "Wave 4 -- merge
and sync"). Built directly on libs/extras/vcs/diff.w's Myers line diff:
merge3 does not run its own comparison algorithm, it reuses diff.w's
diff_myers_ops twice (base->ours, base->theirs) and reconciles the two
edit scripts. Line input/output conventions mirror diff.w exactly: a
"line" is diff.w's split-on-'\n' string, `no_newline` flags whether the
structurally last line of a file lacks a trailing newline, and the core
entry point (merge3_merge) takes pre-split diff_input-shaped arguments
the same way diff_lines does, with merge3_merge_text as the diff_text-
shaped convenience wrapper.

Algorithm: base-anchored sync regions (bzrlib's Merge3 / Mercurial's
simplemerge.py -- both descend from the same classic three-way merge
construction; this is not git's xdiff internals, but produces the same
observable git diff3 semantics for line-based, non-overlapping-vs-
overlapping conflict detection, which is what the wave asked for).

  1. Compute matching blocks (maximal runs of identical lines) for
     base<->ours and base<->theirs independently, from diff_myers_ops'
     DIFF_EQUAL runs (merge3_matching_blocks).
  2. Intersect the two block lists in BASE coordinates: a "sync region"
     is a base line range present unchanged in BOTH ours and theirs
     (merge3_find_sync_regions). Because a matching block already
     guarantees byte-for-byte equality (diff_myers_ops' equality
     predicate already accounts for the trailing-newline edge case), any
     sub-range of an intersection is trivially still an exact match, so
     the sync region's ours/theirs sub-ranges are positioned by simple
     offset arithmetic -- no further comparison needed.
  3. Walk the gaps BETWEEN consecutive sync regions (merge3_emit_gap):
     each gap is, by construction, a maximal base range where at least
     one side differs from base. Classify by comparing content (not
     just block presence, to stay correct even if Myers' particular
     shortest-edit-script choice did not surface a matching block for a
     coincidentally-equal sub-range):
       - neither side's gap content differs from base: copy base (rare;
         a Myers-alignment artifact, not a "real" change -- handled as a
         safe no-op).
       - only one side differs from base: take that side's content
         wholesale (git's "non-overlapping changes apply cleanly").
       - both differ, and their gap content is identical to each other:
         coalesce -- emit once (git's "identical changes coalesce").
       - both differ and disagree: conflict. Emit git's standard
         7-character markers ("<<<<<<<", "=======", ">>>>>>>", each
         exactly 7 characters -- git's own convention) around ours' and
         theirs' gap content, and increment the conflict counter once
         per conflicting gap (a "conflict" here is a region, not a
         line -- the same granularity `git merge` reports as one hunk).
  4. Between gaps, the sync region itself is copied verbatim from base
     (ours and theirs are byte-identical to it there by construction, so
     the choice of source is arbitrary).

Ownership: base_lines/ours_lines/theirs_lines are borrowed from the
caller for the duration of the call (diff.w's own convention -- see
diff_line's header comment); merge3_result's line list is a MIX of
borrowed pointers (unchanged/one-side/coalesced content, straight from
the caller's line arrays) and a small number of owned strings synthesized
for conflict marker text, so each merge3_line node carries its own
`owned` flag and merge3_result_free frees exactly the owned ones.

Deliberately out of scope this wave (see docs/projects/version_control.md
and the header comment on tools/wvc.w's merge subcommand for how the
porcelain layer uses this module): rename detection, and recursive/
virtual-base merge-base synthesis for criss-cross histories (git's
merge-recursive/merge-ort) -- this module only ever merges exactly one
base against ours/theirs; picking WHICH base to hand it when a commit
DAG has more than one best common ancestor is tools/wvc.w's job, using
dag.w's dag_merge_base (deterministic "first by insertion order" choice,
documented there). No histogram/patience diff variant either: diff.w's
plain Myers algorithm is what backs both sides' comparisons.

Nothing here enters the seed import graph (docs/projects/version_control.md).
*/
import lib.lib
import lib.container
import structures.string
import libs.extras.vcs.diff


/* Matching blocks: maximal identical runs between base and one side */


struct merge3_block:
	int base_start
	int side_start
	int len


# Maximal runs of DIFF_EQUAL ops between base_lines and side_lines (each
# run's base/side start positions and length), terminated by a
# zero-length sentinel block at (base_lines.length, side_lines.length) --
# the same trick bzrlib's Merge3.find_sync_regions uses so the gap AFTER
# the last real match is processed by the exact same loop as every other
# gap, with no special-casing at end-of-file.
list[merge3_block*] merge3_matching_blocks(list[char*] base_lines, int base_no_nl, list[char*] side_lines, int side_no_nl):
	list[diff_op*] ops = diff_myers_ops(base_lines, base_no_nl, side_lines, side_no_nl)
	list[merge3_block*] blocks = new list[merge3_block*]
	int i = 0
	while (i < ops.length):
		if (ops[i].kind == DIFF_EQUAL()):
			int base_start = ops[i].old_index
			int side_start = ops[i].new_index
			int len = 0
			while ((i < ops.length) && (ops[i].kind == DIFF_EQUAL())):
				len = len + 1
				i = i + 1
			merge3_block* b = new merge3_block()
			b.base_start = base_start
			b.side_start = side_start
			b.len = len
			blocks.push(b)
		else:
			i = i + 1
	merge3_block* sentinel = new merge3_block()
	sentinel.base_start = base_lines.length
	sentinel.side_start = side_lines.length
	sentinel.len = 0
	blocks.push(sentinel)
	for diff_op* op in ops:
		free(op)
	list_free[diff_op*](ops)
	return blocks


int merge3_min(int a, int b):
	if (a < b):
		return a
	return b


int merge3_max(int a, int b):
	if (a > b):
		return a
	return b


/* Sync regions: base ranges unchanged on BOTH sides */


struct merge3_sync:
	int base_start
	int base_end
	int a_start
	int a_end
	int b_start
	int b_end


# The base-coordinate ranges where both a_blocks (base<->ours) and
# b_blocks (base<->theirs) have a matching block -- positions neither
# side touched. Two-pointer walk over both base-sorted block lists,
# intersecting one pair of ranges at a time and always advancing
# whichever block ends first in base coordinates (bzrlib's
# find_sync_regions, transcribed directly: a well-tested construction,
# not reinvented here). An explicit trailing sentinel region
# (base_len, base_len, a_len, a_len, b_len, b_len) is appended
# unconditionally after the walk -- the two block lists' own sentinels
# are zero-length and never intersect, so without this the final gap
# (from the last real match to end-of-file) would never be visited by
# merge3_merge's gap-processing loop.
list[merge3_sync*] merge3_find_sync_regions(list[merge3_block*] a_blocks, list[merge3_block*] b_blocks, int base_len, int a_len, int b_len):
	list[merge3_sync*] result = new list[merge3_sync*]
	int ia = 0
	int ib = 0
	while ((ia < a_blocks.length) && (ib < b_blocks.length)):
		merge3_block* ab = a_blocks[ia]
		merge3_block* bb = b_blocks[ib]
		int a_lo = ab.base_start
		int a_hi = ab.base_start + ab.len
		int b_lo = bb.base_start
		int b_hi = bb.base_start + bb.len
		int lo = merge3_max(a_lo, b_lo)
		int hi = merge3_min(a_hi, b_hi)
		if (lo < hi):
			int int_len = hi - lo
			merge3_sync* s = new merge3_sync()
			s.base_start = lo
			s.base_end = hi
			s.a_start = ab.side_start + (lo - ab.base_start)
			s.a_end = s.a_start + int_len
			s.b_start = bb.side_start + (lo - bb.base_start)
			s.b_end = s.b_start + int_len
			result.push(s)
		if (a_hi < b_hi):
			ia = ia + 1
		else:
			ib = ib + 1
	merge3_sync* tail = new merge3_sync()
	tail.base_start = base_len
	tail.base_end = base_len
	tail.a_start = a_len
	tail.a_end = a_len
	tail.b_start = b_len
	tail.b_end = b_len
	result.push(tail)
	return result


/* Content comparison over a line range */


# `end <= start` (an empty range) reports "no missing newline": there is
# no last line to have one.
int merge3_range_no_newline(list[char*] lines, int no_nl, int start, int end):
	if (end <= start):
		return 0
	return diff_missing_at(lines, no_nl, end - 1)


# Byte-for-byte content equality of two line ranges, including whether
# each range's structurally-last line (if it is also the FILE's last
# line) lacks a trailing newline -- so a pure "trailing newline added/
# removed" edit is correctly seen as a change even when every line's
# text is otherwise identical.
int merge3_ranges_equal(list[char*] a_lines, int a_no_nl, int a_start, int a_end, list[char*] b_lines, int b_no_nl, int b_start, int b_end):
	int a_len = a_end - a_start
	int b_len = b_end - b_start
	if (a_len != b_len):
		return 0
	int i = 0
	while (i < a_len):
		if (strcmp(a_lines[a_start + i], b_lines[b_start + i]) != 0):
			return 0
		i = i + 1
	if (merge3_range_no_newline(a_lines, a_no_nl, a_start, a_end) != merge3_range_no_newline(b_lines, b_no_nl, b_start, b_end)):
		return 0
	return 1


/* Output: a mix of borrowed (unchanged/one-side/coalesced) and owned
   (synthesized marker) lines */


struct merge3_line:
	char* text
	int owned         # 1 when `text` was malloc'd here and must be freed
	int no_newline


struct merge3_result:
	list[merge3_line*] lines
	int no_newline    # whether the merged file's structural last line lacks a trailing newline
	int conflicts     # number of conflicting GAPS (regions), not lines


void merge3_result_free(merge3_result* r):
	for merge3_line* l in r.lines:
		if (l.owned):
			free(l.text)
		free(l)
	r.lines.clear()
	list_free[merge3_line*](r.lines)
	free(r)


# Appends one line, updating out.no_newline the same way diff_apply does
# (diff.w): every append simply overwrites the flag, so whatever was
# emitted most recently determines the merged file's own trailing-
# newline state.
void merge3_emit_line(merge3_result* out, char* text, int no_newline, int owned):
	merge3_line* l = new merge3_line()
	l.text = text
	l.owned = owned
	l.no_newline = no_newline
	out.lines.push(l)
	out.no_newline = no_newline


void merge3_emit_range(merge3_result* out, list[char*] lines, int no_nl, int start, int end):
	int i = start
	while (i < end):
		merge3_emit_line(out, lines[i], diff_missing_at(lines, no_nl, i), 0)
		i = i + 1


char* MERGE3_MARKER_OURS_PREFIX():
	return c"<<<<<<<"


char* MERGE3_MARKER_SEP():
	return c"======="


char* MERGE3_MARKER_THEIRS_PREFIX():
	return c">>>>>>>"


char* MERGE3_DEFAULT_OURS_LABEL():
	return c"ours"


char* MERGE3_DEFAULT_THEIRS_LABEL():
	return c"theirs"


# Emits one marker line: `prefix` alone when `label` is empty/0 (used for
# the bare "=======" separator, always a static literal so owned=0), or
# "<prefix> <label>" freshly built (owned=1) otherwise -- e.g.
# "<<<<<<< ours". Marker lines always carry a trailing newline (0): a
# conflict can only be followed by more content or, at worst, by the
# file's true end, in which case this module chooses to still terminate
# the synthesized marker line with '\n' rather than track whichever
# side's own original no-newline-at-eof status would otherwise have
# applied to that position -- a deliberate simplification, documented
# here rather than silently dropped.
void merge3_emit_marker(merge3_result* out, char* prefix, char* label):
	if ((label == 0) || (strlen(label) == 0)):
		merge3_emit_line(out, prefix, 0, 0)
		return
	string_builder* s = string_new()
	string_append(s, prefix)
	string_append_char(s, ' ')
	string_append(s, label)
	char* text = s.data
	free(s)
	merge3_emit_line(out, text, 0, 1)


/* Classifying and emitting one gap between two consecutive sync regions */


void merge3_emit_gap(merge3_result* out, list[char*] base_lines, int base_no_nl, int base_start, int base_end, list[char*] ours_lines, int ours_no_nl, int a_start, int a_end, list[char*] theirs_lines, int theirs_no_nl, int b_start, int b_end, char* ours_label, char* theirs_label):
	int a_changed = merge3_ranges_equal(base_lines, base_no_nl, base_start, base_end, ours_lines, ours_no_nl, a_start, a_end) == 0
	int b_changed = merge3_ranges_equal(base_lines, base_no_nl, base_start, base_end, theirs_lines, theirs_no_nl, b_start, b_end) == 0

	if ((a_changed == 0) && (b_changed == 0)):
		# Neither side's gap content actually differs from base -- a
		# Myers-alignment artifact (see the header comment), not a real
		# change. Safe no-op: copy base.
		merge3_emit_range(out, base_lines, base_no_nl, base_start, base_end)
		return
	if (a_changed == 0):
		# Only theirs changed: apply cleanly.
		merge3_emit_range(out, theirs_lines, theirs_no_nl, b_start, b_end)
		return
	if (b_changed == 0):
		# Only ours changed: apply cleanly.
		merge3_emit_range(out, ours_lines, ours_no_nl, a_start, a_end)
		return
	if (merge3_ranges_equal(ours_lines, ours_no_nl, a_start, a_end, theirs_lines, theirs_no_nl, b_start, b_end)):
		# Both changed, identically: coalesce into a single copy.
		merge3_emit_range(out, ours_lines, ours_no_nl, a_start, a_end)
		return

	# Both changed, differently: conflict.
	out.conflicts = out.conflicts + 1
	merge3_emit_marker(out, MERGE3_MARKER_OURS_PREFIX(), ours_label)
	merge3_emit_range(out, ours_lines, ours_no_nl, a_start, a_end)
	merge3_emit_marker(out, MERGE3_MARKER_SEP(), 0)
	merge3_emit_range(out, theirs_lines, theirs_no_nl, b_start, b_end)
	merge3_emit_marker(out, MERGE3_MARKER_THEIRS_PREFIX(), theirs_label)


/* Core entry point (diff_lines-shaped: pre-split lines + no_newline flags) */


merge3_result* merge3_merge(list[char*] base_lines, int base_no_nl, list[char*] ours_lines, int ours_no_nl, list[char*] theirs_lines, int theirs_no_nl, char* ours_label, char* theirs_label):
	list[merge3_block*] a_blocks = merge3_matching_blocks(base_lines, base_no_nl, ours_lines, ours_no_nl)
	list[merge3_block*] b_blocks = merge3_matching_blocks(base_lines, base_no_nl, theirs_lines, theirs_no_nl)
	list[merge3_sync*] syncs = merge3_find_sync_regions(a_blocks, b_blocks, base_lines.length, ours_lines.length, theirs_lines.length)

	merge3_result* out = new merge3_result()
	out.lines = new list[merge3_line*]
	out.no_newline = 0
	out.conflicts = 0

	int prev_base_end = 0
	int prev_a_end = 0
	int prev_b_end = 0
	for merge3_sync* s in syncs:
		merge3_emit_gap(out, base_lines, base_no_nl, prev_base_end, s.base_start, ours_lines, ours_no_nl, prev_a_end, s.a_start, theirs_lines, theirs_no_nl, prev_b_end, s.b_start, ours_label, theirs_label)
		merge3_emit_range(out, base_lines, base_no_nl, s.base_start, s.base_end)
		prev_base_end = s.base_end
		prev_a_end = s.a_end
		prev_b_end = s.b_end

	for merge3_block* b in a_blocks:
		free(b)
	list_free[merge3_block*](a_blocks)
	for merge3_block* b in b_blocks:
		free(b)
	list_free[merge3_block*](b_blocks)
	for merge3_sync* s in syncs:
		free(s)
	list_free[merge3_sync*](syncs)

	return out


# merge3_merge with default "ours"/"theirs" marker labels.
merge3_result* merge3_merge_default(list[char*] base_lines, int base_no_nl, list[char*] ours_lines, int ours_no_nl, list[char*] theirs_lines, int theirs_no_nl):
	return merge3_merge(base_lines, base_no_nl, ours_lines, ours_no_nl, theirs_lines, theirs_no_nl, MERGE3_DEFAULT_OURS_LABEL(), MERGE3_DEFAULT_THEIRS_LABEL())


# Rejoins a merge3_result's lines into raw text, the merge3_line analogue
# of diff.w's diff_join_lines: every line but (optionally) the last is
# followed by '\n'.
char* merge3_join_lines(list[merge3_line*] lines, int no_newline):
	string_builder* s = string_new()
	int i = 0
	while (i < lines.length):
		string_append(s, lines[i].text)
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


/* Convenience entry point (diff_text-shaped: whole-buffer text in/out) */


struct merge3_text_result:
	char* text        # owned, malloc'd
	int conflicts


# Splits all three texts (diff.w's diff_read_text), merges them, and
# joins the result back into one owned string. `ours_label`/
# `theirs_label` may be 0 to fall back to "ours"/"theirs"
# (MERGE3_DEFAULT_OURS_LABEL/MERGE3_DEFAULT_THEIRS_LABEL).
merge3_text_result* merge3_merge_text(char* base_text, char* ours_text, char* theirs_text, char* ours_label, char* theirs_label):
	char* a_label = ours_label
	if (a_label == 0):
		a_label = MERGE3_DEFAULT_OURS_LABEL()
	char* b_label = theirs_label
	if (b_label == 0):
		b_label = MERGE3_DEFAULT_THEIRS_LABEL()

	diff_input* base_input = diff_read_text(base_text)
	diff_input* ours_input = diff_read_text(ours_text)
	diff_input* theirs_input = diff_read_text(theirs_text)
	merge3_result* r = merge3_merge(base_input.lines, base_input.no_newline, ours_input.lines, ours_input.no_newline, theirs_input.lines, theirs_input.no_newline, a_label, b_label)

	merge3_text_result* out = new merge3_text_result()
	out.text = merge3_join_lines(r.lines, r.no_newline)
	out.conflicts = r.conflicts
	merge3_result_free(r)
	return out
