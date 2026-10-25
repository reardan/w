# wbuild: target=linebreak_data tag=generated dep=wv2 input=tools/unicode/ input=tools/generate_linebreak_data.w output=lib/linebreak_data.w
# wbuild: step="bin/wv2 tools/generate_linebreak_data.w -o bin/generate_linebreak_data"
# wbuild: step="bin/generate_linebreak_data"
# Emits lib/linebreak_data.w, the Line_Break table behind lib/linebreak.w
# (UAX #14, issue #826), from the committed Unicode 15.0.0 Character
# Database files under tools/unicode/:
#   LineBreak.txt        Line_Break, with the defaults its header lists for
#                        unassigned code points (ID in the CJK and Plane
#                        1-3 ranges, PR in Currency Symbols, XX elsewhere)
#   EastAsianWidth.txt   East_Asian_Width, for the [OP-\p{ea=F|W|H}] of
#                        rule LB30
#   emoji-data.txt       Extended_Pictographic, for the
#                        [\p{Extended_Pictographic}&\p{Cn}] of rule LB30b
#   UnicodeData.txt      General_Category: SA marks (Mn, Mc) resolve to
#                        CM here (rule LB1), and Cn for LB30b
# The files are unmodified copies of the Unicode 15.0.0 data
# (Public/15.0.0/ucd/, emoji-data.txt from ucd/emoji/).
#
# The table is a byte-string literal of 4-byte entries (24-bit big-endian
# start, value byte): an entry's value covers every codepoint up to the
# next entry's start. The value's low six bits are the class (the
# lb_class_* numbering of lib/linebreak.w, in gen_class_names order); bit
# 6 marks an OP or CP whose East_Asian_Width is F, W or H, bit 7 an unassigned
# Extended_Pictographic code point.
#
# Run from the repo root: ./wbuild linebreak_data
import lib.lib
import lib.stream
import structures.string


const int gen_max_cp = 1114111
const int gen_wide_flag = 64
const int gen_pictographic_flag = 128


void gen_fail(char* message, char* detail):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"generate_linebreak_data: ")
	stream_write_cstr(err, message)
	if (detail != 0):
		stream_write_cstr(err, c": ")
		stream_write_cstr(err, detail)
	stream_write_line(err, c"")
	stream_flush(err)
	exit(1)


# Line_Break short names in lb_class_* order (lib/linebreak.w).
char* gen_class_names():
	return c"XX BK CR LF CM NL SG WJ ZW GL SP ZWJ B2 BA BB HY CB CL CP EX IN NS OP QU IS NU PO PR SY AI AK AL AP AS CJ EB EM H2 H3 HL ID JL JV JT RI SA VF VI"


# Index of word in a space-separated name list, or -1.
int gen_name_index(char* names, char* word):
	int index = 0
	int i = 0
	while (names[i] != 0):
		int j = 0
		while ((word[j] != 0) && (names[i + j] == word[j])): j = j + 1
		if ((word[j] == 0) && ((names[i + j] == ' ') || (names[i + j] == 0))): return index
		while ((names[i] != ' ') && (names[i] != 0)): i = i + 1
		if (names[i] == ' '): i = i + 1
		index = index + 1
	return -1


int gen_hex_digit(int c):
	if ((c >= '0') && (c <= '9')): return c - '0'
	if ((c >= 'a') && (c <= 'f')): return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')): return c - 'A' + 10
	return -1


int gen_is_space(int c):
	return (c == ' ') || (c == 9)


int gen_parse_hex(char* text):
	int i = 0
	while (gen_is_space(text[i])): i = i + 1
	int value = 0
	while (gen_hex_digit(text[i]) >= 0):
		value = value * 16 + gen_hex_digit(text[i])
		i = i + 1
	return value


# "XXXX" or "XXXX..YYYY": the range's first and last codepoint.
void gen_parse_range(char* text, int* first, int* last):
	first[0] = gen_parse_hex(text)
	last[0] = first[0]
	int i = 0
	while ((text[i] != 0) && (text[i] != '.')): i = i + 1
	if ((text[i] == '.') && (text[i + 1] == '.')): last[0] = gen_parse_hex(&text[i + 2])


# Cuts line at '#', splits the rest at ';' in place and trims each field.
# Pointers land in fields (cleared first); they borrow line's buffer.
void gen_split(char* line, list[char*] fields):
	fields.clear()
	int i = 0
	while ((line[i] != 0) && (line[i] != '#')): i = i + 1
	line[i] = 0
	i = 0
	int start = 0
	while (1):
		int c = line[i]
		if ((c == ';') || (c == 0)):
			line[i] = 0
			int s = start
			while (gen_is_space(line[s])): s = s + 1
			int e = i
			while ((e > s) && gen_is_space(line[e - 1])): e = e - 1
			line[e] = 0
			fields.push(&line[s])
			if (c == 0): return
			start = i + 1
		i = i + 1


wstream* gen_open(char* path):
	wstream* stream = stream_open_read(path)
	if (stream == 0): gen_fail(c"cannot open (run from the repo root)", path)
	return stream


void gen_fill(char* table, int first, int last, int value):
	if ((first < 0) || (last > gen_max_cp) || (first > last)): gen_fail(c"bad codepoint range", 0)
	for cp in range(first, last + 1): table[cp] = value


char* gen_table(int value):
	char* table = cast(char*, malloc(gen_max_cp + 1))
	for cp in range(gen_max_cp + 1): table[cp] = value
	return table


# General_Category of every code point as its two letters packed into a
# 16-bit value ('C' << 8 | 'n' for unassigned), from UnicodeData.txt.
int16* gen_load_categories():
	int16* table = cast(int16*, malloc((gen_max_cp + 1) * 2))
	int cn = ('C' << 8) | 'n'
	for cp in range(gen_max_cp + 1): table[cp] = cn
	wstream* src = gen_open(c"tools/unicode/UnicodeData.txt")
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	int pending = -1
	while (stream_read_line(src, line)):
		if (line.length == 0): continue
		gen_split(line.data, f)
		if (f.length < 3): gen_fail(c"short UnicodeData.txt line", f[0])
		int cp = gen_parse_hex(f[0])
		if (ends_with(f[1], c", First>")):
			pending = cp
			continue
		int first = cp
		if (ends_with(f[1], c", Last>")): first = pending
		int value = ((f[2][0] & 255) << 8) | (f[2][1] & 255)
		for c in range(first, cp + 1): table[c] = value
	stream_close(src)
	return table


# Fills table with the class values of a "range;Value" property file.
# Returns the number of data lines.
int gen_load_property(char* path, char* table, char* names):
	wstream* src = gen_open(path)
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	int first = 0
	int last = 0
	int lines = 0
	while (stream_read_line(src, line)):
		gen_split(line.data, f)
		if ((f.length < 2) || (f[0][0] == 0)): continue
		int value = gen_name_index(names, f[1])
		if (value < 0): gen_fail(c"unknown property value", f[1])
		gen_parse_range(f[0], &first, &last)
		gen_fill(table, first, last, value)
		lines = lines + 1
	stream_close(src)
	return lines


# Line_Break, with the header's documented defaults for unlisted code
# points, SA marks resolved to CM and the two LB30/LB30b flags.
char* gen_load_classes():
	char* table = gen_table(0)
	int id = gen_name_index(gen_class_names(), c"ID")
	gen_fill(table, 0x3400, 0x4dbf, id)
	gen_fill(table, 0x4e00, 0x9fff, id)
	gen_fill(table, 0xf900, 0xfaff, id)
	gen_fill(table, 0x20000, 0x2fffd, id)
	gen_fill(table, 0x30000, 0x3fffd, id)
	gen_fill(table, 0x1f000, 0x1faff, id)
	gen_fill(table, 0x1fc00, 0x1fffd, id)
	gen_fill(table, 0x20a0, 0x20cf, gen_name_index(gen_class_names(), c"PR"))
	if (gen_load_property(c"tools/unicode/LineBreak.txt", table, gen_class_names()) < 1000): gen_fail(c"LineBreak.txt is too short", 0)
	int16* categories = gen_load_categories()
	char* widths = gen_table(0)
	gen_load_property(c"tools/unicode/EastAsianWidth.txt", widths, c"N A H W F Na")
	int sa = gen_name_index(gen_class_names(), c"SA")
	int cm = gen_name_index(gen_class_names(), c"CM")
	int op = gen_name_index(gen_class_names(), c"OP")
	int cp_class = gen_name_index(gen_class_names(), c"CP")
	int mn = ('M' << 8) | 'n'
	int mc = ('M' << 8) | 'c'
	for cp in range(gen_max_cp + 1):
		int value = table[cp] & 255
		int category = categories[cp] & 65535
		if ((value == sa) && ((category == mn) || (category == mc))): table[cp] = cm
		# East_Asian_Width H, W and F are values 2, 3 and 4.
		if (((value == op) || (value == cp_class)) && (widths[cp] >= 2) && (widths[cp] <= 4)): table[cp] = value | gen_wide_flag
	# Extended_Pictographic code points that are still unassigned.
	wstream* src = gen_open(c"tools/unicode/emoji-data.txt")
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	int first = 0
	int last = 0
	int cn = ('C' << 8) | 'n'
	while (stream_read_line(src, line)):
		gen_split(line.data, f)
		if ((f.length < 2) || (strcmp(f[1], c"Extended_Pictographic") != 0)): continue
		gen_parse_range(f[0], &first, &last)
		for cp in range(first, last + 1):
			if ((categories[cp] & 65535) == cn): table[cp] = table[cp] | gen_pictographic_flag
	stream_close(src)
	return table


void gen_hex_byte(string_builder* out, int value):
	value = value & 255
	string_append_char(out, 92)
	string_append_char(out, 'x')
	int hi = value >> 4
	int lo = value & 15
	if (hi < 10): string_append_char(out, 48 + hi)
	else: string_append_char(out, 87 + hi)
	if (lo < 10): string_append_char(out, 48 + lo)
	else: string_append_char(out, 87 + lo)


int main(int argc, int argv):
	char* table = gen_load_classes()
	string_builder* literal = string_new()
	int count = 0
	for cp in range(gen_max_cp + 1):
		if ((cp == 0) || (table[cp] != table[cp - 1])):
			gen_hex_byte(literal, cp >> 16)
			gen_hex_byte(literal, cp >> 8)
			gen_hex_byte(literal, cp)
			gen_hex_byte(literal, table[cp])
			count = count + 1
	char* path = c"lib/linebreak_data.w"
	wstream* out = stream_open_write(path)
	if (out == 0): gen_fail(c"cannot write", path)
	stream_write_line(out, c"# Generated by tools/generate_linebreak_data.w from the Unicode database")
	stream_write_line(out, c"# files under tools/unicode/, version 15.0.0.")
	stream_write_line(out, c"# A build output, never committed: any ./wbuild run regenerates it (issue #323).")
	stream_write_line(out, c"# Range table: 4-byte entries (24-bit big-endian start, value byte); the")
	stream_write_line(out, c"# value is an lb_class_* number, plus 64 for an East Asian wide OP or CP and 128")
	stream_write_line(out, c"# for an unassigned Extended_Pictographic code point.")
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_line(out, f"int lbd_classes_count():")
	stream_write_line(out, f"\treturn {count}")
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_line(out, c"char* lbd_classes():")
	stream_write_cstr(out, c"\treturn c\"")
	stream_write(out, literal.data, literal.length)
	stream_write_line(out, c"\"")
	stream_close(out)
	print(f"generated {path} ({count} ranges)\n")
	return 0
