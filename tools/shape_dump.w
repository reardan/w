# Print the portable shaper's output (lib.ttf_shape) for each line of a
# UTF-8 text file, for comparison with another shaping engine:
#   bin/shape_dump font.ttf lines.txt
# One output line per input line: "dir=<ltr|rtl>" then, per glyph in
# visual order, "gid@cluster+x_advance(x_offset,y_offset)" in font units.
# Direction follows the first strong character, else the script.
# tools/shape_compare_hb.py runs this against HarfBuzz.
import lib.lib
import lib.stream
import lib.ttf
import lib.ttf_layout
import lib.ttf_shape
import lib.unicode_text
import structures.string

void shape_dump_line(ttf_font* font, char* text, int length):
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
	if (rtl): print(c"dir=rtl")
	else: print(c"dir=ltr")
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		print(f" {g.gid}@{g.cluster}+{g.x_advance}({g.x_offset},{g.y_offset})")
	print(c"\n")
	otl_buffer_free(b)
	free(cps)
	free(clusters)

int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc < 3):
		println2(c"usage: shape_dump font.ttf lines.txt")
		return 2
	ttf_font font
	if (!ttf_load(&font, args[1])): return 2
	wstream* src = stream_open_read(args[2])
	if (src == 0):
		println2(c"shape_dump: cannot read the text file")
		return 2
	string_builder* line = string_new()
	while (stream_read_line(src, line)): shape_dump_line(&font, line.data, line.length)
	stream_close(src)
	return 0
