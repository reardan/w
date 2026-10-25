/*
lib.ttf_shape: portable text shaping for lib.ttf fonts (issue #459), the
counterpart of HarfBuzz for runs of one script, direction and font.

	otl_buffer* b = ttf_shape(font, cps, clusters, count, rtl, script, language, flags)

maps codepoints to glyphs (mirrored forms in RTL runs), reorders
combining marks canonically, applies the OpenType features of the script
(ccmp/locl; Arabic-style isol/fina/medi/init from Unicode joining types;
rlig/rclt/calt/liga/clig; kern/mark/mkmk/curs/dist/abvm/blwm), and
returns positioned glyphs in visual order (reversed for RTL) with font-
unit advances and offsets and source clusters.

Fonts without the tables still shape usefully: Arabic falls back to the
Unicode presentation forms (including lam-alef ligatures) when the font
maps them, pair kerning falls back to the legacy kern table, and marks
with no GPOS attachment are centred over (or under) their base using
glyph boxes, stacking outward. Default-ignorable characters (ZWJ, ZWNJ,
variation selectors, bidi controls) shape with no ink and no advance.

Devanagari, Bengali, Gurmukhi, Gujarati, Oriya, Tamil, Telugu, Kannada
and Malayalam runs go through lib.ttf_indic, a port of HarfBuzz's Indic
shaper (syllables, reph, pre-base matras and consonants, the basic and
presentation feature stages). Other complex scripts (Southeast Asian,
USE) apply the generic features, which suits Thai and Hebrew fonts but
not their reordering.
*/
import lib.lib
import lib.ttf
import lib.ttf_indic
import lib.ttf_layout
import lib.unicode_text

const int ttf_shape_no_liga = 1     # flags: disable liga/clig
const int ttf_shape_no_kern = 2     # flags: disable kern

# Feature masks. Global features use bit 0; Arabic positional forms take
# their own bits (lib.ttf_indic's per-syllable masks start at bit 5).
const int ttf_mask_global = 1
const int ttf_mask_isol = 2
const int ttf_mask_fina = 4
const int ttf_mask_medi = 8
const int ttf_mask_init = 16

# OpenType script tags for a Unicode script id, most preferred first, as
# 4-byte groups, always ending in the DFLT/dflt/latn fallbacks. Writes up
# to 7 tags into out (28 bytes + terminator); returns the tag count.
int ttf_script_tags(int script, char* out):
	char* code = ut_script_code(script)
	int n = 0
	char[5] tag
	tag[4] = 0
	for k in range(4):
		int ch = code[k]
		if ((ch >= 'A') && (ch <= 'Z')): ch = ch + 32
		tag[k] = ch
	char* special = 0
	if (strcmp(&tag[0], c"deva") == 0): special = c"dev2"
	if (strcmp(&tag[0], c"beng") == 0): special = c"bng2"
	if (strcmp(&tag[0], c"guru") == 0): special = c"gur2"
	if (strcmp(&tag[0], c"gujr") == 0): special = c"gjr2"
	if (strcmp(&tag[0], c"orya") == 0): special = c"ory2"
	if (strcmp(&tag[0], c"taml") == 0): special = c"tml2"
	if (strcmp(&tag[0], c"telu") == 0): special = c"tel2"
	if (strcmp(&tag[0], c"knda") == 0): special = c"knd2"
	if (strcmp(&tag[0], c"mlym") == 0): special = c"mlm2"
	if (strcmp(&tag[0], c"mymr") == 0): special = c"mym2"
	if ((strcmp(&tag[0], c"hira") == 0) || (strcmp(&tag[0], c"kana") == 0)): special = c"kana"
	if (strcmp(&tag[0], c"laoo") == 0): special = c"lao "
	if (strcmp(&tag[0], c"yiii") == 0): special = c"yi  "
	if (strcmp(&tag[0], c"nkoo") == 0): special = c"nko "
	if (strcmp(&tag[0], c"vaii") == 0): special = c"vai "
	if (special != 0):
		for k in range(4): out[n * 4 + k] = special[k]
		n = n + 1
	if (!ut_script_is_shared(script) && ((special == 0) || (strcmp(&tag[0], c"hira") != 0))):
		if ((special == 0) || (strcmp(special, &tag[0]) != 0)):
			for k in range(4): out[n * 4 + k] = tag[k]
			n = n + 1
	char* fallback = c"DFLTdfltlatn"
	for k in range(12): out[n * 4 + k] = fallback[k]
	n = n + 3
	out[n * 4] = 0
	return n

# The first script that is not Common/Inherited in cps, else Common.
int ttf_guess_script(int32* cps, int count):
	for i in range(count):
		int script = ut_script(cps[i])
		if (!ut_script_is_shared(script)): return script
	if (count > 0): return ut_script(cps[0])
	return 0

int ttf_code_is(char* code, char* want):
	return (code[0] == want[0]) && (code[1] == want[1]) && (code[2] == want[2]) && (code[3] == want[3])

# Scripts written right to left.
int ttf_script_is_rtl(int script):
	char* code = ut_script_code(script)
	char* rtl = c"ArabHebrSyrcThaaNkooSamrMandMendAdlmRohgYeziArmiAvstCprtKhar"
	int n = strlen(rtl) / 4
	for k in range(n):
		if (ttf_code_is(code, &rtl[k * 4])): return 1
	return 0

int ttf_is_joining_script(char* code):
	return ttf_code_is(code, c"Arab") || ttf_code_is(code, c"Syrc") || ttf_code_is(code, c"Nkoo") || ttf_code_is(code, c"Mong") || ttf_code_is(code, c"Mand") || ttf_code_is(code, c"Mani") || ttf_code_is(code, c"Phag") || ttf_code_is(code, c"Adlm") || ttf_code_is(code, c"Rohg") || ttf_code_is(code, c"Sogd")

# Combining class for mark reordering. Like HarfBuzz, Hebrew and Arabic
# points are renumbered so the marks nearest the letter (dagesh, shin and
# sin dots; shadda) sort first, which is the order fonts expect. The
# Telugu length marks (84, 91) sort before the virama (9).
int ttf_modified_ccc(int cp):
	int ccc = ut_combining_class(cp)
	if ((ccc >= 10) && (ccc <= 26)):
		char* hebrew = c"\x16\x0f\x10\x11\x17\x12\x13\x14\x15\x0e\x18\x0c\x19\x0d\x0a\x0b\x1a"
		return hebrew[ccc - 10]
	if ((ccc >= 27) && (ccc <= 32)): return ccc + 1
	if (ccc == 33): return 27
	if (ccc == 84): return 4
	if (ccc == 91): return 5
	return ccc

# Canonical reordering of combining marks (UAX #15 / HarfBuzz's mark
# normalization): stable-sort each run of nonzero combining classes.
void ttf_reorder_marks(otl_buffer* b):
	int i = 0
	while (i < b.count):
		if ((b.glyphs[i].cp < 0) || (ttf_modified_ccc(b.glyphs[i].cp) == 0)):
			i = i + 1
			continue
		int end = i
		while ((end < b.count) && (b.glyphs[end].cp >= 0) && (ttf_modified_ccc(b.glyphs[end].cp) != 0)): end = end + 1
		otl_glyph tmp
		for k in range(i + 1, end):
			int j = k
			while ((j > i) && (ttf_modified_ccc(b.glyphs[j - 1].cp) > ttf_modified_ccc(b.glyphs[j].cp))):
				otl_glyph_copy(&tmp, &b.glyphs[j - 1])
				otl_glyph_copy(&b.glyphs[j - 1], &b.glyphs[j])
				otl_glyph_copy(&b.glyphs[j], &tmp)
				j = j - 1
		i = end

# Arabic-style joining (ArabicShaping.txt): the positional form of each
# character as ut_form_*, written to forms.
void ttf_joining_forms(otl_buffer* b, int32* forms):
	int previous = -1
	int previous_type = ut_join_u
	for i in range(b.count):
		forms[i] = ut_form_none
		int type = ut_join_u
		if (b.glyphs[i].cp >= 0): type = ut_joining_type(b.glyphs[i].cp)
		if (type == ut_join_t): continue
		# Join-causing characters (ZWJ, tatweel) join like dual-joining
		# letters and take forms too, as in HarfBuzz.
		if (type == ut_join_c): type = ut_join_d
		int joins_previous = ((type == ut_join_r) || (type == ut_join_d)) && ((previous_type == ut_join_l) || (previous_type == ut_join_d))
		if ((type == ut_join_r) || (type == ut_join_d) || (type == ut_join_l)): forms[i] = ut_form_isol
		if (joins_previous):
			# The previous character gains a following join.
			if (previous >= 0):
				if (forms[previous] == ut_form_isol): forms[previous] = ut_form_init
				else if (forms[previous] == ut_form_fina): forms[previous] = ut_form_medi
			if ((type == ut_join_r) || (type == ut_join_d)): forms[i] = ut_form_fina
		previous = i
		previous_type = type

int ttf_form_mask(int form):
	if (form == ut_form_isol): return ttf_mask_isol
	if (form == ut_form_fina): return ttf_mask_fina
	if (form == ut_form_medi): return ttf_mask_medi
	if (form == ut_form_init): return ttf_mask_init
	return 0

# Presentation-form fallback for fonts without positional GSUB features.
void ttf_arabic_fallback(ttf_font* f, otl_buffer* b, int32* forms):
	int i = 0
	while (i < b.count):
		otl_glyph* g = &b.glyphs[i]
		if ((g.cp == 0x0644) && ((forms[i] == ut_form_init) || (forms[i] == ut_form_medi))):
			int j = i + 1
			while ((j < b.count) && (b.glyphs[j].cp >= 0) && (ut_joining_type(b.glyphs[j].cp) == ut_join_t)): j = j + 1
			if (j < b.count):
				int form = ut_form_isol
				if (forms[i] == ut_form_medi): form = ut_form_fina
				int lig = ut_lam_alef(b.glyphs[j].cp, form)
				int gid = 0
				# HarfBuzz forms the ligature from the components' own
				# presentation forms, so the font must have those too.
				int lam_form = ut_arabic_form(0x0644, forms[i])
				int alef_form = ut_arabic_form(b.glyphs[j].cp, ut_form_fina)
				int parts = (lam_form >= 0) && (alef_form >= 0) && (ttf_glyph_id(f, lam_form) != 0) && (ttf_glyph_id(f, alef_form) != 0)
				if ((lig >= 0) && parts): gid = ttf_glyph_id(f, lig)
				if (gid != 0):
					g.gid = gid
					for k in range(i + 1, j + 1): b.glyphs[k].cluster = g.cluster
					otl_buffer_delete(b, j)
					for k in range(j, b.count): forms[k] = forms[k + 1]
					i = i + 1
					continue
		# SHADDA with a following vowel mark: the U+FC5E..U+FC63 mark
		# ligatures, as HarfBuzz's fallback does.
		if ((g.cp == 0x0651) && (i + 1 < b.count)):
			int vowel = b.glyphs[i + 1].cp
			int lig = -1
			if ((vowel >= 0x064c) && (vowel <= 0x0650)): lig = 0xfc5e + (vowel - 0x064c)
			if (vowel == 0x0670): lig = 0xfc63
			int gid = 0
			if (lig >= 0): gid = ttf_glyph_id(f, lig)
			if (gid != 0):
				g.gid = gid
				otl_buffer_delete(b, i + 1)
				for k in range(i + 1, b.count): forms[k] = forms[k + 1]
				i = i + 1
				continue
		if (forms[i] != ut_form_none):
			int presentation = ut_arabic_form(g.cp, forms[i])
			if (presentation >= 0):
				int gid = ttf_glyph_id(f, presentation)
				if (gid != 0): g.gid = gid
		i = i + 1

void ttf_stage1(int* tags, int* masks, int tag, int mask, int* n):
	tags[n[0]] = tag
	masks[n[0]] = mask
	n[0] = n[0] + 1

# Where fallback placement puts a mark: its combining class, with
# HarfBuzz's mapping of the script-specific Hebrew, Arabic, Thai, Lao and
# Tibetan classes onto the positional ones (200-234). Classes outside
# that range are only centred horizontally.
int ttf_mark_placement(int cp):
	int ccc = ut_combining_class(cp)
	if ((ccc == 19) || (ccc == 25)): return 228
	if (ccc == 24): return 232
	if (ccc == 23): return 214
	if (ccc == 26): return 230
	if ((ccc >= 10) && (ccc <= 22) && (ccc != 21)): return 220
	if ((ccc == 29) || (ccc == 32)): return 220
	if ((ccc >= 27) && (ccc <= 36)): return 230
	if (ccc == 103): return 222
	if (ccc == 107): return 232
	if ((ccc == 118) || (ccc == 129) || (ccc == 132)): return 220
	if ((ccc == 122) || (ccc == 130)): return 230
	return ccc

# Place nonspacing marks around their base from glyph boxes, following
# HarfBuzz's fallback mark positioning: horizontally against the base's
# advance (left, right or centred), vertically stacked outward from the
# base's ink with a gap of upem/16 for unattached classes. Below marks are
# never shifted up, and above marks are shifted down at most half way.
# Marks get no advance.
void ttf_fallback_marks(ttf_font* f, otl_buffer* b, int rtl):
	int[4] base_box
	int[4] mark_box
	int gap = f.upem / 16
	int base = -1
	int top = 0
	int bottom = 0
	int last_cls = -1
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		if (!g.unicode_mark):
			base = i
			ttf_glyph_bbox(f, g.gid, &base_box[0])
			last_cls = -1
			continue
		# Only marks with a combining class are placed (and lose their
		# advance); class 0 marks keep their own metrics.
		if ((base < 0) || (ut_combining_class(g.cp) == 0)): continue
		g.x_advance = 0
		if (g.attach_kind != 0): continue
		ttf_glyph_bbox(f, g.gid, &mark_box[0])
		int cls = ttf_mark_placement(g.cp)
		# Marks of one class stack outward; a new class starts again from
		# the base.
		if (cls != last_cls):
			last_cls = cls
			top = base_box[3]
			bottom = base_box[1]
		# Horizontally the base spans its advance, not its ink (HarfBuzz
		# does this so zero-ink bases still place marks sensibly).
		int base_width = ttf_advance_units(f, b.glyphs[base].gid)
		int mark_width = mark_box[2] - mark_box[0]
		int dx = (base_width - mark_width) / 2 - mark_box[0]
		if ((cls == 200) || (cls == 218) || (cls == 228)): dx = 0 - mark_box[0]
		if ((cls == 216) || (cls == 222) || (cls == 232)): dx = base_width - mark_width - mark_box[0]
		# Double-width marks (U+035C..U+0362) straddle the next base.
		if ((cls == 233) || (cls == 234)):
			dx = base_width - mark_width / 2 - mark_box[0]
			if (rtl): dx = 0 - mark_width / 2 - mark_box[0]
		int dy = 0
		int below = (cls == 200) || (cls == 202) || (cls == 218) || (cls == 220) || (cls == 222) || (cls == 233)
		int above = (cls == 214) || (cls == 216) || (cls == 228) || (cls == 230) || (cls == 232) || (cls == 234)
		if (below):
			if ((cls != 200) && (cls != 202)): bottom = bottom - gap
			dy = bottom - mark_box[3]
			if (dy > 0):
				bottom = bottom - dy
				dy = 0
			bottom = bottom - (mark_box[3] - mark_box[1])
		else if (above):
			if ((cls != 214) && (cls != 216)): top = top + gap
			dy = top - mark_box[1]
			if (dy < 0):
				int correction = (0 - dy) / 2
				top = top + correction
				dy = dy + correction
			top = top + (mark_box[3] - mark_box[1])
		g.attach = base
		g.attach_kind = otl_attach_mark
		g.attach_dx = dx
		g.attach_dy = dy

# Legacy pair kerning between consecutive non-mark glyphs. Like
# HarfBuzz, the adjustment is split: half (rounded down) widens the first
# glyph and the rest moves and widens the second.
void ttf_fallback_kern(ttf_font* f, otl_buffer* b, int rtl):
	int previous = -1
	for i in range(b.count):
		if (b.glyphs[i].props == otl_class_mark): continue
		# Default ignorables (ZWJ, ZWNJ, variation selectors) never
		# separate a kerning pair.
		if ((b.glyphs[i].cp >= 0) && ut_default_ignorable(b.glyphs[i].cp)): continue
		if (previous >= 0):
			# Pairs kern in visual order: in RTL the later glyph is on the left.
			int left = previous
			int right = i
			if (rtl):
				left = i
				right = previous
			int kern = ttf_kern_table_units(f, b.glyphs[left].gid, b.glyphs[right].gid)
			int first = kern >> 1
			b.glyphs[left].x_advance = b.glyphs[left].x_advance + first
			b.glyphs[right].x_advance = b.glyphs[right].x_advance + kern - first
			b.glyphs[right].x_offset = b.glyphs[right].x_offset + kern - first
		previous = i

# Canonical decomposition of cp for a font that lacks its glyph: appends
# the fully decomposed codepoints to out and returns their count, or 0
# when the font cannot draw the decomposition either.
int ttf_decompose_for(ttf_font* f, int cp, int32* out, int depth):
	int a = 0
	int b = 0
	if ((depth > 4) || !ut_decompose(cp, &a, &b)): return 0
	int n = 0
	if (ttf_glyph_id(f, a) != 0):
		out[0] = a
		n = 1
	else:
		n = ttf_decompose_for(f, a, out, depth + 1)
		if (n == 0): return 0
	if (b == 0): return n
	if (ttf_glyph_id(f, b) != 0):
		out[n] = b
		return n + 1
	int m = ttf_decompose_for(f, b, &out[n], depth + 1)
	if (m == 0): return 0
	return n + m

# Compose each starter with following unblocked marks when the font has
# the composed glyph (HarfBuzz's composed-diacritics normalization).
# Dagesh forms of U+05D0..U+05EA (0: none), for ttf_hebrew_compose.
int ttf_hebrew_dagesh(int letter):
	char* forms = c"\x30\x31\x32\x33\x34\x35\x36\x00\x38\x39\x3a\x3b\x3c\x00\x3e\x00\x40\x41\x00\x43\x44\x00\x46\x47\x48\x49\x4a"
	int low = forms[letter - 0x05d0] & 255
	if (low == 0): return 0
	return 0xfb00 + low

# HarfBuzz's Hebrew presentation-form compositions, which normalization
# excludes but old fonts without GPOS mark positioning want. Returns the
# composed codepoint, or -1.
int ttf_hebrew_compose(int a, int mark):
	if (mark == 0x05b4):
		if (a == 0x05d9): return 0xfb1d
	if (mark == 0x05b7):
		if (a == 0x05f2): return 0xfb1f
		if (a == 0x05d0): return 0xfb2e
	if ((mark == 0x05b8) && (a == 0x05d0)): return 0xfb2f
	if ((mark == 0x05b9) && (a == 0x05d5)): return 0xfb4b
	if (mark == 0x05bc):
		if ((a >= 0x05d0) && (a <= 0x05ea)):
			int form = ttf_hebrew_dagesh(a)
			if (form != 0): return form
			return -1
		if (a == 0xfb2a): return 0xfb2c
		if (a == 0xfb2b): return 0xfb2d
	if (mark == 0x05bf):
		if (a == 0x05d1): return 0xfb4c
		if (a == 0x05db): return 0xfb4d
		if (a == 0x05e4): return 0xfb4e
	if (mark == 0x05c1):
		if (a == 0x05e9): return 0xfb2a
		if (a == 0xfb49): return 0xfb2c
	if (mark == 0x05c2):
		if (a == 0x05e9): return 0xfb2b
		if (a == 0xfb49): return 0xfb2d
	return -1

# Recompose marks into the preceding starter where the font has the
# composed character (HarfBuzz's default normalization). hebrew_forms
# adds ttf_hebrew_compose.
void ttf_recompose(ttf_font* f, otl_buffer* b, int hebrew_forms):
	int starter = -1
	int last_ccc = 0
	int i = 0
	while (i < b.count):
		otl_glyph* g = &b.glyphs[i]
		int ccc = 0
		if (g.cp >= 0): ccc = ut_combining_class(g.cp)
		# Hangul V and T jamo compose with the syllable before them.
		int jamo = (g.cp >= 0x1161) && (g.cp <= 0x11c2) && (starter >= 0) && (i == starter + 1)
		if ((starter >= 0) && ((ccc != 0) || jamo) && (g.cp >= 0) && ((i == starter + 1) || (last_ccc < ccc))):
			otl_glyph* s = &b.glyphs[starter]
			int composed = ut_compose(s.cp, g.cp)
			if ((composed < 0) && hebrew_forms): composed = ttf_hebrew_compose(s.cp, g.cp)
			int gid = 0
			if (composed >= 0): gid = ttf_glyph_id(f, composed)
			if (gid != 0):
				s.cp = composed
				s.gid = gid
				s.unicode_mark = ut_is_nonspacing_mark(composed)
				otl_buffer_delete(b, i)
				continue
		if (ccc == 0):
			starter = -1
			if (g.cp >= 0): starter = i
			last_ccc = 0
		else: last_ccc = ccc
		i = i + 1

# HarfBuzz's Indic decomposition (no short circuit): cp fully decomposed
# whenever the font has the parts, even when it has cp itself, except
# U+0931, U+09DC, U+09DD and U+0B94. Appends to out; returns the count,
# or 0 when cp stays whole.
int ttf_indic_decompose(ttf_font* f, int cp, int32* out, int depth):
	if ((cp == 0x0931) || (cp == 0x09dc) || (cp == 0x09dd) || (cp == 0x0b94)): return 0
	int a = 0
	int b = 0
	if ((depth > 4) || !ut_decompose(cp, &a, &b)): return 0
	if ((b != 0) && (ttf_glyph_id(f, b) == 0)): return 0
	int n = ttf_indic_decompose(f, a, out, depth + 1)
	if ((n == 0) && (ttf_glyph_id(f, a) != 0)):
		out[0] = a
		n = 1
	if (n == 0): return 0
	if (b != 0):
		out[n] = b
		n = n + 1
	return n

# HarfBuzz's recomposition for the Indic shaper: a mark (Mn, Mc, Me)
# composes into the last starter when nothing between them has an equal
# or higher combining class, the starter is not itself a mark (split
# matras stay split) and the font has the composite. U+09AF U+09BC
# composes to U+09DF despite the composition exclusion.
void ttf_indic_recompose(ttf_font* f, otl_buffer* b):
	if (b.count == 0): return
	int starter = 0
	int i = 1
	while (i < b.count):
		otl_glyph* g = &b.glyphs[i]
		int category = -1
		if (g.cp >= 0): category = ut_category(g.cp)
		int mark = (category == ut_cat_mn) || (category == ut_cat_mc) || (category == ut_cat_me)
		otl_glyph* s = &b.glyphs[starter]
		if (mark && (s.cp >= 0) && ((starter == i - 1) || (ttf_modified_ccc(b.glyphs[i - 1].cp) < ttf_modified_ccc(g.cp)))):
			int composed = -1
			int sc = ut_category(s.cp)
			if ((sc != ut_cat_mn) && (sc != ut_cat_mc) && (sc != ut_cat_me)):
				if ((s.cp == 0x09af) && (g.cp == 0x09bc)): composed = 0x09df
				else: composed = ut_compose(s.cp, g.cp)
			int gid = 0
			if (composed >= 0): gid = ttf_glyph_id(f, composed)
			if (gid != 0):
				if (g.cluster < s.cluster): s.cluster = g.cluster
				s.cp = composed
				s.gid = gid
				s.unicode_mark = ut_is_nonspacing_mark(composed)
				otl_buffer_delete(b, i)
				continue
		if ((g.cp < 0) || (ttf_modified_ccc(g.cp) == 0)): starter = i
		i = i + 1

int ttf_continues_cluster(int cp):
	int category = ut_category(cp)
	if ((category == ut_cat_mn) || (category == ut_cat_mc) || (category == ut_cat_me)): return 1
	return (cp == 0x200d) || ((cp >= 0x1160) && (cp <= 0x11ff)) || ((cp >= 0xfe00) && (cp <= 0xfe0f)) || ((cp >= 0xe0100) && (cp <= 0xe01ef)) || ((cp >= 0x1f3fb) && (cp <= 0x1f3ff))

# HarfBuzz's fallback for a space character the font lacks: its width
# as a fraction of the em (N for upem/N), or a special width (-1 the
# space glyph's, -2 a digit's, -3 a period's, -4 half the space's, -5
# 4/18 em); 0 when cp is no such space.
int ttf_space_fallback(int cp):
	if ((cp == 0x20) || (cp == 0xa0)): return -1
	if ((cp == 0x2000) || (cp == 0x2002)): return 2
	if ((cp == 0x2001) || (cp == 0x2003) || (cp == 0x3000)): return 1
	if (cp == 0x2004): return 3
	if (cp == 0x2005): return 4
	if (cp == 0x2006): return 6
	if (cp == 0x2007): return -2
	if (cp == 0x2008): return -3
	if (cp == 0x2009): return 5
	if (cp == 0x200a): return 16
	if (cp == 0x202f): return -4
	if (cp == 0x205f): return -5
	return 0

# The advance of a fallback space glyph (see ttf_space_fallback).
int ttf_space_fallback_advance(ttf_font* f, int kind, int advance):
	if (kind > 0): return (f.upem + kind / 2) / kind
	if (kind == -2):
		for d in range(10):
			int digit = ttf_glyph_id(f, '0' + d)
			if (digit != 0): return ttf_advance_units(f, digit)
	if (kind == -3):
		int dot = ttf_glyph_id(f, '.')
		if (dot == 0): dot = ttf_glyph_id(f, ',')
		if (dot != 0): return ttf_advance_units(f, dot)
	if (kind == -4): return advance / 2
	if (kind == -5): return f.upem * 4 / 18
	return advance

void ttf_shape_add(ttf_font* f, otl_buffer* b, int cp, int source, int rtl):
	int gid = ttf_glyph_id(f, cp)
	if ((gid == 0) && (ttf_space_fallback(cp) != 0)): gid = ttf_glyph_id(f, ' ')
	if (rtl):
		int mirror = ut_mirror(cp)
		if (mirror != cp):
			int mirrored = ttf_glyph_id(f, mirror)
			if (mirrored != 0): gid = mirrored
	# Marks and joiners continue the cluster of the character before
	# them (HarfBuzz's default grapheme cluster level).
	int cluster = source
	if ((b.count > 0) && ttf_continues_cluster(cp)): cluster = b.glyphs[b.count - 1].cluster
	otl_buffer_add(b, gid, cp, cluster, ttf_mask_global)
	b.glyphs[b.count - 1].unicode_mark = ut_is_nonspacing_mark(cp)

# Thai and Lao SARA AM: decomposed to NIKHAHIT + SARA AA, with the
# NIKHAHIT moved before any above-base marks it follows, all in the
# base's cluster (HarfBuzz's Thai preprocessing).
int ttf_thai_above_mark(int cp):
	int c = cp & ~0x80
	return ((c >= 0x0e34) && (c <= 0x0e37)) || ((c >= 0x0e47) && (c <= 0x0e4e)) || (c == 0x0e31) || (c == 0x0e3b)

void ttf_thai_sara_am(ttf_font* f, otl_buffer* b, int cp, int source):
	ttf_shape_add(f, b, cp - 0x0e33 + 0x0e4d, source, 0)
	ttf_shape_add(f, b, cp - 1, source, 0)
	int end = b.count
	int start = end - 2
	while ((start > 0) && ttf_thai_above_mark(b.glyphs[start - 1].cp)): start = start - 1
	int from = start
	if (start + 2 < end):
		otl_glyph nikhahit
		otl_glyph_copy(&nikhahit, &b.glyphs[end - 2])
		int k = end - 2
		while (k > start):
			otl_glyph_copy(&b.glyphs[k], &b.glyphs[k - 1])
			k = k - 1
		otl_glyph_copy(&b.glyphs[start], &nikhahit)
	else if (start > 0): from = start - 1
	int cluster = b.glyphs[from].cluster
	for k in range(from, end):
		if (b.glyphs[k].cluster < cluster): cluster = b.glyphs[k].cluster
	for k in range(from, end): b.glyphs[k].cluster = cluster

# The GSUB stages of every script but the Indic ones: ccmp/locl, Arabic-
# style joining forms (or the presentation-form fallback), rlig, then
# rclt/calt/liga/clig.
void ttf_shape_gsub(ttf_font* f, otl_buffer* b, char* scripts, int script_count, int language, int joining, int rtl, int flags):
	int[16] tags
	int[16] masks
	int n = 0
	# Joining forms come from the characters, before ccmp can decompose
	# a letter into glyphs (a substitution's output inherits the mask).
	if (joining):
		int32* early = cast(int32*, malloc(b.count * 4 + 4))
		ttf_joining_forms(b, early)
		for i in range(b.count): b.glyphs[i].mask = b.glyphs[i].mask | ttf_form_mask(early[i])
		free(early)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"rvrn"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"ccmp"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"locl"), ttf_mask_global, &n)
	otl_apply_stage(f, b, otl_gsub, scripts, script_count, language, &tags[0], &masks[0], n, rtl)
	if (joining):
		int has_forms = otl_has_feature(f, otl_gsub, scripts, script_count, otl_tag(c"init")) || otl_has_feature(f, otl_gsub, scripts, script_count, otl_tag(c"fina"))
		if (has_forms):
			char* order = c"isolfinamediinit"
			for k in range(4):
				tags[0] = otl_tag(&order[k * 4])
				masks[0] = ttf_mask_isol << k
				otl_apply_stage(f, b, otl_gsub, scripts, script_count, language, &tags[0], &masks[0], 1, rtl)
		else:
			int32* forms = cast(int32*, malloc(b.count * 4 + 4))
			ttf_joining_forms(b, forms)
			ttf_arabic_fallback(f, b, forms)
			free(forms)
			# The presentation glyphs take their own GDEF classes.
			otl_set_classes(f, b)
	n = 0
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"rlig"), ttf_mask_global, &n)
	otl_apply_stage(f, b, otl_gsub, scripts, script_count, language, &tags[0], &masks[0], n, rtl)
	n = 0
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"rclt"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"calt"), ttf_mask_global, &n)
	if ((flags & ttf_shape_no_liga) == 0):
		ttf_stage1(&tags[0], &masks[0], otl_tag(c"liga"), ttf_mask_global, &n)
		ttf_stage1(&tags[0], &masks[0], otl_tag(c"clig"), ttf_mask_global, &n)
	otl_apply_stage(f, b, otl_gsub, scripts, script_count, language, &tags[0], &masks[0], n, rtl)

# HarfBuzz's vowel constraints (the USE spec's
# IndicShapingInvalidCluster.txt): whether a dotted circle goes between
# a and b, an independent vowel and a sign that together look like
# another vowel. (Devanagari RA, VIRAMA, I is handled by the caller.)
int ttf_indic_vowel_constraint(char* code, int a, int b):
	if (ttf_code_is(code, c"Deva")):
		if (a == 0x0905): return (b == 0x093a) || (b == 0x093b) || (b == 0x093e) || (b == 0x0945) || (b == 0x0946) || (b == 0x0949) || (b == 0x094a) || (b == 0x094b) || (b == 0x094c) || (b == 0x094f) || (b == 0x0956) || (b == 0x0957)
		if (a == 0x0906): return (b == 0x093a) || (b == 0x0945) || (b == 0x0946) || (b == 0x0947) || (b == 0x0948)
		if (a == 0x0909): return (b == 0x0941)
		if (a == 0x090f): return (b == 0x0945) || (b == 0x0946) || (b == 0x0947)
		return 0
	if (ttf_code_is(code, c"Beng")):
		if (a == 0x0985): return (b == 0x09be)
		if (a == 0x098b): return (b == 0x09c3)
		if (a == 0x098c): return (b == 0x09e2)
		return 0
	if (ttf_code_is(code, c"Guru")):
		if (a == 0x0a05): return (b == 0x0a3e) || (b == 0x0a48) || (b == 0x0a4c)
		if (a == 0x0a72): return (b == 0x0a3f) || (b == 0x0a40) || (b == 0x0a47)
		if (a == 0x0a73): return (b == 0x0a41) || (b == 0x0a42) || (b == 0x0a4b)
		return 0
	if (ttf_code_is(code, c"Gujr")):
		if (a == 0x0a85): return (b == 0x0abe) || (b == 0x0ac5) || (b == 0x0ac7) || (b == 0x0ac8) || (b == 0x0ac9) || (b == 0x0acb) || (b == 0x0acc)
		if (a == 0x0ac5): return (b == 0x0abe)
		return 0
	if (ttf_code_is(code, c"Orya")):
		if (a == 0x0b05): return (b == 0x0b3e)
		if (a == 0x0b0f): return (b == 0x0b57)
		if (a == 0x0b13): return (b == 0x0b57)
		return 0
	if (ttf_code_is(code, c"Taml")):
		if (a == 0x0b85): return (b == 0x0bc2)
		return 0
	if (ttf_code_is(code, c"Telu")):
		if (a == 0x0c12): return (b == 0x0c4c) || (b == 0x0c55)
		if (a == 0x0c3f): return (b == 0x0c55)
		if (a == 0x0c46): return (b == 0x0c55)
		if (a == 0x0c4a): return (b == 0x0c55)
		return 0
	if (ttf_code_is(code, c"Knda")):
		if (a == 0x0c89): return (b == 0x0cbe)
		if (a == 0x0c8b): return (b == 0x0cbe)
		if (a == 0x0c92): return (b == 0x0ccc)
		return 0
	if (ttf_code_is(code, c"Mlym")):
		if (a == 0x0d07): return (b == 0x0d57)
		if (a == 0x0d09): return (b == 0x0d57)
		if (a == 0x0d0e): return (b == 0x0d46)
		if (a == 0x0d12): return (b == 0x0d3e) || (b == 0x0d57)
		return 0
	return 0

# Shape count codepoints (clusters[i] is each one's source position) as
# one run. rtl: 1 for a right-to-left run. script: a lib.unicode_text
# script id, or -1 to guess from the text. language: an OpenType
# language-system tag (otl_tag), or 0. Returns an owned buffer in visual
# order; free it with otl_buffer_free.
# A font with no space glyph to hide default ignorables (VS16 after an
# emoji, ZWJ) behind drops them instead, as HarfBuzz does, merging a
# dropped glyph's cluster into its neighbor's.
void ttf_shape_drop_ignorables(otl_buffer* b):
	int i = 0
	while (i < b.count):
		otl_glyph* g = &b.glyphs[i]
		if ((g.cp < 0) || !ut_default_ignorable(g.cp)):
			i = i + 1
			continue
		int cluster = g.cluster
		if ((i + 1 < b.count) && (b.glyphs[i + 1].cluster == cluster)):
			otl_buffer_delete(b, i)
			continue
		if (i > 0):
			int old = b.glyphs[i - 1].cluster
			if (cluster < old):
				int k = i - 1
				while ((k >= 0) && (b.glyphs[k].cluster == old)):
					b.glyphs[k].cluster = cluster
					k = k - 1
		else if ((i + 1 < b.count) && (cluster < b.glyphs[i + 1].cluster)):
			int old = b.glyphs[i + 1].cluster
			int k = i + 1
			while ((k < b.count) && (b.glyphs[k].cluster == old)):
				b.glyphs[k].cluster = cluster
				k = k + 1
		otl_buffer_delete(b, i)

otl_buffer* ttf_shape(ttf_font* f, int32* cps, int32* clusters, int count, int rtl, int script, int language, int flags):
	otl_buffer* b = otl_buffer_new(count + 4)
	if (script < 0): script = ttf_guess_script(cps, count)
	int space = ttf_glyph_id(f, ' ')
	char[40] scripts
	int script_count = ttf_script_tags(script, &scripts[0])
	char* code = ut_script_code(script)
	int indic = ttf_indic_applies(f, code, &scripts[0], script_count)
	int32[16] parts
	int vowel_last = -1
	for i in range(count):
		int pieces = 0
		parts[0] = cps[i]
		# HarfBuzz's Indic preprocessing: a dotted circle splits a vowel
		# sequence that would read as another vowel (pairs do not overlap).
		int split = indic && (i > 0) && (i - 1 > vowel_last) && ttf_indic_vowel_constraint(code, cps[i - 1], cps[i])
		if (indic && (i > 1) && (i - 2 > vowel_last) && ttf_code_is(code, c"Deva") && (cps[i - 2] == 0x0930) && (cps[i - 1] == 0x094d) && (cps[i] == 0x0907)): split = 1
		if (split):
			vowel_last = i
			int circle_cluster = clusters[i]
			if ((b.count > 0) && ttf_continues_cluster(cps[i])): circle_cluster = b.glyphs[b.count - 1].cluster
			otl_buffer_add(b, ttf_glyph_id(f, 0x25cc), 0x25cc, circle_cluster, ttf_mask_global)
		if ((cps[i] & ~0x80) == 0x0e33):
			ttf_thai_sara_am(f, b, cps[i], clusters[i])
			continue
		if (indic): pieces = ttf_indic_decompose(f, cps[i], &parts[0], 0)
		else if (ttf_glyph_id(f, cps[i]) == 0): pieces = ttf_decompose_for(f, cps[i], &parts[0], 0)
		if (pieces == 0):
			parts[0] = cps[i]
			pieces = 1
		for p in range(pieces): ttf_shape_add(f, b, parts[p], clusters[i], rtl)
	ttf_reorder_marks(b)
	int hebrew_forms = ttf_code_is(code, c"Hebr") && !otl_has_feature(f, otl_gpos, &scripts[0], script_count, otl_tag(c"mark"))
	if (indic): ttf_indic_recompose(f, b)
	else: ttf_recompose(f, b, hebrew_forms)
	otl_set_classes(f, b)
	int[16] tags
	int[16] masks
	int n = 0
	int joining = ttf_is_joining_script(code) && !indic
	if (indic):
		ttf_indic_plan* plan = ttf_indic_plan_new(f, ttf_indic_script(code), &scripts[0], script_count, language)
		ttf_indic_shape(plan, b, (flags & ttf_shape_no_liga) == 0)
		ttf_indic_plan_free(plan)
	else: ttf_shape_gsub(f, b, &scripts[0], script_count, language, joining, rtl, flags)
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		g.x_advance = ttf_advance_units(f, g.gid)
		if ((g.gid == space) && (g.cp >= 0) && (g.cp != ' ') && (ttf_glyph_id(f, g.cp) == 0) && (ttf_space_fallback(g.cp) != 0)): g.x_advance = ttf_space_fallback_advance(f, ttf_space_fallback(g.cp), g.x_advance)
		g.y_advance = 0
		g.x_offset = 0
		g.y_offset = 0
		g.attach = -1
		g.attach_kind = 0
	n = 0
	if ((flags & ttf_shape_no_kern) == 0): ttf_stage1(&tags[0], &masks[0], otl_tag(c"kern"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"mark"), ttf_mask_global | otl_mask_manual_joiners, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"mkmk"), ttf_mask_global | otl_mask_manual_joiners, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"curs"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"dist"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"abvm"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"blwm"), ttf_mask_global, &n)
	# As in HarfBuzz, any GPOS with lookups counts as positioning the
	# text (no fallback marks), whether or not this script uses it.
	int gpos = ttf_table(f, c"GPOS")
	int positioned = (gpos != 0) && (ttf_u16(f, gpos + ttf_u16(f, gpos + 8)) > 0)
	if (positioned && ttf_code_is(code, c"Hebr") && !otl_langsys(f, gpos, c"hebr", 1, 0)): positioned = 0
	if (positioned): otl_apply_stage(f, b, otl_gpos, &scripts[0], script_count, language, &tags[0], &masks[0], n, rtl)
	# The legacy kern table stands in for a missing GPOS 'kern' feature.
	# (HarfBuzz's Indic shaper applies no legacy kerning.)
	if (((flags & ttf_shape_no_kern) == 0) && !indic && (!positioned || !otl_has_feature(f, otl_gpos, &scripts[0], script_count, otl_tag(c"kern")))): ttf_fallback_kern(f, b, rtl)
	# Like HarfBuzz: a font with no usable GPOS gets fallback mark
	# placement, except in Indic and Thai text, whose marks the font
	# designs in place. GPOS counts as unusable for Hebrew unless it has
	# the 'hebr' script (a HarfBuzz rule for broken legacy fonts).
	# First GDEF marks lose their width (the Indic shaper zeroes none);
	# without GDEF the classes come from the text (nonspacing marks).
	# Without GPOS, an LTR mark keeps its ink where it was by moving back
	# by the width it loses.
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		if (!indic && (g.props == otl_class_mark)):
			if (!positioned && !rtl): g.x_offset = g.x_offset - g.x_advance
			g.x_advance = 0
	if (!positioned && !indic && !ttf_code_is(code, c"Thai") && !ttf_code_is(code, c"Laoo")): ttf_fallback_marks(f, b, rtl)
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		if ((g.cp >= 0) && ut_default_ignorable(g.cp)):
			g.gid = space
			g.x_advance = 0
			g.x_offset = 0
			g.attach_kind = 0
	otl_position_finish(b, rtl)
	if (space == 0): ttf_shape_drop_ignorables(b)
	if (rtl): otl_buffer_reverse(b)
	return b
