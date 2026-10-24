# Unicode properties for text layout (issue #459): Bidi_Class, paired
# brackets, mirroring glyphs, Joining_Type and Script, read from the
# compact Unicode 15.0.0 tables in lib/unicode_text_data.w (a build output
# of tools/generate_text_data.w). Lookups allocate nothing.
#
# This is deliberately much smaller than libs/standard/text/unicodedata:
# bidi and shaping need only these properties, and the whole table set is
# about 12 KB of data.
import lib.unicode_text_data

# Bidi classes: the unicode_bidi_* numbering of libs/standard/text/unicodedata.
const int ut_bidi_l = 1
const int ut_bidi_r = 2
const int ut_bidi_al = 3
const int ut_bidi_en = 4
const int ut_bidi_es = 5
const int ut_bidi_et = 6
const int ut_bidi_an = 7
const int ut_bidi_cs = 8
const int ut_bidi_nsm = 9
const int ut_bidi_bn = 10
const int ut_bidi_b = 11
const int ut_bidi_s = 12
const int ut_bidi_ws = 13
const int ut_bidi_on = 14
const int ut_bidi_lre = 15
const int ut_bidi_lro = 16
const int ut_bidi_rle = 17
const int ut_bidi_rlo = 18
const int ut_bidi_pdf = 19
const int ut_bidi_lri = 20
const int ut_bidi_rli = 21
const int ut_bidi_fsi = 22
const int ut_bidi_pdi = 23

# Joining types (ArabicShaping.txt).
const int ut_join_u = 0
const int ut_join_t = 1
const int ut_join_r = 2
const int ut_join_l = 3
const int ut_join_d = 4
const int ut_join_c = 5

int ut_u24(char* p, int at):
	return ((p[at] & 255) << 16) | ((p[at + 1] & 255) << 8) | (p[at + 2] & 255)

# Value of the range entry covering cp in a 4-byte start/value table;
# out-of-range codepoints read as missing (0 = the table's own default).
int ut_range_value(char* table, int count, int cp):
	if ((cp < 0) || (cp > 1114111)): return 0
	int lo = 0
	int hi = count - 1
	while (lo < hi):
		int mid = (lo + hi + 1) >> 1
		if (ut_u24(table, mid * 4) <= cp): lo = mid
		else: hi = mid - 1
	return table[lo * 4 + 3] & 255

# Second codepoint of the 6-byte pair whose first is cp, or -1.
int ut_pair_lookup(char* table, int count, int cp):
	int lo = 0
	int hi = count - 1
	while (lo <= hi):
		int mid = (lo + hi) >> 1
		int first = ut_u24(table, mid * 6)
		if (first == cp): return ut_u24(table, mid * 6 + 3)
		if (first < cp): lo = mid + 1
		else: hi = mid - 1
	return -1

int ut_bidi_class(int cp):
	if ((cp < 0) || (cp > 1114111)): return ut_bidi_l
	return ut_range_value(utd_bidi(), utd_bidi_count(), cp)

int ut_joining_type(int cp):
	return ut_range_value(utd_joining(), utd_joining_count(), cp)

# Script id of cp; 0 is Zzzz (Unknown). ut_script_code names an id.
int ut_script(int cp):
	return ut_range_value(utd_script(), utd_script_count(), cp)

# The ISO 15924 code of a script id as 4 bytes (not terminated), or "Zzzz".
char* ut_script_code(int id):
	if ((id < 0) || (id >= utd_script_code_count())): id = 0
	return &utd_script_codes()[id * 4]

# Script id for a 4-letter ISO 15924 code, or -1.
int ut_script_from_code(char* code):
	char* codes = utd_script_codes()
	for id in range(utd_script_code_count()):
		int same = 1
		for k in range(4):
			if (codes[id * 4 + k] != code[k]): same = 0
		if (same): return id
	return -1

# Common (Zyyy) and Inherited (Zinh) take the script of their neighbours.
int ut_script_is_shared(int id):
	char* code = ut_script_code(id)
	if (code[0] != 'Z'): return 0
	return ((code[1] == 'y') && (code[2] == 'y') && (code[3] == 'y')) || ((code[1] == 'i') && (code[2] == 'n') && (code[3] == 'h')) || ((code[1] == 'z') && (code[2] == 'z') && (code[3] == 'z'))

# Bidi_Paired_Bracket_Type: 1 for an opener (partner = its closer), 2 for
# a closer (partner = its opener), 0 otherwise.
int ut_bracket(int cp, int* partner):
	int close = ut_pair_lookup(utd_brackets(), utd_brackets_count(), cp)
	if (close >= 0):
		partner[0] = close
		return 1
	char* table = utd_brackets()
	for i in range(utd_brackets_count()):
		if (ut_u24(table, i * 6 + 3) == cp):
			partner[0] = ut_u24(table, i * 6)
			return 2
	return 0

# Canonical equivalents among brackets (U+2329/U+232A decompose to
# U+3008/U+3009), so either spelling pairs with the other (BD16).
int ut_bracket_canonical(int cp):
	if (cp == 9001): return 12296
	if (cp == 9002): return 12297
	return cp

# Bidi_Mirroring_Glyph of cp, or cp itself.
int ut_mirror(int cp):
	int mirror = ut_pair_lookup(utd_mirrors(), utd_mirrors_count(), cp)
	if (mirror < 0): return cp
	return mirror
