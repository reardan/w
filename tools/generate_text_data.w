# wbuild: target=unicode_text_data tag=generated dep=wv2 input=tools/unicode/ input=tools/generate_text_data.w output=lib/unicode_text_data.w
# wbuild: step="bin/wv2 tools/generate_text_data.w -o bin/generate_text_data"
# wbuild: step="bin/generate_text_data"
# Emits lib/unicode_text_data.w, the compact text-layout tables behind
# lib/bidi.w and graphics/ui/shape_ot.w (issue #459), from the committed
# Unicode 15.0.0 Character Database files under tools/unicode/:
#   DerivedBidiClass.txt      Bidi_Class, including its @missing defaults
#   BidiBrackets.txt          Bidi_Paired_Bracket(_Type) for rule N0
#   BidiMirroring.txt         Bidi_Mirroring_Glyph for RTL glyph selection
#   ArabicShaping.txt         Joining_Type (with the documented T default
#                             for unlisted Mn/Me/Cf from UnicodeData.txt)
#   Scripts.txt               Script, with PropertyValueAliases.txt short
#                             names (ISO 15924 codes)
#   UnicodeData.txt           General_Category, Canonical_Combining_Class,
#                             canonical decompositions (with
#                             CompositionExclusions.txt for composition)
#                             and the <isolated>/<final>/<initial>/<medial>
#                             Arabic presentation forms (shaping fallback)
# The files are unmodified copies of the unicodetools 15.0.0 data
# (unicodetools/data/ucd/15.0.0/, DerivedBidiClass.txt from extracted/).
#
# Every table is a byte-string literal read in place. Range tables hold
# 4-byte entries (24-bit big-endian start, 1-byte value): an entry's value
# covers every codepoint up to the next entry's start.
#
# Run from the repo root: ./wbuild unicode_text_data
import lib.lib
import lib.stream
import structures.string


const int gen_max_cp = 1114111


void gen_fail(char* message, char* detail):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"generate_text_data: ")
	stream_write_cstr(err, message)
	if (detail != 0):
		stream_write_cstr(err, c": ")
		stream_write_cstr(err, detail)
	stream_write_line(err, c"")
	stream_flush(err)
	exit(1)


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


# Short Bidi_Class names in unicode_bidi_* order (libs/standard/text/
# unicodedata.w); index 0 is unused.
char* gen_bidi_names():
	return c"- L R AL EN ES ET AN CS NSM BN B S WS ON LRE LRO RLE RLO PDF LRI RLI FSI PDI"


# The long names DerivedBidiClass.txt uses on its @missing lines, in the
# same order.
char* gen_bidi_long_names():
	return c"- Left_To_Right Right_To_Left Arabic_Letter European_Number European_Separator European_Terminator Arabic_Number Common_Separator Nonspacing_Mark Boundary_Neutral Paragraph_Separator Segment_Separator White_Space Other_Neutral Left_To_Right_Embedding Left_To_Right_Override Right_To_Left_Embedding Right_To_Left_Override Pop_Directional_Format Left_To_Right_Isolate Right_To_Left_Isolate First_Strong_Isolate Pop_Directional_Isolate"


# General_Category names in the unicode_cat_* order of
# libs/standard/text/unicodedata.w (Cn = 0).
char* gen_category_names():
	return c"Cn Lu Ll Lt Lm Lo Mn Mc Me Nd Nl No Pc Pd Ps Pe Pi Pf Po Sm Sc Sk So Zs Zl Zp Cc Cf Cs Co"


# Arabic form tags, numbered as lib/unicode_text.w's ut_form_* constants.
char* gen_form_names():
	return c"- <isolated> <final> <initial> <medial>"


# Joining_Type values in the order lib/unicode_text_data.w documents.
char* gen_joining_names():
	return c"U T R L D C"


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


# Parses whitespace-separated hex codepoints from text into out (cleared
# first).
void gen_parse_cps(char* text, list[int] out):
	out.clear()
	int i = 0
	while (text[i] != 0):
		while (gen_is_space(text[i])): i = i + 1
		if (text[i] == 0): return
		out.push(gen_parse_hex(&text[i]))
		while ((text[i] != 0) && (gen_is_space(text[i]) == 0)): i = i + 1


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


# DerivedBidiClass.txt: "# @missing: a..b; Long_Name" defaults first (in
# file order, later lines refine earlier ones), then the explicit lines.
char* gen_load_bidi():
	char* table = gen_table(0)
	wstream* src = gen_open(c"tools/unicode/DerivedBidiClass.txt")
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	int first = 0
	int last = 0
	while (stream_read_line(src, line)):
		char* text = line.data
		if (starts_with(text, c"# @missing: ")):
			text = &text[12]
			gen_split(text, f)
			if (f.length < 2): gen_fail(c"short @missing line", text)
			int value = gen_name_index(gen_bidi_long_names(), f[1])
			if (value <= 0): gen_fail(c"unknown bidi class", f[1])
			gen_parse_range(f[0], &first, &last)
			gen_fill(table, first, last, value)
			continue
		gen_split(text, f)
		if ((f.length < 2) || (f[0][0] == 0)): continue
		int value = gen_name_index(gen_bidi_names(), f[1])
		if (value <= 0): gen_fail(c"unknown bidi class", f[1])
		gen_parse_range(f[0], &first, &last)
		gen_fill(table, first, last, value)
	stream_close(src)
	for cp in range(gen_max_cp + 1):
		if (table[cp] == 0): gen_fail(c"codepoint without a bidi class", 0)
	return table


struct gen_ucd:
	char* category
	char* ccc
	# Single-letter presentation forms: (letter, form, presentation) triples,
	# and lam-alef ligatures: (alef, form, presentation).
	list[int] forms
	list[int] lam_alef
	# Canonical decompositions: (cp, first, second) with second 0 for a
	# singleton.
	list[int] decomp


void gen_form_entry(list[int] table, int base, int form, int presentation):
	# Presentation Forms-B (U+FE70..) wins over an earlier Forms-A entry.
	for i in range(0, table.length, 3):
		if ((table[i] == base) && (table[i + 1] == form)):
			table[i + 2] = presentation
			return
	table.push(base)
	table.push(form)
	table.push(presentation)


# One pass over UnicodeData.txt: General_Category, combining classes and
# the Arabic presentation-form decompositions.
gen_ucd* gen_load_ucd():
	gen_ucd* ucd = new gen_ucd
	ucd.category = gen_table(0)
	ucd.ccc = gen_table(0)
	ucd.forms = new list[int]
	ucd.lam_alef = new list[int]
	ucd.decomp = new list[int]
	wstream* src = gen_open(c"tools/unicode/UnicodeData.txt")
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	list[int] cps = new list[int]
	int pending = -1
	while (stream_read_line(src, line)):
		if (line.length == 0): continue
		gen_split(line.data, f)
		if (f.length < 6): gen_fail(c"short UnicodeData.txt line", f[0])
		int cp = gen_parse_hex(f[0])
		if (ends_with(f[1], c", First>")):
			pending = cp
			continue
		int first = cp
		if (ends_with(f[1], c", Last>")): first = pending
		int category = gen_name_index(gen_category_names(), f[2])
		if (category < 0): gen_fail(c"unknown category", f[2])
		gen_fill(ucd.category, first, cp, category)
		gen_fill(ucd.ccc, first, cp, atoi(f[3]))
		char* d = f[5]
		if (d[0] == 0): continue
		if (d[0] != '<'):
			gen_parse_cps(d, cps)
			if ((cps.length < 1) || (cps.length > 2)): gen_fail(c"long canonical decomposition", f[0])
			ucd.decomp.push(cp)
			ucd.decomp.push(cps[0])
			if (cps.length == 2): ucd.decomp.push(cps[1])
			else: ucd.decomp.push(0)
			continue
		int close = 0
		while ((d[close] != '>') && (d[close] != 0)): close = close + 1
		if (d[close] == 0): continue
		d[close + 1] = 0
		int form = gen_name_index(gen_form_names(), d)
		if (form <= 0): continue
		gen_parse_cps(&d[close + 2], cps)
		int presentation = ((cp >= 0xfb50) && (cp <= 0xfdff)) || ((cp >= 0xfe70) && (cp <= 0xfeff))
		if (!presentation): continue
		if (cps.length == 1): gen_form_entry(ucd.forms, cps[0], form, cp)
		else if ((cps.length == 2) && (cps[0] == 0x0644) && (cp >= 0xfef5) && (cp <= 0xfefc)): gen_form_entry(ucd.lam_alef, cps[1], form, cp)
	stream_close(src)
	return ucd


# Joining_Type: unlisted Mn, Me and Cf are T, everything else unlisted U.
char* gen_load_joining(gen_ucd* ucd):
	char* table = gen_table(0)
	for cp in range(gen_max_cp + 1):
		int category = ucd.category[cp]
		# Mn = 6, Me = 8, Cf = 27 in gen_category_names order.
		if ((category == 6) || (category == 8) || (category == 27)): table[cp] = 1
	wstream* src = gen_open(c"tools/unicode/ArabicShaping.txt")
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	int first = 0
	int last = 0
	while (stream_read_line(src, line)):
		gen_split(line.data, f)
		if ((f.length < 3) || (f[0][0] == 0)): continue
		int value = gen_name_index(gen_joining_names(), f[2])
		if (value < 0): gen_fail(c"unknown joining type", f[2])
		gen_parse_range(f[0], &first, &last)
		gen_fill(table, first, last, value)
	stream_close(src)
	return table


# Script long name -> ISO 15924 code, from PropertyValueAliases.txt's
# "sc ; Code ; Long_Name [; alias]" lines. codes[i] is the 4-letter code of
# script id i; id 0 is Zzzz (Unknown), the @missing default.
char* gen_load_scripts(list[char*] codes):
	map[char*, int] ids = new map[char*, int]
	codes.push(c"Zzzz")
	ids[c"Unknown"] = 0
	wstream* src = gen_open(c"tools/unicode/PropertyValueAliases.txt")
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	while (stream_read_line(src, line)):
		gen_split(line.data, f)
		if ((f.length < 3) || (strcmp(f[0], c"sc") != 0)): continue
		if (strcmp(f[1], c"Zzzz") == 0): continue
		if (strlen(f[1]) != 4): gen_fail(c"script code is not 4 letters", f[1])
		ids[strclone(f[2])] = codes.length
		codes.push(strclone(f[1]))
	stream_close(src)
	if (codes.length > 255): gen_fail(c"too many scripts", 0)
	char* table = gen_table(0)
	src = gen_open(c"tools/unicode/Scripts.txt")
	int first = 0
	int last = 0
	while (stream_read_line(src, line)):
		gen_split(line.data, f)
		if ((f.length < 2) || (f[0][0] == 0)): continue
		int id = ids.get(f[1], -1)
		if (id < 0): gen_fail(c"unknown script", f[1])
		gen_parse_range(f[0], &first, &last)
		gen_fill(table, first, last, id)
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


void gen_u24(string_builder* out, int value):
	gen_hex_byte(out, value >> 16)
	gen_hex_byte(out, value >> 8)
	gen_hex_byte(out, value)


void gen_function(wstream* out, char* name, string_builder* literal):
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_cstr(out, c"char* ")
	stream_write_cstr(out, name)
	stream_write_line(out, c"():")
	stream_write_cstr(out, c"\treturn c\"")
	stream_write(out, literal.data, literal.length)
	stream_write_line(out, c"\"")


void gen_int_function(wstream* out, char* name, int value):
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_cstr(out, c"int ")
	stream_write_cstr(out, name)
	stream_write_line(out, c"():")
	stream_write_cstr(out, c"\treturn ")
	stream_write_int(out, value)
	stream_write_line(out, c"")


# A per-codepoint table as start/value range entries.
void gen_ranges(wstream* out, char* name, char* table):
	string_builder* literal = string_new()
	int count = 0
	for cp in range(gen_max_cp + 1):
		if ((cp == 0) || (table[cp] != table[cp - 1])):
			gen_u24(literal, cp)
			gen_hex_byte(literal, table[cp])
			count = count + 1
	gen_int_function(out, f"{name}_count", count)
	gen_function(out, name, literal)


# "XXXX; YYYY [; type]" pair files as 6-byte (first, second) entries, in
# file order (ascending first codepoint). With a type field, a 'c'
# (closing) entry is skipped: openers list their own closer.
void gen_pairs(wstream* out, char* name, char* path, int typed):
	wstream* src = gen_open(path)
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	string_builder* literal = string_new()
	int count = 0
	int previous = -1
	while (stream_read_line(src, line)):
		gen_split(line.data, f)
		if ((f.length < 2) || (f[0][0] == 0)): continue
		if (typed && (f.length > 2) && (f[2][0] == 'c')): continue
		int first = gen_parse_hex(f[0])
		if (first <= previous): gen_fail(c"pair file is not sorted", f[0])
		previous = first
		gen_u24(literal, first)
		gen_u24(literal, gen_parse_hex(f[1]))
		count = count + 1
	stream_close(src)
	gen_int_function(out, f"{name}_count", count)
	gen_function(out, name, literal)


int gen_pair_after(list[int] pairs, int x, int y):
	if (pairs[x * 3] != pairs[y * 3]): return pairs[x * 3] > pairs[y * 3]
	return pairs[x * 3 + 1] > pairs[y * 3 + 1]


# Canonical decomposition entries (cp, first, second) as 9 bytes sorted by
# cp, and the canonical compositions as (first, second, cp) sorted by
# the pair: pairs only, without singletons, non-starter decompositions or
# the CompositionExclusions.txt list (the Full_Composition_Exclusion set).
void gen_decompositions(wstream* out, gen_ucd* ucd):
	string_builder* literal = string_new()
	int n = ucd.decomp.length / 3
	for i in range(n):
		for k in range(3): gen_u24(literal, ucd.decomp[i * 3 + k])
	gen_int_function(out, c"utd_decomp_count", n)
	gen_function(out, c"utd_decomp", literal)
	char* excluded = gen_table(0)
	wstream* src = gen_open(c"tools/unicode/CompositionExclusions.txt")
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	int first = 0
	int last = 0
	while (stream_read_line(src, line)):
		gen_split(line.data, f)
		if ((f.length < 1) || (f[0][0] == 0)): continue
		gen_parse_range(f[0], &first, &last)
		gen_fill(excluded, first, last, 1)
	stream_close(src)
	list[int] pairs = new list[int]
	for i in range(n):
		int cp = ucd.decomp[i * 3]
		int a = ucd.decomp[i * 3 + 1]
		int b = ucd.decomp[i * 3 + 2]
		if ((b == 0) || excluded[cp] || (ucd.ccc[a] != 0)): continue
		pairs.push(a)
		pairs.push(b)
		pairs.push(cp)
	int m = pairs.length / 3
	# Sort by (first, second).
	for i in range(1, m):
		int j = i
		while ((j > 0) && gen_pair_after(pairs, j - 1, j)):
			for k in range(3):
				int swap = pairs[(j - 1) * 3 + k]
				pairs[(j - 1) * 3 + k] = pairs[j * 3 + k]
				pairs[j * 3 + k] = swap
			j = j - 1
	string_builder* compose = string_new()
	for i in range(m):
		for k in range(3): gen_u24(compose, pairs[i * 3 + k])
	gen_int_function(out, c"utd_compose_count", m)
	gen_function(out, c"utd_compose", compose)


# (base, form, presentation) triples as 7-byte entries sorted by base
# and form.
void gen_triples(wstream* out, char* name, list[int] table):
	int n = table.length / 3
	# Insertion sort by (base, form); the lists are small.
	for i in range(1, n):
		int j = i
		while ((j > 0) && ((table[(j - 1) * 3] * 8 + table[(j - 1) * 3 + 1]) > (table[j * 3] * 8 + table[j * 3 + 1]))):
			for k in range(3):
				int swap = table[(j - 1) * 3 + k]
				table[(j - 1) * 3 + k] = table[j * 3 + k]
				table[j * 3 + k] = swap
			j = j - 1
	string_builder* literal = string_new()
	for i in range(n):
		gen_u24(literal, table[i * 3])
		gen_hex_byte(literal, table[i * 3 + 1])
		gen_u24(literal, table[i * 3 + 2])
	gen_int_function(out, f"{name}_count", n)
	gen_function(out, name, literal)


int main(int argc, int argv):
	char* bidi = gen_load_bidi()
	gen_ucd* ucd = gen_load_ucd()
	char* joining = gen_load_joining(ucd)
	list[char*] codes = new list[char*]
	char* scripts = gen_load_scripts(codes)
	char* path = c"lib/unicode_text_data.w"
	wstream* out = stream_open_write(path)
	if (out == 0): gen_fail(c"cannot write", path)
	stream_write_line(out, c"# Generated by tools/generate_text_data.w from the Unicode database")
	stream_write_line(out, c"# files under tools/unicode/, version 15.0.0.")
	stream_write_line(out, c"# A build output, never committed: any ./wbuild run regenerates it (issue #323).")
	stream_write_line(out, c"# Range tables: 4-byte entries (24-bit big-endian start, value byte).")
	stream_write_line(out, c"# Bidi values are unicode_bidi_* numbers (L=1 .. PDI=23); joining values")
	stream_write_line(out, c"# are U=0 T=1 R=2 L=3 D=4 C=5; script values index utd_script_codes;")
	stream_write_line(out, c"# category values are unicode_cat_* numbers (Cn=0 .. Co=29).")
	gen_ranges(out, c"utd_bidi", bidi)
	gen_ranges(out, c"utd_joining", joining)
	gen_ranges(out, c"utd_script", scripts)
	gen_ranges(out, c"utd_category", ucd.category)
	gen_ranges(out, c"utd_ccc", ucd.ccc)
	gen_triples(out, c"utd_arabic_forms", ucd.forms)
	gen_triples(out, c"utd_lam_alef", ucd.lam_alef)
	gen_decompositions(out, ucd)
	string_builder* names = string_new()
	for code in codes: string_append(names, code)
	gen_int_function(out, c"utd_script_code_count", codes.length)
	gen_function(out, c"utd_script_codes", names)
	gen_pairs(out, c"utd_brackets", c"tools/unicode/BidiBrackets.txt", 1)
	gen_pairs(out, c"utd_mirrors", c"tools/unicode/BidiMirroring.txt", 0)
	stream_close(out)
	print(f"generated {path}\n")
	return 0
