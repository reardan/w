# Unicode Character Database lookups in the style of Python's
# unicodedata module, for Unicode 15.0.0: general category, bidirectional
# class, canonical combining class, mirrored flag, decimal/digit/numeric
# values, simple and full case mappings, case folding, decompositions,
# and NFC/NFD/NFKC/NFKD normalization of UTF-8 text.
#
# The tables live in libs/standard/text/unicodedata_data.w, a build
# output of tools/generate_unicodedata.w (target unicodedata_data, in the
# "generated" umbrella every ./wbuild run builds first; issue #323). They
# are byte-string literals read in place: codepoint lookups allocate
# nothing. Functions returning char* say whether the result is static or
# owned by the caller (free it).
#
# Differences from Python:
#   - Codepoints are ints; text is UTF-8 bytes. Invalid UTF-8 sequences
#     decode as U+FFFD, one byte at a time.
#   - unicode_numeric_str returns the UnicodeData.txt text ("1/2") instead
#     of a float; unicode_numeric_fraction splits it into ints.
#   - unicode_upper/lower apply unconditional full mappings
#     (SpecialCasing.txt) but not the context-sensitive Final_Sigma rule
#     or language-specific mappings, so lower("ΑΣ") is "ασ", not "ας".
#   - No character names (name/lookup) and no east_asian_width.
#   - Codepoints outside 0..0x10FFFF read as unassigned (Cn).
import lib.lib
import libs.standard.text.unicodedata_data


# General categories (unicode_category). unicode_cat_cn is also every
# unassigned codepoint and noncharacter.
const int unicode_cat_cn = 0
const int unicode_cat_lu = 1
const int unicode_cat_ll = 2
const int unicode_cat_lt = 3
const int unicode_cat_lm = 4
const int unicode_cat_lo = 5
const int unicode_cat_mn = 6
const int unicode_cat_mc = 7
const int unicode_cat_me = 8
const int unicode_cat_nd = 9
const int unicode_cat_nl = 10
const int unicode_cat_no = 11
const int unicode_cat_pc = 12
const int unicode_cat_pd = 13
const int unicode_cat_ps = 14
const int unicode_cat_pe = 15
const int unicode_cat_pi = 16
const int unicode_cat_pf = 17
const int unicode_cat_po = 18
const int unicode_cat_sm = 19
const int unicode_cat_sc = 20
const int unicode_cat_sk = 21
const int unicode_cat_so = 22
const int unicode_cat_zs = 23
const int unicode_cat_zl = 24
const int unicode_cat_zp = 25
const int unicode_cat_cc = 26
const int unicode_cat_cf = 27
const int unicode_cat_cs = 28
const int unicode_cat_co = 29

# Bidirectional classes (unicode_bidirectional); 0 is the empty class
# Python reports for unassigned codepoints.
const int unicode_bidi_none = 0
const int unicode_bidi_l = 1
const int unicode_bidi_r = 2
const int unicode_bidi_al = 3
const int unicode_bidi_en = 4
const int unicode_bidi_es = 5
const int unicode_bidi_et = 6
const int unicode_bidi_an = 7
const int unicode_bidi_cs = 8
const int unicode_bidi_nsm = 9
const int unicode_bidi_bn = 10
const int unicode_bidi_b = 11
const int unicode_bidi_s = 12
const int unicode_bidi_ws = 13
const int unicode_bidi_on = 14
const int unicode_bidi_lre = 15
const int unicode_bidi_lro = 16
const int unicode_bidi_rle = 17
const int unicode_bidi_rlo = 18
const int unicode_bidi_pdf = 19
const int unicode_bidi_lri = 20
const int unicode_bidi_rli = 21
const int unicode_bidi_fsi = 22
const int unicode_bidi_pdi = 23

# Normalization forms (unicode_form).
const int unicode_nfc = 0
const int unicode_nfd = 1
const int unicode_nfkc = 2
const int unicode_nfkd = 3

const int ud_max_cp = 1114111
const int ud_bias = 8388608

# Record byte offsets (tools/generate_unicodedata.w gen_record).
const int ud_off_category = 0
const int ud_off_bidi = 1
const int ud_off_combining = 2
const int ud_off_decimal = 3
const int ud_off_digit = 4
const int ud_off_mirrored = 5
const int ud_off_numeric = 6
const int ud_off_upper = 8
const int ud_off_lower = 11
const int ud_off_title = 14
const int ud_off_fold = 17
const int ud_off_flags = 20

const int ud_flag_special = 1
const int ud_flag_full_fold = 2
const int ud_flag_decomp = 4

# Full-mapping kinds in the special table.
const int ud_kind_lower = 0
const int ud_kind_title = 1
const int ud_kind_upper = 2
const int ud_kind_fold = 3

# Hangul syllable algorithm (Unicode 15.0 section 3.12).
const int ud_s_base = 44032
const int ud_l_base = 4352
const int ud_v_base = 4449
const int ud_t_base = 4519
const int ud_l_count = 19
const int ud_v_count = 21
const int ud_t_count = 28
const int ud_n_count = 588
const int ud_s_count = 11172


# The Unicode Character Database version of the tables ("15.0.0").
char* unicode_version():
	return ud_unicode_version()


int ud_u16(char* p, int i):
	return ((p[i] & 255) << 8) | (p[i + 1] & 255)


int ud_u24(char* p, int i):
	return ((p[i] & 255) << 16) | ((p[i + 1] & 255) << 8) | (p[i + 2] & 255)


# The property record of cp (out-of-range codepoints read as U+10FFFF,
# an unassigned noncharacter with every default).
char* ud_record(int cp):
	if ((cp < 0) || (cp > ud_max_cp)): cp = ud_max_cp
	int shift = ud_shift()
	int block = ud_u16(ud_index1(), (cp >> shift) * 2)
	int slot = (block << shift) + (cp & ((1 << shift) - 1))
	int record = ud_u16(ud_index2(), slot * 2)
	return &ud_records()[record * ud_record_size()]


int ud_field(int cp, int offset):
	return ud_record(cp)[offset] & 255


int ud_mapped(int cp, int offset):
	if ((cp < 0) || (cp > ud_max_cp)): return cp
	return cp + ud_u24(ud_record(cp), offset) - ud_bias


# ---- properties ------------------------------------------------------

# General category of cp as a unicode_cat_* constant.
int unicode_category(int cp):
	return ud_field(cp, ud_off_category)


# Two-letter name of a unicode_cat_* constant ("Lu"); static. Out of
# range values name "Cn".
char* unicode_category_name(int category):
	if ((category < 0) || (category > unicode_cat_co)): category = 0
	char* names = c"Cn\x00Lu\x00Ll\x00Lt\x00Lm\x00Lo\x00Mn\x00Mc\x00Me\x00Nd\x00Nl\x00No\x00Pc\x00Pd\x00Ps\x00Pe\x00Pi\x00Pf\x00Po\x00Sm\x00Sc\x00Sk\x00So\x00Zs\x00Zl\x00Zp\x00Cc\x00Cf\x00Cs\x00Co"
	return &names[category * 3]


# unicodedata.category(chr(cp)); static.
char* unicode_category_str(int cp):
	return unicode_category_name(unicode_category(cp))


# Bidirectional class of cp as a unicode_bidi_* constant.
int unicode_bidirectional(int cp):
	return ud_field(cp, ud_off_bidi)


# Name of a unicode_bidi_* constant ("AL"; "" for unicode_bidi_none);
# static.
char* unicode_bidirectional_name(int bidi):
	if ((bidi < 0) || (bidi > unicode_bidi_pdi)): bidi = 0
	char* names = c"\x00\x00\x00\x00L\x00\x00\x00R\x00\x00\x00AL\x00\x00EN\x00\x00ES\x00\x00ET\x00\x00AN\x00\x00CS\x00\x00NSM\x00BN\x00\x00B\x00\x00\x00S\x00\x00\x00WS\x00\x00ON\x00\x00LRE\x00LRO\x00RLE\x00RLO\x00PDF\x00LRI\x00RLI\x00FSI\x00PDI"
	return &names[bidi * 4]


# unicodedata.bidirectional(chr(cp)); static.
char* unicode_bidirectional_str(int cp):
	return unicode_bidirectional_name(unicode_bidirectional(cp))


# Canonical combining class (0 for starters).
int unicode_combining(int cp):
	return ud_field(cp, ud_off_combining)


# 1 when cp is mirrored in bidirectional text.
int unicode_mirrored(int cp):
	return ud_field(cp, ud_off_mirrored)


# Decimal digit value, or -1 when cp has none.
int unicode_decimal(int cp):
	return ud_field(cp, ud_off_decimal) - 1


# Digit value (decimal digits plus superscripts, circled digits, ...),
# or -1 when cp has none.
int unicode_digit(int cp):
	return ud_field(cp, ud_off_digit) - 1


# The numeric value of cp as UnicodeData.txt writes it ("7", "1/4",
# "-1/2", "1000000000000"), or 0 when cp has none; static.
char* unicode_numeric_str(int cp):
	int id = ud_u16(ud_record(cp), ud_off_numeric)
	if (id == 0): return 0
	int offset = ud_u16(ud_numeric_offsets(), (id - 1) * 2)
	return &ud_numeric()[offset]


# The numeric value of cp as a fraction num/den (den is 1 for whole
# numbers). Returns 0 when cp has no numeric value or the value does not
# fit in 31 bits (only a few CJK and Egyptian large numbers).
int unicode_numeric_fraction(int cp, int* num, int* den):
	char* text = unicode_numeric_str(cp)
	if (text == 0): return 0
	int negative = 0
	int i = 0
	if (text[0] == '-'):
		negative = 1
		i = 1
	int top = 0
	while ((text[i] >= '0') && (text[i] <= '9')):
		if (top > 214748363): return 0
		top = top * 10 + text[i] - '0'
		i = i + 1
	int bottom = 1
	if (text[i] == '/'):
		bottom = atoi(&text[i + 1])
	if (negative): top = 0 - top
	*num = top
	*den = bottom
	return 1


# Python str.isalpha for one codepoint: categories Lu Ll Lt Lm Lo.
int unicode_is_alpha(int cp):
	int c = unicode_category(cp)
	return (c >= unicode_cat_lu) && (c <= unicode_cat_lo)


# Python str.isdecimal for one codepoint.
int unicode_is_decimal(int cp):
	return unicode_decimal(cp) >= 0


# Python str.isdigit for one codepoint.
int unicode_is_digit(int cp):
	return unicode_digit(cp) >= 0


# Python str.isnumeric for one codepoint.
int unicode_is_numeric(int cp):
	return unicode_numeric_str(cp) != 0


# Python str.isspace for one codepoint: category Zs or bidi WS, B or S.
int unicode_is_space(int cp):
	if (unicode_category(cp) == unicode_cat_zs): return 1
	int b = unicode_bidirectional(cp)
	return (b == unicode_bidi_ws) || (b == unicode_bidi_b) || (b == unicode_bidi_s)


# ---- simple case mappings ------------------------------------------------

# Simple (single-codepoint) uppercase mapping; cp itself when it has none.
int unicode_to_upper(int cp):
	return ud_mapped(cp, ud_off_upper)


# Simple lowercase mapping.
int unicode_to_lower(int cp):
	return ud_mapped(cp, ud_off_lower)


# Simple titlecase mapping (the uppercase mapping when UnicodeData.txt
# gives none).
int unicode_to_title(int cp):
	return ud_mapped(cp, ud_off_title)


# Simple case folding (CaseFolding.txt statuses C and S).
int unicode_casefold_simple(int cp):
	return ud_mapped(cp, ud_off_fold)


# ---- UTF-8 helpers ---------------------------------------------------------

# Decodes data[0..length) into cps; malformed bytes become U+FFFD.
void ud_decode(char* data, int length, list[int] cps):
	int i = 0
	while (i < length):
		int cp = 0
		int n = utf8_scan(&data[i], length - i, &cp)
		if (n == 0):
			cp = 65533
			n = 1
		cps.push(cp)
		i = i + n


# Encodes cps as a malloc'd NUL-terminated UTF-8 buffer; stores the byte
# length (excluding the NUL) in out_length when it is not 0.
char* ud_encode(list[int] cps, int* out_length):
	char* out = cast(char*, malloc(cps.length * 4 + 1))
	int n = 0
	for cp in cps:
		if (cp < 128):
			out[n] = cp
			n = n + 1
		else if (cp < 2048):
			out[n] = 192 | (cp >> 6)
			out[n + 1] = 128 | (cp & 63)
			n = n + 2
		else if (cp < 65536):
			out[n] = 224 | (cp >> 12)
			out[n + 1] = 128 | ((cp >> 6) & 63)
			out[n + 2] = 128 | (cp & 63)
			n = n + 3
		else:
			out[n] = 240 | (cp >> 18)
			out[n + 1] = 128 | ((cp >> 12) & 63)
			out[n + 2] = 128 | ((cp >> 6) & 63)
			out[n + 3] = 128 | (cp & 63)
			n = n + 4
	out[n] = 0
	if (out_length != 0): *out_length = n
	return out


# ---- full case mappings ----------------------------------------------------

# Index of the (cp, kind) entry in the special table, or -1.
int ud_special_find(int cp, int kind):
	char* table = ud_special()
	int lo = 0
	int hi = ud_special_count() - 1
	while (lo <= hi):
		int mid = (lo + hi) / 2
		int at = ud_u24(table, mid * 14)
		int at_kind = table[mid * 14 + 3] & 255
		if ((at == cp) && (at_kind == kind)): return mid
		if ((at < cp) || ((at == cp) && (at_kind < kind))): lo = mid + 1
		else: hi = mid - 1
	return -1


# Appends the full mapping of one codepoint of the given kind.
void ud_full_map(int cp, int kind, list[int] out):
	char* record = ud_record(cp)
	int flags = record[ud_off_flags] & 255
	if (flags & ud_flag_special):
		int entry = ud_special_find(cp, kind)
		if (entry >= 0):
			char* table = ud_special()
			int count = table[entry * 14 + 4] & 255
			for k in range(count): out.push(ud_u24(table, entry * 14 + 5 + k * 3))
			return
	int offset = ud_off_lower
	if (kind == ud_kind_title): offset = ud_off_title
	else if (kind == ud_kind_upper): offset = ud_off_upper
	else if (kind == ud_kind_fold): offset = ud_off_fold
	out.push(cp + ud_u24(record, offset) - ud_bias)


char* ud_map_text(char* text, int kind):
	list[int] cps = new list[int]
	list[int] out = new list[int]
	ud_decode(text, strlen(text), cps)
	for cp in cps: ud_full_map(cp, kind, out)
	char* result = ud_encode(out, 0)
	cps.free()
	out.free()
	return result


# Python str.upper of UTF-8 text with full mappings ("ß" -> "SS");
# caller frees.
char* unicode_upper(char* text):
	return ud_map_text(text, ud_kind_upper)


# Python str.lower of UTF-8 text (without Final_Sigma); caller frees.
char* unicode_lower(char* text):
	return ud_map_text(text, ud_kind_lower)


# Python str.casefold of UTF-8 text (full folding, C+F); caller frees.
char* unicode_casefold(char* text):
	return ud_map_text(text, ud_kind_fold)


# ---- decomposition ---------------------------------------------------------

# Index of cp's entry in the decomposition table, or -1.
int ud_decomp_find(int cp):
	if ((ud_field(cp, ud_off_flags) & ud_flag_decomp) == 0): return -1
	char* table = ud_decomp()
	int lo = 0
	int hi = ud_decomp_count() - 1
	while (lo <= hi):
		int mid = (lo + hi) / 2
		int at = ud_u24(table, mid * 7)
		if (at == cp): return mid
		if (at < cp): lo = mid + 1
		else: hi = mid - 1
	return -1


char* ud_tag_name(int tag):
	char* names = c"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00<font>\x00\x00\x00\x00\x00<noBreak>\x00\x00<initial>\x00\x00<medial>\x00\x00\x00<final>\x00\x00\x00\x00<isolated>\x00<circle>\x00\x00\x00<super>\x00\x00\x00\x00<sub>\x00\x00\x00\x00\x00\x00<vertical>\x00<wide>\x00\x00\x00\x00\x00<narrow>\x00\x00\x00<small>\x00\x00\x00\x00<square>\x00\x00\x00<fraction>\x00<compat>"
	return &names[tag * 11]


void ud_append_hex(list[int] out, int value):
	int digits = 4
	if (value > 65535): digits = 5
	if (value > 1048575): digits = 6
	for k in range(digits):
		int d = (value >> ((digits - 1 - k) * 4)) & 15
		if (d < 10): out.push('0' + d)
		else: out.push('A' + d - 10)


# Appends the full canonical (compat == 0) or compatibility decomposition
# of cp, unordered.
void ud_decompose(int cp, int compat, list[int] out):
	int s = cp - ud_s_base
	if ((s >= 0) && (s < ud_s_count)):
		out.push(ud_l_base + s / ud_n_count)
		out.push(ud_v_base + (s % ud_n_count) / ud_t_count)
		int t = s % ud_t_count
		if (t != 0): out.push(ud_t_base + t)
		return
	int entry = ud_decomp_find(cp)
	if (entry >= 0):
		char* table = ud_decomp()
		int tag = table[entry * 7 + 3] & 255
		if ((tag == 0) || compat):
			int count = table[entry * 7 + 4] & 255
			int offset = ud_u16(table, entry * 7 + 5)
			for k in range(count): ud_decompose(ud_u24(ud_decomp_cps(), (offset + k) * 3), compat, out)
			return
	out.push(cp)


# unicodedata.decomposition(chr(cp)): "<compat> 0020 0308", "0041 030A",
# or "" when cp has none. Hangul syllables give their algorithmic
# jamo ("1100 1161 11A8"), as in Python. Caller frees.
char* unicode_decomposition(int cp):
	list[int] text = new list[int]
	int entry = ud_decomp_find(cp)
	int s = cp - ud_s_base
	if ((s >= 0) && (s < ud_s_count)):
		list[int] jamo = new list[int]
		ud_decompose(cp, 0, jamo)
		for j in jamo:
			if (text.length > 0): text.push(' ')
			ud_append_hex(text, j)
		jamo.free()
	else if (entry >= 0):
		char* table = ud_decomp()
		int tag = table[entry * 7 + 3] & 255
		int count = table[entry * 7 + 4] & 255
		int offset = ud_u16(table, entry * 7 + 5)
		if (tag != 0):
			char* name = ud_tag_name(tag)
			int i = 0
			while (name[i] != 0):
				text.push(name[i])
				i = i + 1
		for k in range(count):
			if (text.length > 0): text.push(' ')
			ud_append_hex(text, ud_u24(ud_decomp_cps(), (offset + k) * 3))
	char* result = ud_encode(text, 0)
	text.free()
	return result


# Canonical Ordering Algorithm: a stable sort of each run of nonstarters
# by combining class.
void ud_reorder(list[int] cps):
	for i in range(1, cps.length):
		int cp = cps[i]
		int cls = unicode_combining(cp)
		if (cls == 0): continue
		int j = i
		while ((j > 0) && (unicode_combining(cps[j - 1]) > cls)):
			cps[j] = cps[j - 1]
			j = j - 1
		cps[j] = cp


# The primary composite of first + second, or -1.
int ud_compose_pair(int first, int second):
	int l = first - ud_l_base
	if ((l >= 0) && (l < ud_l_count)):
		int v = second - ud_v_base
		if ((v >= 0) && (v < ud_v_count)): return ud_s_base + (l * ud_v_count + v) * ud_t_count
		return -1
	int s = first - ud_s_base
	if ((s >= 0) && (s < ud_s_count) && ((s % ud_t_count) == 0)):
		int t = second - ud_t_base
		if ((t > 0) && (t < ud_t_count)): return first + t
		return -1
	char* table = ud_compose()
	int lo = 0
	int hi = ud_compose_count() - 1
	while (lo <= hi):
		int mid = (lo + hi) / 2
		int a = ud_u24(table, mid * 9)
		int b = ud_u24(table, mid * 9 + 3)
		if ((a == first) && (b == second)): return ud_u24(table, mid * 9 + 6)
		if ((a < first) || ((a == first) && (b < second))): lo = mid + 1
		else: hi = mid - 1
	return -1


# Canonical Composition Algorithm over a canonically ordered sequence,
# in place.
void ud_compose_all(list[int] cps):
	if (cps.length == 0): return
	int starter_pos = 0
	int starter = cps[0]
	int last_class = unicode_combining(starter)
	if (last_class != 0): last_class = 256
	int n = 1
	for i in range(1, cps.length):
		int cp = cps[i]
		int cls = unicode_combining(cp)
		int composite = ud_compose_pair(starter, cp)
		if ((composite >= 0) && ((last_class < cls) || (last_class == 0))):
			cps[starter_pos] = composite
			starter = composite
			continue
		if (cls == 0):
			starter_pos = n
			starter = cp
		last_class = cls
		cps[n] = cp
		n = n + 1
	while (cps.length > n): cps.pop()


# A normalization form constant for "NFC", "NFD", "NFKC" or "NFKD", or -1.
int unicode_form(char* name):
	if (strcmp(name, c"NFC") == 0): return unicode_nfc
	if (strcmp(name, c"NFD") == 0): return unicode_nfd
	if (strcmp(name, c"NFKC") == 0): return unicode_nfkc
	if (strcmp(name, c"NFKD") == 0): return unicode_nfkd
	return -1


# Normalizes length bytes of UTF-8 to form (a unicode_* form constant).
# Returns a malloc'd NUL-terminated buffer and stores its byte length in
# out_length (when not 0); 0 for an unknown form. Embedded NULs survive.
char* unicode_normalize_bytes(int form, char* data, int length, int* out_length):
	if ((form < unicode_nfc) || (form > unicode_nfkd)): return 0
	int compat = (form == unicode_nfkc) || (form == unicode_nfkd)
	list[int] input = new list[int]
	list[int] cps = new list[int]
	ud_decode(data, length, input)
	for cp in input: ud_decompose(cp, compat, cps)
	ud_reorder(cps)
	if ((form == unicode_nfc) || (form == unicode_nfkc)): ud_compose_all(cps)
	char* result = ud_encode(cps, out_length)
	input.free()
	cps.free()
	return result


# unicodedata.normalize(form, text) for NUL-terminated UTF-8 text. Returns
# a malloc'd string, or 0 when form is not NFC/NFD/NFKC/NFKD.
char* unicode_normalize(char* form, char* text):
	return unicode_normalize_bytes(unicode_form(form), text, strlen(text), 0)


# unicodedata.is_normalized(form, text): 1 or 0, or -1 for an unknown form.
int unicode_is_normalized(char* form, char* text):
	int length = strlen(text)
	int out_length = 0
	char* normalized = unicode_normalize_bytes(unicode_form(form), text, length, &out_length)
	if (normalized == 0): return -1
	int same = out_length == length
	int i = 0
	while (same && (i < length)):
		if (normalized[i] != text[i]): same = 0
		i = i + 1
	free(normalized)
	return same
