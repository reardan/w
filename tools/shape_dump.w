# Print the portable shaper's output (lib.ttf_shape) for each line of a
# UTF-8 text file, for comparison with another shaping engine:
#   bin/shape_dump font.ttf lines.txt
# One output line per input line: "dir=<ltr|rtl>" then, per glyph in
# visual order, "gid@cluster+x_advance(x_offset,y_offset)" in font units.
# Direction follows the first strong character, else the script.
# tools/shape_compare_hb.py runs this against HarfBuzz.
import lib.lib
import lib.stream
import tools.shape_dump_lib

int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc < 3):
		println2(c"usage: shape_dump font.ttf lines.txt")
		return 2
	ttf_font font
	if (!shape_load_spec(&font, args[1])): return 2
	wstream* src = stream_open_read(args[2])
	if (src == 0):
		println2(c"shape_dump: cannot read the text file")
		return 2
	string_builder* line = string_new()
	string_builder* out = string_new()
	while (stream_read_line(src, line)):
		string_clear(out)
		shape_format(&font, line.data, line.length, out)
		string_append_char(out, 10)
		print_n(out.data, out.length)
	stream_close(src)
	return 0
