/*
graphics.ui.widgets.buffer: a growable multi-line text buffer with a
line index (docs/projects/ui_widgets.md §4). What ui_textbox_state's
fixed char[128] becomes when the text is a document rather than a
field.

Pure: no graphics.gl / graphics.window import, so it runs on wasm and
the 32-bit target alongside the rest of the pure UI core, and an
editor can hold one without a display.

Storage is a NUL-terminated char array grown by doubling. line_starts
holds the offset of each line's first byte — line_starts[0] is always
0, and a buffer always has at least one line, so an empty buffer is one
empty line rather than zero lines. The index is rebuilt on every edit,
O(n); an incremental rebuild (shift the suffix, splice the edited
line's entries) is the editor's follow-up, and the API here does not
change when it lands.

Offsets are byte indices, not character counts: the widget layer
measures with the same byte-per-glyph font the rest of graphics.ui
uses. UTF-8 clusters are the flagged follow-up (docs/todo.txt).

Index arithmetic goes through &line_starts[n], never line_starts + n —
T* + int is an unscaled byte offset for every pointee width.
*/
import lib.lib


int ui_text_buffer_min_capacity():
	return 64


struct ui_text_buffer:
	char* data
	int32 length
	int32 capacity
	int32* line_starts
	int32 line_count
	int32 line_capacity


void ui_text_buffer_init(ui_text_buffer* b):
	b.capacity = ui_text_buffer_min_capacity()
	b.data = malloc(b.capacity)
	b.data[0] = 0
	b.length = 0
	b.line_capacity = ui_text_buffer_min_capacity()
	b.line_starts = cast(int32*, malloc(b.line_capacity * 4))
	b.line_starts[0] = 0
	b.line_count = 1


# Free the storage and leave a zeroed struct — safe to init again, and
# safe to free twice.
void ui_text_buffer_free(ui_text_buffer* b):
	if (b.data != 0):
		free(b.data)
	if (b.line_starts != 0):
		free(cast(char*, b.line_starts))
	b.data = 0
	b.length = 0
	b.capacity = 0
	b.line_starts = 0
	b.line_count = 0
	b.line_capacity = 0


# Grow the text storage to hold at least `needed` bytes plus the NUL.
void ui_text_buffer_reserve(ui_text_buffer* b, int needed):
	if (needed + 1 <= b.capacity):
		return
	int next = b.capacity
	while (next < needed + 1):
		next = next * 2
	char* moved = realloc(b.data, b.capacity, next)
	if (moved == 0):
		return
	b.data = moved
	b.capacity = next


void ui_text_buffer_reserve_lines(ui_text_buffer* b, int needed):
	if (needed <= b.line_capacity):
		return
	int next = b.line_capacity
	while (next < needed):
		next = next * 2
	int32* moved = cast(int32*, realloc(cast(char*, b.line_starts), b.line_capacity * 4, next * 4))
	if (moved == 0):
		return
	b.line_starts = moved
	b.line_capacity = next


# Rebuild the line index from the text. O(n) on every edit; the
# incremental version is the editor's follow-up.
void ui_text_buffer_reindex(ui_text_buffer* b):
	b.line_starts[0] = 0
	b.line_count = 1
	int i = 0
	while (i < b.length):
		if (b.data[i] == '\n'):
			# The line after a newline starts at the next byte — which
			# may be b.length, giving a final empty line, exactly as a
			# text editor shows a trailing newline.
			ui_text_buffer_reserve_lines(b, b.line_count + 1)
			if (b.line_count < b.line_capacity):
				b.line_starts[b.line_count] = i + 1
				b.line_count = b.line_count + 1
		i = i + 1


void ui_text_buffer_set(ui_text_buffer* b, char* s):
	int len = strlen(s)
	ui_text_buffer_reserve(b, len)
	if (len + 1 > b.capacity):
		len = b.capacity - 1
	int i = 0
	while (i < len):
		b.data[i] = s[i]
		i = i + 1
	b.data[len] = 0
	b.length = len
	ui_text_buffer_reindex(b)


# Insert one byte at a byte offset. An out-of-range offset clamps to
# the buffer's ends rather than corrupting it.
void ui_text_buffer_insert(ui_text_buffer* b, int offset, int ch):
	if (offset < 0):
		offset = 0
	if (offset > b.length):
		offset = b.length
	ui_text_buffer_reserve(b, b.length + 1)
	if (b.length + 1 >= b.capacity):
		return
	int i = b.length
	while (i > offset):
		b.data[i] = b.data[i - 1]
		i = i - 1
	b.data[offset] = ch
	b.length = b.length + 1
	b.data[b.length] = 0
	ui_text_buffer_reindex(b)


void ui_text_buffer_insert_text(ui_text_buffer* b, int offset, char* s):
	if (offset < 0):
		offset = 0
	if (offset > b.length):
		offset = b.length
	int len = strlen(s)
	if (len == 0):
		return
	ui_text_buffer_reserve(b, b.length + len)
	if (b.length + len + 1 > b.capacity):
		len = b.capacity - 1 - b.length
	if (len <= 0):
		return
	# Shift the tail right, from the end, so the copy never overwrites
	# a byte it has yet to move.
	int i = b.length
	while (i > offset):
		b.data[i - 1 + len] = b.data[i - 1]
		i = i - 1
	i = 0
	while (i < len):
		b.data[offset + i] = s[i]
		i = i + 1
	b.length = b.length + len
	b.data[b.length] = 0
	ui_text_buffer_reindex(b)


# Delete count bytes at offset; a range past the end deletes what
# exists and stops.
void ui_text_buffer_delete(ui_text_buffer* b, int offset, int count):
	if (count <= 0):
		return
	if (offset < 0):
		offset = 0
	if (offset >= b.length):
		return
	if (offset + count > b.length):
		count = b.length - offset
	int i = offset
	while (i + count < b.length):
		b.data[i] = b.data[i + count]
		i = i + 1
	b.length = b.length - count
	b.data[b.length] = 0
	ui_text_buffer_reindex(b)


# Byte offset of a line's first byte; out-of-range lines clamp, so a
# caller walking a stale line number cannot read past the buffer.
int ui_text_buffer_line_start(ui_text_buffer* b, int line):
	if (line <= 0):
		return 0
	if (line >= b.line_count):
		return b.length
	return b.line_starts[line]


# Bytes on a line, excluding its newline.
int ui_text_buffer_line_length(ui_text_buffer* b, int line):
	if ((line < 0) || (line >= b.line_count)):
		return 0
	int start = b.line_starts[line]
	int end = b.length
	if (line + 1 < b.line_count):
		# The next line starts after the newline, which is not part of
		# this line's text.
		end = b.line_starts[line + 1] - 1
	if (end < start):
		return 0
	return end - start


int ui_text_buffer_offset_to_line(ui_text_buffer* b, int offset):
	if (offset <= 0):
		return 0
	int line = 0
	while (line + 1 < b.line_count):
		if (b.line_starts[line + 1] > offset):
			return line
		line = line + 1
	return line


# Byte offset of a line/column pair, with the column clamped to the
# line's length — the caret cannot sit past the end of a short line.
int ui_text_buffer_line_col_to_offset(ui_text_buffer* b, int line, int col):
	if (line < 0):
		line = 0
	if (line >= b.line_count):
		line = b.line_count - 1
	int len = ui_text_buffer_line_length(b, line)
	if (col < 0):
		col = 0
	if (col > len):
		col = len
	return b.line_starts[line] + col
