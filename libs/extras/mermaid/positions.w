# Portable graphical positions are ordinary Mermaid comments in the selected
# diagram. Coordinates are layout coordinates (before the title's 40px gutter).
import libs.extras.mermaid.scene

const int MM_POSITION_LIMIT = 100000

int mm_position_title_offset(mm_document* d):
	if (d.title[0] != 0): return 40
	return 0

# Families whose source grammar the graphical editor splices. Every one shares
# the mm_node/mm_edge graph model and the generic graph layout and renderer.
int mm_graph_edit_family(int kind):
	return kind == MM_FLOW || kind == MM_ER || kind == MM_CLASS || kind == MM_STATE

int mm_position_supported(mm_document* d, int index):
	if (d.error != 0 || mm_graph_edit_family(d.kind) == 0): return 0
	if (index < 0 || index >= d.nodes.length): return 0
	mm_node* n = d.nodes[index]
	if (n.group || n.parent >= 0): return 0
	# Quoted identifiers have no embedded quote/newline in the parser grammar.
	if (n.id[0] == 0): return 0
	for i in range(strlen(n.id)):
		if (n.id[i] == '"' || n.id[i] == 10 || n.id[i] == 13): return 0
	return 1

int mm_position_space(int c):
	return c == 32 || c == 9 || c == 13

# Only ranges actually consumed by mm_separators are comments. In particular,
# accDescr blocks may contain metadata-looking lines that must stay plain text.
int mm_position_comment(mm_document* d, int start, int end):
	if (d.comment_ranges == 0): return 0
	int low = 0
	int high = d.comment_ranges.length / 2
	while (low < high):
		int mid = low + (high - low) / 2
		int offset = d.comment_ranges[mid * 2]
		if (offset < start): low = mid + 1
		else: high = mid
	if (low * 2 >= d.comment_ranges.length): return 0
	return d.comment_ranges[low * 2] == start && d.comment_ranges[low * 2 + 1] == end

# A malformed comment remains ordinary text; it must never move a node or
# overflow an integer. Return the matched node index only for complete records.
int mm_position_record(mm_document* d, int start, int end, int* x, int* y):
	int at = start
	while (at < end && mm_position_space(d.source[at])): at = at + 1
	char* prefix = c"%% @w-position "
	int length = strlen(prefix)
	if (end - at < length): return -1
	for i in range(length):
		if (d.source[at + i] != prefix[i]): return -1
	if (mm_position_comment(d, at, end) == 0): return -1
	at = at + length
	while (at < end && mm_position_space(d.source[at])): at = at + 1
	int quoted = at < end && d.source[at] == '"'
	if (quoted): at = at + 1
	int id_start = at
	while (at < end):
		if (quoted && d.source[at] == '"'): break
		if (quoted == 0 && mm_position_space(d.source[at])): break
		at = at + 1
	if (at == id_start || at == end): return -1
	char* id = str_copy_range(d.source, id_start, at)
	int index = mm_find_node(d, id)
	free(id)
	if (mm_position_supported(d, index) == 0): return -1
	if (quoted): at = at + 1
	for axis in range(2):
		if (at == end || mm_position_space(d.source[at]) == 0): return -1
		while (at < end && mm_position_space(d.source[at])): at = at + 1
		int digit_start = at
		int value = 0
		while (at < end && d.source[at] >= '0' && d.source[at] <= '9'):
			int digit = d.source[at] - '0'
			if (value > (MM_POSITION_LIMIT - digit) / 10): return -1
			value = value * 10 + digit
			at = at + 1
		if (at == digit_start): return -1
		if (axis == 0): *x = value
		else: *y = value
	while (at < end && mm_position_space(d.source[at])): at = at + 1
	if (at != end): return -1
	return index

int mm_position_line_end(mm_document* d, int start):
	int end = start
	while (end < d.source_end && d.source[end] != 10): end = end + 1
	return end

void mm_positions_apply(mm_document* d, mm_scene* s):
	if (mm_graph_edit_family(d.kind) == 0): return
	int at = d.source_start
	while (at < d.source_end):
		int end = mm_position_line_end(d, at)
		int x = 0
		int y = 0
		int index = mm_position_record(d, at, end, &x, &y)
		if (index >= 0 && index < s.nodes.length):
			s.nodes[index].x = x
			s.nodes[index].y = y
		at = end + 1

# Replace only valid metadata for this node. Keep all other source bytes,
# including malformed comments and other Markdown fences. Last record wins on
# read; writing coalesces duplicate records into one bounded comment.
char* mm_position_source(mm_document* d, int index, int x, int y):
	if (mm_position_supported(d, index) == 0): return 0
	if (x < 0 || y < 0 || x > MM_POSITION_LIMIT || y > MM_POSITION_LIMIT): return 0
	string_builder* out = string_new()
	string_append_bytes(out, d.source, d.source_start)
	int at = d.source_start
	int crlf = 0
	while (at < d.source_end):
		int end = mm_position_line_end(d, at)
		if (end > at && d.source[end - 1] == 13): crlf = 1
		int line_end = end
		if (line_end < d.source_end): line_end = line_end + 1
		int old_x = 0
		int old_y = 0
		if (mm_position_record(d, at, end, &old_x, &old_y) != index): string_append_bytes(out, d.source + at, line_end - at)
		at = line_end
	if (out.length > 0 && out.data[out.length - 1] != 10):
		if (crlf): string_append_char(out, 13)
		string_append_char(out, 10)
	string_append(out, c"%% @w-position \"")
	string_append(out, d.nodes[index].id)
	string_append(out, c"\" ")
	string_append_int(out, x)
	string_append_char(out, 32)
	string_append_int(out, y)
	if (crlf): string_append_char(out, 13)
	string_append_char(out, 10)
	string_append_bytes(out, d.source + d.source_end, d.length - d.source_end)
	char* result = out.data
	free(out)
	return result
