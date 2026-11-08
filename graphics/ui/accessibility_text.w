/*
graphics.ui.accessibility_text: the text queries every platform bridge
answers from a semantic snapshot's text node (#863): where characters
are (glyph geometry for magnifiers, braille panning and caret
tracking), which character is at a point, and which attributes (font,
size, weight, colours) cover a character. The boxes, attributes and
selections themselves are stored by graphics.ui.accessibility
(ui_access_set_char_boxes, ui_access_default_attrs,
ui_access_add_attr_run, ui_access_add_selection).

Offsets count characters (code points) of the node's value, as every
bridge does. A node without boxes has no glyph geometry: the queries
return 0 and the bridges fall back to the node's bounds.
*/
import graphics.ui.accessibility


int ui_access_text_count(ui_access_node* n):
	return ui_access_char_count(n.value.data, n.value.length)


int ui_access_has_glyphs(ui_access_node* n):
	return (n != 0) && (n.char_boxes != 0) && (n.char_box_count == ui_access_text_count(n))


# The box of character k into out; k == the character count is the
# caret position after the last character (a zero-width box at its
# right edge). 0 without glyph geometry or for an offset out of range.
int ui_access_char_box(ui_access_node* n, int k, ui_rect* out):
	if (!ui_access_has_glyphs(n) || (k < 0) || (k > n.char_box_count) || (n.char_box_count == 0)): return 0
	if (k < n.char_box_count):
		out[0] = n.char_boxes[k]
		return 1
	ui_rect last = n.char_boxes[k - 1]
	out[0] = ui_rect_new(last.x + last.w, last.y, 0.0, last.h)
	return 1


ui_rect ui_access_rect_union(ui_rect a, ui_rect b):
	float32 x0 = a.x
	float32 y0 = a.y
	float32 x1 = a.x + a.w
	float32 y1 = a.y + a.h
	if (b.x < x0): x0 = b.x
	if (b.y < y0): y0 = b.y
	if (b.x + b.w > x1): x1 = b.x + b.w
	if (b.y + b.h > y1): y1 = b.y + b.h
	return ui_rect_new(x0, y0, x1 - x0, y1 - y0)


# The smallest box around characters [start, end) (an empty range: the
# caret box at start). 0 without glyph geometry or for a bad range.
int ui_access_range_box(ui_access_node* n, int start, int end, ui_rect* out):
	if (!ui_access_has_glyphs(n)): return 0
	int count = n.char_box_count
	if (start < 0): start = 0
	if (end > count): end = count
	if (start > end): return 0
	if (start == end): return ui_access_char_box(n, start, out)
	ui_rect box = n.char_boxes[start]
	for k in range(start + 1, end): box = ui_access_rect_union(box, n.char_boxes[k])
	out[0] = box
	return 1


# One box per line of characters [start, end): consecutive characters
# whose boxes share a top and height belong to one line. Writes up to
# cap boxes to out and returns how many lines there are (0 without
# glyph geometry or for an empty range).
int ui_access_range_lines(ui_access_node* n, int start, int end, ui_rect* out, int cap):
	if (!ui_access_has_glyphs(n)): return 0
	if (start < 0): start = 0
	if (end > n.char_box_count): end = n.char_box_count
	int lines = 0
	ui_rect current
	for k in range(start, end):
		ui_rect b = n.char_boxes[k]
		if ((lines > 0) && (b.y == current.y) && (b.h == current.h)):
			current = ui_access_rect_union(current, b)
		else:
			if ((lines > 0) && (lines <= cap)): out[lines - 1] = current
			current = b
			lines = lines + 1
	if ((lines > 0) && (lines <= cap)): out[lines - 1] = current
	return lines


# The character whose box contains (x, y), or -1.
int ui_access_offset_at_point(ui_access_node* n, float32 x, float32 y):
	if (!ui_access_has_glyphs(n)): return 0 - 1
	for k in range(n.char_box_count):
		if (ui_rect_contains(n.char_boxes[k], x, y)): return k
	return 0 - 1


# The nearest caret position (0..count) to (x, y): on the line closest
# to y, before the first character whose middle lies right of x. -1
# without glyph geometry.
int ui_access_caret_at_point(ui_access_node* n, float32 x, float32 y):
	if (!ui_access_has_glyphs(n)): return 0 - 1
	int count = n.char_box_count
	if (count == 0): return 0
	# The line: the boxes whose vertical extent is nearest y.
	float32 best = 0.0
	float32 line_y = 0.0
	int found = 0
	for k in range(count):
		ui_rect b = n.char_boxes[k]
		float32 d = 0.0
		if (y < b.y): d = b.y - y
		else if (y >= b.y + b.h): d = y - (b.y + b.h) + 1.0
		if (!found || (d < best)):
			best = d
			line_y = b.y
			found = 1
	int last = 0 - 1
	for k in range(count):
		ui_rect b = n.char_boxes[k]
		if (b.y == line_y):
			if (x < b.x + b.w * 0.5): return k
			last = k
	# Past the line's end: after its last character, unless that is the
	# newline ending the line (the caret goes before it).
	if ((last >= 0) && (last < n.value.length)):
		int at = ui_access_char_byte(n.value.data, n.value.length, last)
		if (n.value.data[at] == 10): return last
	return last + 1


# The attributes covering character k: its run's, else the node's
# defaults (0 when the node has none). *start and *end receive the run
# the attributes hold over: a run, or the stretch between runs.
ui_access_text_attrs* ui_access_attrs_at(ui_access_node* n, int k, int* start, int* end):
	int count = ui_access_text_count(n)
	int from = 0
	int to = count
	for i in range(n.run_count):
		ui_access_text_run* run = &n.runs[i]
		if ((k >= run.start) && (k < run.end)):
			start[0] = run.start
			end[0] = run.end
			return &run.attrs
		if (run.end <= k): from = run.end
		if ((run.start > k) && (run.start < to)): to = run.start
	if (k >= count):
		# The end of the text belongs to the last run when it reaches it.
		if ((n.run_count > 0) && (n.runs[n.run_count - 1].end == count) && (count > 0)):
			ui_access_text_run* tail = &n.runs[n.run_count - 1]
			start[0] = tail.start
			end[0] = tail.end
			return &tail.attrs
	start[0] = from
	end[0] = to
	return n.attrs


# 1 when every character of [start, end) has the same attributes.
int ui_access_attrs_uniform(ui_access_node* n, int start, int end):
	int a = 0
	int b = 0
	ui_access_text_attrs* first = ui_access_attrs_at(n, start, &a, &b)
	while (b < end):
		ui_access_text_attrs* next = ui_access_attrs_at(n, b, &a, &b)
		if ((first == 0) != (next == 0)): return 0
		if ((first != 0) && !ui_access_attrs_same(first, next)): return 0
		if (b <= a): return 1
	return 1


# 0xRRGGBB from a theme colour's 0..1 channels.
int ui_access_rgb(float32 r, float32 g, float32 b):
	int ri = cast(int, r * 255.0 + 0.5)
	int gi = cast(int, g * 255.0 + 0.5)
	int bi = cast(int, b * 255.0 + 0.5)
	if (ri < 0): ri = 0
	if (gi < 0): gi = 0
	if (bi < 0): bi = 0
	if (ri > 255): ri = 255
	if (gi > 255): gi = 255
	if (bi > 255): bi = 255
	return (ri << 16) | (gi << 8) | bi


# The caret: n's caret offset, 0 when it shows none.
int ui_access_caret_or_zero(ui_access_node* n):
	if (n.caret < 0): return 0
	return n.caret


# The UI_ACCESS_SET_SELECTIONS payload that replaces selection k of n
# (ui_access_selection_range order) with [start, end): k equal to the
# current count adds one, start < 0 removes selection k. The first pair
# keeps the primary selection's anchor and caret (or is the bare caret
# when the primary is empty or removed). Stores a fresh payload in *out
# and returns its length; 0 for an out-of-range request.
int ui_access_selections_edit(ui_access_node* n, int k, int start, int end, char** out):
	out[0] = 0
	int count = ui_access_text_count(n)
	int total = ui_access_selection_total(n)
	if ((k < 0) || (k > total) || (start > count) || (end > count) || ((start >= 0) && (end < start))): return 0
	if ((start < 0) && (k == total)): return 0
	int* pairs = cast(int*, malloc((total + 2) * 2 * __word_size__))
	int caret = ui_access_caret_or_zero(n)
	int first = 0
	pairs[0] = caret
	pairs[1] = caret
	int used = 1
	if (ui_access_has_selection(n)):
		first = 1
		if (k != 0):
			int anchor = n.selection_start
			if (caret == n.selection_start): anchor = n.selection_end
			pairs[0] = anchor
			pairs[1] = caret
		else if (start >= 0):
			pairs[0] = start
			pairs[1] = end
	for i in range(first, total):
		int s = 0
		int e = 0
		ui_access_selection_range(n, i, &s, &e)
		if (i == k):
			s = start
			e = end
		if (s >= 0):
			pairs[used * 2] = s
			pairs[used * 2 + 1] = e
			used = used + 1
	if ((k == total) && (start >= 0)):
		pairs[used * 2] = start
		pairs[used * 2 + 1] = end
		used = used + 1
	char* payload = cast(char*, malloc(used * 24 + 1))
	int length = ui_access_selections_format(payload, pairs, used)
	free(cast(char*, pairs))
	out[0] = payload
	return length


/* Relations (#911). */

# Reverse relation kinds, as ui_access_related answers them: the nodes
# whose relation of the negated kind names this one.
const int UI_ACCESS_REL_LABEL_FOR = 0 - 1
const int UI_ACCESS_REL_DESCRIPTION_FOR = 0 - 2
const int UI_ACCESS_REL_CONTROLLED_BY = 0 - 3


# The nodes related to n by kind: a UI_ACCESS_REL_* (n's own relations
# whose targets exist) or a reverse kind (the nodes relating to n).
# Returns how many there are, storing the index-th (0 when out of
# range) in *out.
int ui_access_related(ui_access_tree* tree, ui_access_node* n, int kind, int index, ui_access_node** out):
	out[0] = 0
	if ((tree == 0) || (n == 0) || (kind == 0)): return 0
	int count = 0
	if (kind > 0):
		for i in range(n.relation_count):
			if (n.relations[i * 2] == kind):
				ui_access_node* t = ui_access_find(tree, n.relations[i * 2 + 1])
				if (t != 0):
					if (count == index): out[0] = t
					count = count + 1
		return count
	if (kind == 0 - UI_ACCESS_REL_MEMBER_OF): return 0
	for int id in tree.nodes:
		ui_access_node* c = tree.nodes[id]
		for i in range(c.relation_count):
			if ((c.relations[i * 2] == 0 - kind) && (c.relations[i * 2 + 1] == n.id)):
				if (count == index): out[0] = c
				count = count + 1
	return count


# The relation kinds n has at least one target for, forward kinds then
# reverse ones, in a fixed order: how many, the index-th in *kind.
int ui_access_relation_kinds(ui_access_tree* tree, ui_access_node* n, int index, int* kind):
	kind[0] = 0
	int count = 0
	ui_access_node* t = 0
	for k in range(1, UI_ACCESS_REL_LAST + 1):
		for sign in range(2):
			int candidate = k
			if (sign == 1): candidate = 0 - k
			if (ui_access_related(tree, n, candidate, 0, &t) > 0):
				if (count == index): kind[0] = candidate
				count = count + 1
	return count


/* IME composition (#912). */

# Insert an IME composition into text node id's value as the screen
# shows it: text[0..length) (UTF-8) at character at, with boxes[k] the
# box of its k-th character (0: none; the node then loses its glyph
# geometry unless it had none). The caret moves to at + caret (caret
# counts characters of the composition), the selection collapses onto
# it, later selections and attribute runs shift, and the composition and
# its conversion target [target, target + target_length) (inside the
# composition, 0 length for none) are recorded. 0 on bad input.
int ui_access_insert_composition(ui_access_tree* tree, int id, int at, char* text, int length, ui_rect* boxes, int caret, int target, int target_length):
	ui_access_node* n = ui_access_find(tree, id)
	if ((n == 0) || (length <= 0) || (at < 0)): return 0
	if (!utf8_validate_bytes(text, length)): return 0
	int count = ui_access_char_count(text, length)
	int total = ui_access_text_count(n)
	if ((at > total) || (caret < 0) || (caret > count) || (target < 0) || (target_length < 0) || (target + target_length > count)): return 0
	int glyphs = ui_access_has_glyphs(n)
	int byte = ui_access_char_byte(n.value.data, n.value.length, at)
	int size = n.value.length + length
	char* joined = cast(char*, malloc(size + 1))
	for i in range(byte): joined[i] = n.value.data[i]
	for i in range(length): joined[byte + i] = text[i]
	for i in range(byte, n.value.length): joined[length + i] = n.value.data[i]
	ui_rect* old_boxes = n.char_boxes
	int old_count = n.char_box_count
	n.char_boxes = 0
	n.char_box_count = 0
	int ok = ui_access_set_text(tree, id, UI_ACCESS_VALUE, joined, size)
	free(joined)
	if (!ok):
		n.char_boxes = old_boxes
		n.char_box_count = old_count
		return 0
	if (glyphs && (boxes != 0)):
		ui_rect* grown = cast(ui_rect*, malloc((old_count + count + 1) * sizeof(ui_rect)))
		for i in range(at): grown[i] = old_boxes[i]
		for i in range(count): grown[at + i] = boxes[i]
		for i in range(at, old_count): grown[count + i] = old_boxes[i]
		ui_access_set_char_boxes(tree, id, grown, old_count + count)
		free(cast(char*, grown))
	free(cast(char*, old_boxes))
	for i in range(n.selection_count * 2):
		if (n.selections[i] >= at): n.selections[i] = n.selections[i] + count
	for i in range(n.run_count):
		ui_access_text_run* run = &n.runs[i]
		if (run.start >= at): run.start = run.start + count
		if (run.end >= at): run.end = run.end + count
	n.caret = at + caret
	n.selection_start = n.caret
	n.selection_end = n.caret
	return ui_access_set_composition(tree, id, at, count, at + target, target_length)


/* Visible text (#912). */

# 1 when character k's box overlaps clip (a zero-width box counts when
# its edge lies inside it).
int ui_access_char_in(ui_access_node* n, int k, ui_rect clip):
	ui_rect b = n.char_boxes[k]
	if ((b.y + b.h <= clip.y) || (b.y >= clip.y + clip.h)): return 0
	if (b.w <= 0.0): return (b.x >= clip.x) && (b.x <= clip.x + clip.w)
	return (b.x + b.w > clip.x) && (b.x < clip.x + clip.w)


# The stretches of n's characters whose boxes overlap clip, as [start,
# end) pairs in order: how many, with up to cap of them in out (two
# ints each). Without glyph geometry the whole text is one stretch.
int ui_access_visible_ranges(ui_access_node* n, ui_rect clip, int* out, int cap):
	int count = ui_access_text_count(n)
	if (!ui_access_has_glyphs(n)):
		if (cap > 0):
			out[0] = 0
			out[1] = count
		return 1
	int ranges = 0
	int start = 0 - 1
	for k in range(count + 1):
		int inside = (k < count) && ui_access_char_in(n, k, clip)
		if (inside && (start < 0)): start = k
		if (!inside && (start >= 0)):
			if (ranges < cap):
				out[ranges * 2] = start
				out[ranges * 2 + 1] = k
			ranges = ranges + 1
			start = 0 - 1
	return ranges


# The rectangle n's text shows through: its bounds.
ui_rect ui_access_text_clip(ui_access_node* n):
	return n.bounds
