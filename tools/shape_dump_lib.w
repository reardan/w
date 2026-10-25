# The text form of portable shaper output shared by tools/shape_dump.w
# and tests/ttf_shape_test.w: "dir=<ltr|rtl>" then, per glyph in visual
# order, " gid@cluster+x_advance(x_offset,y_offset)" in font units,
# matching tools/shape_compare_hb.py's HarfBuzz rendering. Direction
# follows the first strong character, else the script.
import lib.lib
import lib.utf8
import lib.ttf
import lib.ttf_layout
import lib.ttf_shape
import lib.unicode_text
import structures.string

void shape_format(ttf_font* font, char* text, int length, string_builder* out):
	int32* cps = cast(int32*, malloc(length * 4 + 4))
	int32* clusters = cast(int32*, malloc(length * 4 + 4))
	int count = 0
	int at = 0
	int strong = 0
	while (at < length):
		int cp = 0
		int size = utf8_scan(text + at, length - at, &cp)
		if (size == 0):
			cp = 65533
			size = 1
		clusters[count] = at
		cps[count] = cp
		count = count + 1
		at = at + size
		if (strong == 0):
			int cls = ut_bidi_class(cp)
			if (cls == ut_bidi_l): strong = 1
			if ((cls == ut_bidi_r) || (cls == ut_bidi_al)): strong = 2
	int rtl = strong == 2
	if (strong == 0): rtl = ttf_script_is_rtl(ttf_guess_script(cps, count))
	otl_buffer* b = ttf_shape(font, cps, clusters, count, rtl, -1, 0, 0)
	if (rtl): string_append(out, c"dir=rtl")
	else: string_append(out, c"dir=ltr")
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		string_append_char(out, ' ')
		string_append_int(out, g.gid)
		string_append_char(out, '@')
		string_append_int(out, g.cluster)
		string_append_char(out, '+')
		string_append_int(out, g.x_advance)
		string_append_char(out, '(')
		string_append_int(out, g.x_offset)
		string_append_char(out, ',')
		string_append_int(out, g.y_offset)
		string_append_char(out, ')')
	otl_buffer_free(b)
	free(cps)
	free(clusters)

# Load a font spec: a path, optionally followed by "!-TAG" suffixes that
# hide those tables so a test can reach the no-GSUB / no-GPOS fallbacks.
# The tag's last letter is decremented, which keeps the table directory
# sorted (tools/shape_compare_hb.py reads the same syntax). Returns ttf_load's result; f owns the bytes.
int shape_load_spec(ttf_font* f, char* spec):
	int length = strlen(spec)
	int cut = length
	for i in range(length - 1):
		if ((cut == length) && (spec[i] == '!') && (spec[i + 1] == '-')): cut = i
	char* path = cast(char*, malloc(cut + 1))
	mem_copy(path, spec, cut)
	path[cut] = 0
	int size = 0
	char* data = ttf_read_file(path, &size)
	free(path)
	if (data == 0): return 0
	int at = cut
	while ((at + 6 <= length) && (spec[at] == '!') && (spec[at + 1] == '-')):
		int tables = ((data[4] & 255) << 8) | (data[5] & 255)
		for t in range(tables):
			char* rec = data + 12 + t * 16
			if ((rec[0] == spec[at + 2]) && (rec[1] == spec[at + 3]) && (rec[2] == spec[at + 4]) && (rec[3] == spec[at + 5])): rec[3] = rec[3] - 1
		at = at + 6
	if (!ttf_load_bytes(f, data, size)):
		free(data)
		f.data = 0
		return 0
	return 1
