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
