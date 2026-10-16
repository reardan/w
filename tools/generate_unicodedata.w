# wbuild: target=unicodedata_data tag=generated dep=wv2 input=tools/unicode/ input=tools/generate_unicodedata.w output=libs/standard/text/unicodedata_data.w
# wbuild: step="bin/wv2 tools/generate_unicodedata.w -o bin/generate_unicodedata"
# wbuild: step="bin/generate_unicodedata"
# Emits libs/standard/text/unicodedata_data.w, the lookup tables behind
# libs/standard/text/unicodedata.w, from the committed Unicode 15.0.0
# Character Database files under tools/unicode/:
#
#   UnicodeData.txt            categories, bidi classes, combining classes,
#                              numeric values, simple case mappings and
#                              decompositions
#   CaseFolding.txt            simple (C+S) and full (C+F) case folding
#   SpecialCasing.txt          unconditional full upper/lower/title mappings
#   DerivedNumericValues.txt   numeric values, including Unihan ones
#                              (extracted/ in the UCD)
#   CompositionExclusions.txt  script-specific and post-composition-version
#                              exclusions; the rest of Full_Composition_Exclusion
#                              (singletons, non-starter decompositions) is
#                              derived from UnicodeData.txt here
#
# The four files beside UnicodeData.txt are the unmodified 15.0.0 UCD
# files as mirrored in github.com/unicode-org/unicodetools
# (unicodetools/data/ucd/15.0.0/, DerivedNumericValues.txt from its
# extracted/ directory); that mirror's UnicodeData.txt is byte-identical
# to the committed one.
#
# Every table is a byte string (c"\x.." literal) read in place, so lookups
# allocate nothing:
#
#   index1   2 bytes per 128-codepoint block: the block's id
#   index2   2 bytes per codepoint of each distinct block: a record index
#   records  ud_record_size bytes per distinct property record (layout in
#            gen_record_key below and unicodedata.w)
#   decomp   sorted by codepoint: cp(3) tag(1) count(1) offset(2) where
#            offset indexes decomp_cps (3 bytes per codepoint)
#   compose  primary composites sorted by (first, second): first(3) second(3)
#            composite(3); Hangul syllables are algorithmic, not listed
#   special  full case mappings sorted by (cp, kind): cp(3) kind(1)
#            count(1) cps(3 x 3), kind 0 lower, 1 title, 2 upper, 3 fold
#   numeric  NUL-terminated numeric value texts ("1/2"), offsets 2 bytes each
#
# Run from the repo root: ./wbuild unicodedata_data
import lib.lib
import lib.stream
import structures.string


const int gen_cp_count = 1114112
const int gen_shift = 7
const int gen_block = 128
const int gen_record_size = 21
const int gen_bias = 8388608
const int gen_max_full = 3


# Update together with tools/unicode/*.txt.
char* gen_unicode_version():
	return c"15.0.0"


# Must match the UNICODE_CAT_* order in libs/standard/text/unicodedata.w.
char* gen_category_names():
	return c"Cn Lu Ll Lt Lm Lo Mn Mc Me Nd Nl No Pc Pd Ps Pe Pi Pf Po Sm Sc Sk So Zs Zl Zp Cc Cf Cs Co"


# Must match the UNICODE_BIDI_* order in unicodedata.w (index 0 is the
# empty class of unassigned codepoints).
char* gen_bidi_names():
	return c"- L R AL EN ES ET AN CS NSM BN B S WS ON LRE LRO RLE RLO PDF LRI RLI FSI PDI"


# Decomposition tags; index 0 is a canonical decomposition.
char* gen_tag_names():
	return c"- <font> <noBreak> <initial> <medial> <final> <isolated> <circle> <super> <sub> <vertical> <wide> <narrow> <small> <square> <fraction> <compat>"


void gen_fail(char* message, char* detail):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"generate_unicodedata: ")
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


int gen_hex_digit(int c):
	if ((c >= '0') && (c <= '9')): return c - '0'
	if ((c >= 'a') && (c <= 'f')): return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')): return c - 'A' + 10
	return -1


int gen_is_space(int c):
	return (c == ' ') || (c == 9)


# Parses whitespace-separated hex codepoints from text into out (cleared
# first).
void gen_parse_cps(char* text, list[int] out):
	out.clear()
	int i = 0
	while (text[i] != 0):
		while (gen_is_space(text[i])): i = i + 1
		if (text[i] == 0): return
		int value = 0
		while (gen_hex_digit(text[i]) >= 0):
			value = value * 16 + gen_hex_digit(text[i])
			i = i + 1
		out.push(value)
		while ((text[i] != 0) && (gen_is_space(text[i]) == 0)): i = i + 1


int gen_parse_hex(char* text):
	int i = 0
	while (gen_is_space(text[i])): i = i + 1
	int value = 0
	while (gen_hex_digit(text[i]) >= 0):
		value = value * 16 + gen_hex_digit(text[i])
		i = i + 1
	return value


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


struct gen_db:
	char* category
	char* bidi
	char* combining
	char* decimal
	char* digit
	char* mirrored
	char* flags
	char* excluded
	int* numeric
	int* upper
	int* lower
	int* title
	int* fold
	list[char*] numeric_texts
	map[char*, int] numeric_ids
	list[int] decomp_cp
	list[int] decomp_tag
	list[int] decomp_offset
	list[int] decomp_count
	list[int] decomp_cps
	list[int] special_cp
	list[int] special_kind
	list[int] special_cps


char* gen_bytes(int count):
	char* p = cast(char*, malloc(count))
	for i in range(count): p[i] = 0
	return p


int* gen_ints(int count, int value):
	int* p = cast(int*, malloc(count * __word_size__))
	for i in range(count): p[i] = value
	return p


gen_db* gen_db_new():
	gen_db* db = new gen_db()
	db.category = gen_bytes(gen_cp_count)
	db.bidi = gen_bytes(gen_cp_count)
	db.combining = gen_bytes(gen_cp_count)
	db.decimal = gen_bytes(gen_cp_count)
	db.digit = gen_bytes(gen_cp_count)
	db.mirrored = gen_bytes(gen_cp_count)
	db.flags = gen_bytes(gen_cp_count)
	db.excluded = gen_bytes(gen_cp_count)
	db.numeric = gen_ints(gen_cp_count, 0)
	db.upper = gen_ints(gen_cp_count, -1)
	db.lower = gen_ints(gen_cp_count, -1)
	db.title = gen_ints(gen_cp_count, -1)
	db.fold = gen_ints(gen_cp_count, -1)
	db.numeric_texts = new list[char*]
	db.numeric_ids = new map[char*, int]
	db.decomp_cp = new list[int]
	db.decomp_tag = new list[int]
	db.decomp_offset = new list[int]
	db.decomp_count = new list[int]
	db.decomp_cps = new list[int]
	db.special_cp = new list[int]
	db.special_kind = new list[int]
	db.special_cps = new list[int]
	return db


wstream* gen_open(char* path):
	wstream* stream = stream_open_read(path)
	if (stream == 0): gen_fail(c"cannot open (run from the repo root)", path)
	return stream


void gen_set_numeric(gen_db* db, int cp, char* value):
	int id = db.numeric_ids.get(value, 0)
	if (id == 0):
		char* text = strclone(value)
		db.numeric_texts.push(text)
		id = db.numeric_texts.length
		db.numeric_ids[text] = id
	db.numeric[cp] = id


# Stores one UnicodeData.txt record (already split into fields) for cp.
void gen_assign(gen_db* db, int cp, list[char*] f, list[int] cps):
	int cat = gen_name_index(gen_category_names(), f[2])
	if (cat < 0): gen_fail(c"unknown category", f[2])
	db.category[cp] = cat
	int bidi = gen_name_index(gen_bidi_names(), f[4])
	if (bidi <= 0): gen_fail(c"unknown bidi class", f[4])
	db.bidi[cp] = bidi
	db.combining[cp] = atoi(f[3])
	if (f[6][0] != 0): db.decimal[cp] = atoi(f[6]) + 1
	if (f[7][0] != 0): db.digit[cp] = atoi(f[7]) + 1
	if (f[8][0] != 0): gen_set_numeric(db, cp, f[8])
	if (f[9][0] == 'Y'): db.mirrored[cp] = 1
	if (f[12][0] != 0): db.upper[cp] = gen_parse_hex(f[12])
	if (f[13][0] != 0): db.lower[cp] = gen_parse_hex(f[13])
	if (f[14][0] != 0): db.title[cp] = gen_parse_hex(f[14])
	else: db.title[cp] = db.upper[cp]
	char* d = f[5]
	if (d[0] == 0): return
	int tag = 0
	if (d[0] == '<'):
		int close = 0
		while (d[close] != '>'): close = close + 1
		d[close + 1] = 0
		tag = gen_name_index(gen_tag_names(), d)
		if (tag <= 0): gen_fail(c"unknown decomposition tag", d)
		d = &d[close + 2]
	gen_parse_cps(d, cps)
	db.decomp_cp.push(cp)
	db.decomp_tag.push(tag)
	db.decomp_offset.push(db.decomp_cps.length)
	db.decomp_count.push(cps.length)
	for c in cps: db.decomp_cps.push(c)
	db.flags[cp] = db.flags[cp] | 4


void gen_load_unicode_data(gen_db* db):
	wstream* in = gen_open(c"tools/unicode/UnicodeData.txt")
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	list[int] cps = new list[int]
	int pending_first = -1
	while (stream_read_line(in, line)):
		if (line.length == 0): continue
		gen_split(line.data, f)
		if (f.length < 15): gen_fail(c"short UnicodeData.txt line", f[0])
		int cp = gen_parse_hex(f[0])
		if (ends_with(f[1], c", First>")):
			pending_first = cp
			continue
		if (ends_with(f[1], c", Last>")):
			for fill in range(pending_first, cp + 1): gen_assign(db, fill, f, cps)
			pending_first = -1
			continue
		gen_assign(db, cp, f, cps)
	f.free()
	cps.free()
	string_free(line)
	stream_close(in)


# DerivedNumericValues.txt: cp or first..last; decimal; ; rational. It
# adds the Unihan numeric values (kPrimaryNumeric and friends) that
# UnicodeData.txt leaves out, as Python's unicodedata.numeric reports them.
void gen_load_numeric_values(gen_db* db):
	wstream* in = gen_open(c"tools/unicode/DerivedNumericValues.txt")
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	while (stream_read_line(in, line)):
		gen_split(line.data, f)
		if ((f.length < 4) || (f[0][0] == 0)): continue
		int first = gen_parse_hex(f[0])
		int last = first
		int dots = 0
		while ((f[0][dots] != 0) && (f[0][dots] != '.')): dots = dots + 1
		if (f[0][dots] == '.'): last = gen_parse_hex(&f[0][dots + 2])
		for cp in range(first, last + 1): gen_set_numeric(db, cp, f[3])
	f.free()
	string_free(line)
	stream_close(in)


void gen_add_special(gen_db* db, int cp, int kind, list[int] cps):
	if (cps.length > gen_max_full): gen_fail(c"full mapping longer than 3", 0)
	db.special_cp.push(cp)
	db.special_kind.push(kind)
	for i in range(gen_max_full):
		if (i < cps.length): db.special_cps.push(cps[i])
		else: db.special_cps.push(-1)
	db.flags[cp] = db.flags[cp] | 1


void gen_load_case_folding(gen_db* db):
	wstream* in = gen_open(c"tools/unicode/CaseFolding.txt")
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	list[int] cps = new list[int]
	while (stream_read_line(in, line)):
		gen_split(line.data, f)
		if ((f.length < 3) || (f[0][0] == 0)): continue
		int cp = gen_parse_hex(f[0])
		int status = f[1][0]
		gen_parse_cps(f[2], cps)
		if ((status == 'C') || (status == 'S')): db.fold[cp] = cps[0]
		if (status == 'F'):
			gen_add_special(db, cp, 3, cps)
			db.flags[cp] = db.flags[cp] | 2
	f.free()
	cps.free()
	string_free(line)
	stream_close(in)


# Unconditional SpecialCasing.txt lines: code; lower; title; upper; # ...
# Lines with a condition field (Final_Sigma, language tags) are skipped.
void gen_load_special_casing(gen_db* db):
	wstream* in = gen_open(c"tools/unicode/SpecialCasing.txt")
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	list[int] cps = new list[int]
	while (stream_read_line(in, line)):
		gen_split(line.data, f)
		if ((f.length < 4) || (f[0][0] == 0)): continue
		if ((f.length > 4) && (f[4][0] != 0)): continue
		int cp = gen_parse_hex(f[0])
		for kind in range(3):
			gen_parse_cps(f[kind + 1], cps)
			gen_add_special(db, cp, kind, cps)
	f.free()
	cps.free()
	string_free(line)
	stream_close(in)


void gen_load_exclusions(gen_db* db):
	wstream* in = gen_open(c"tools/unicode/CompositionExclusions.txt")
	string_builder* line = string_new()
	list[char*] f = new list[char*]
	while (stream_read_line(in, line)):
		gen_split(line.data, f)
		if (f[0][0] == 0): continue
		db.excluded[gen_parse_hex(f[0])] = 1
	f.free()
	string_free(line)
	stream_close(in)


# Special entries arrive grouped by file; sort them by (cp, kind) with an
# index permutation (a few hundred entries, insertion sort is plenty).
list[int] gen_special_order(gen_db* db):
	list[int] order = new list[int]
	for i in range(db.special_cp.length):
		order.push(i)
		int j = order.length - 1
		while (j > 0):
			int a = order[j - 1]
			int b = order[j]
			int later = (db.special_cp[a] > db.special_cp[b]) || ((db.special_cp[a] == db.special_cp[b]) && (db.special_kind[a] > db.special_kind[b]))
			if (later == 0): break
			order[j - 1] = b
			order[j] = a
			j = j - 1
	return order


# Primary composites: canonical pairs not in Full_Composition_Exclusion
# (the exclusion file, singletons, and non-starter decompositions), as
# flat (first, second, composite) triples sorted by (first, second).
list[int] gen_compositions(gen_db* db):
	list[int] triples = new list[int]
	for i in range(db.decomp_cp.length):
		int cp = db.decomp_cp[i]
		if (db.decomp_tag[i] != 0): continue
		if (db.decomp_count[i] != 2): continue
		if (db.excluded[cp]): continue
		int first = db.decomp_cps[db.decomp_offset[i]]
		int second = db.decomp_cps[db.decomp_offset[i] + 1]
		if (db.combining[cp] != 0): continue
		if (db.combining[first] != 0): continue
		triples.push(first)
		triples.push(second)
		triples.push(cp)
		int j = triples.length - 3
		while (j > 0):
			int earlier = (triples[j - 3] < triples[j]) || ((triples[j - 3] == triples[j]) && (triples[j - 2] < triples[j + 1]))
			if (earlier): break
			for k in range(3):
				int t = triples[j - 3 + k]
				triples[j - 3 + k] = triples[j + k]
				triples[j + k] = t
			j = j - 3
	return triples


# ---- emission --------------------------------------------------------

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


void gen_u16(string_builder* out, int value):
	if ((value < 0) || (value > 65535)): gen_fail(c"value does not fit 16 bits", 0)
	gen_hex_byte(out, value >> 8)
	gen_hex_byte(out, value)


void gen_u24(string_builder* out, int value):
	if ((value < 0) || (value > 16777215)): gen_fail(c"value does not fit 24 bits", 0)
	gen_hex_byte(out, value >> 16)
	gen_hex_byte(out, value >> 8)
	gen_hex_byte(out, value)


# A mapping as a biased delta from cp (identity is a zero delta).
int gen_delta(int* table, int cp):
	if (table[cp] < 0): return gen_bias
	return gen_bias + table[cp] - cp


# One record as escaped bytes: category, bidi, combining, decimal+1,
# digit+1, mirrored, numeric id (2), upper/lower/title/fold deltas (3
# each), flags (1 special casing, 2 full fold, 4 decomposition).
void gen_record(gen_db* db, int cp, string_builder* out):
	gen_hex_byte(out, db.category[cp])
	gen_hex_byte(out, db.bidi[cp])
	gen_hex_byte(out, db.combining[cp])
	gen_hex_byte(out, db.decimal[cp])
	gen_hex_byte(out, db.digit[cp])
	gen_hex_byte(out, db.mirrored[cp])
	gen_u16(out, db.numeric[cp])
	gen_u24(out, gen_delta(db.upper, cp))
	gen_u24(out, gen_delta(db.lower, cp))
	gen_u24(out, gen_delta(db.title, cp))
	gen_u24(out, gen_delta(db.fold, cp))
	gen_hex_byte(out, db.flags[cp])


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


void gen_emit(gen_db* db, wstream* out):
	stream_write_line(out, c"# Generated by tools/generate_unicodedata.w from the Unicode database")
	stream_write_cstr(out, c"# files under tools/unicode/, version ")
	stream_write_cstr(out, gen_unicode_version())
	stream_write_line(out, c".")
	stream_write_line(out, c"# A build output, never committed: any ./wbuild run regenerates it (issue #323).")

	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_line(out, c"char* ud_unicode_version():")
	stream_write_cstr(out, c"\treturn c\"")
	stream_write_cstr(out, gen_unicode_version())
	stream_write_line(out, c"\"")

	# Property records, deduplicated; then 128-codepoint blocks of record
	# indexes, deduplicated.
	map[char*, int] record_ids = new map[char*, int]
	string_builder* records = string_new()
	int* record_of = gen_ints(gen_cp_count, 0)
	string_builder* key = string_new()
	for cp in range(gen_cp_count):
		string_clear(key)
		gen_record(db, cp, key)
		int id = record_ids.get(key.data, -1)
		if (id < 0):
			id = record_ids.length
			record_ids[strclone(key.data)] = id
			string_append_bytes(records, key.data, key.length)
		record_of[cp] = id

	map[char*, int] block_ids = new map[char*, int]
	string_builder* index1 = string_new()
	string_builder* index2 = string_new()
	int blocks = gen_cp_count >> gen_shift
	for b in range(blocks):
		string_clear(key)
		for k in range(gen_block): gen_u16(key, record_of[b * gen_block + k])
		int id = block_ids.get(key.data, -1)
		if (id < 0):
			id = block_ids.length
			block_ids[strclone(key.data)] = id
			string_append_bytes(index2, key.data, key.length)
		gen_u16(index1, id)

	gen_int_function(out, c"ud_shift", gen_shift)
	gen_int_function(out, c"ud_record_size", gen_record_size)
	gen_int_function(out, c"ud_record_count", record_ids.length)
	gen_int_function(out, c"ud_block_count", block_ids.length)
	gen_function(out, c"ud_index1", index1)
	gen_function(out, c"ud_index2", index2)
	gen_function(out, c"ud_records", records)

	string_builder* decomp = string_new()
	string_builder* decomp_cps = string_new()
	for i in range(db.decomp_cp.length):
		gen_u24(decomp, db.decomp_cp[i])
		gen_hex_byte(decomp, db.decomp_tag[i])
		gen_hex_byte(decomp, db.decomp_count[i])
		gen_u16(decomp, db.decomp_offset[i])
	for c in db.decomp_cps: gen_u24(decomp_cps, c)
	gen_int_function(out, c"ud_decomp_count", db.decomp_cp.length)
	gen_function(out, c"ud_decomp", decomp)
	gen_function(out, c"ud_decomp_cps", decomp_cps)

	list[int] triples = gen_compositions(db)
	string_builder* compose = string_new()
	for t in triples: gen_u24(compose, t)
	gen_int_function(out, c"ud_compose_count", triples.length / 3)
	gen_function(out, c"ud_compose", compose)

	list[int] order = gen_special_order(db)
	string_builder* special = string_new()
	for i in order:
		gen_u24(special, db.special_cp[i])
		gen_hex_byte(special, db.special_kind[i])
		int count = 0
		for k in range(gen_max_full):
			if (db.special_cps[i * gen_max_full + k] >= 0): count = count + 1
		gen_hex_byte(special, count)
		for k in range(gen_max_full):
			int c = db.special_cps[i * gen_max_full + k]
			if (c < 0): c = 0
			gen_u24(special, c)
	gen_int_function(out, c"ud_special_count", order.length)
	gen_function(out, c"ud_special", special)

	string_builder* numeric = string_new()
	string_builder* numeric_offsets = string_new()
	int offset = 0
	for text in db.numeric_texts:
		gen_u16(numeric_offsets, offset)
		int n = strlen(text)
		for i in range(n): gen_hex_byte(numeric, text[i])
		gen_hex_byte(numeric, 0)
		offset = offset + n + 1
	gen_function(out, c"ud_numeric", numeric)
	gen_function(out, c"ud_numeric_offsets", numeric_offsets)


int main(int argc, int argv):
	gen_db* db = gen_db_new()
	gen_load_unicode_data(db)
	gen_load_numeric_values(db)
	gen_load_case_folding(db)
	gen_load_special_casing(db)
	gen_load_exclusions(db)
	char* path = c"libs/standard/text/unicodedata_data.w"
	wstream* out = stream_open_write(path)
	if (out == 0): gen_fail(c"cannot write", path)
	gen_emit(db, out)
	stream_close(out)
	print(f"generated {path}\n")
	return 0
