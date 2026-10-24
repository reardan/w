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

Complex Indic and Southeast Asian reordering is limited to Devanagari:
pre-base matra and reph reordering with the dev2 feature sequence (see
ttf_shape_indic). Other complex scripts apply the generic features,
which suits Thai and Hebrew fonts but not full Indic shaping.
*/
import lib.lib
import lib.ttf
import lib.ttf_layout
import lib.unicode_text

const int ttf_shape_no_liga = 1     # flags: disable liga/clig
const int ttf_shape_no_kern = 2     # flags: disable kern

# Feature masks. Global features use bit 0; Arabic positional forms and
# Indic per-syllable features take their own bits.
const int ttf_mask_global = 1
const int ttf_mask_isol = 2
const int ttf_mask_fina = 4
const int ttf_mask_medi = 8
const int ttf_mask_init = 16
const int ttf_mask_rphf = 32
const int ttf_mask_half = 64
const int ttf_mask_pref = 128
const int ttf_mask_blwf = 256
const int ttf_mask_pstf = 512

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
# sin dots; shadda) sort first, which is the order fonts expect.
int ttf_modified_ccc(int cp):
	int ccc = ut_combining_class(cp)
	if ((ccc >= 10) && (ccc <= 26)):
		char* hebrew = c"\x16\x0f\x10\x11\x17\x12\x13\x14\x15\x0e\x18\x0c\x19\x0d\x0a\x0b\x1a"
		return hebrew[ccc - 10]
	if ((ccc >= 27) && (ccc <= 32)): return ccc + 1
	if (ccc == 33): return 27
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
		int joins_previous = ((type == ut_join_r) || (type == ut_join_d) || (type == ut_join_c)) && ((previous_type == ut_join_l) || (previous_type == ut_join_d) || (previous_type == ut_join_c))
		if ((type == ut_join_r) || (type == ut_join_d) || (type == ut_join_l)): forms[i] = ut_form_isol
		if (joins_previous):
			# The previous character gains a following join.
			if (previous >= 0):
				if (forms[previous] == ut_form_isol): forms[previous] = ut_form_init
				else if (forms[previous] == ut_form_fina): forms[previous] = ut_form_medi
			if ((type == ut_join_r) || (type == ut_join_d)): forms[i] = ut_form_fina
		previous = i
		previous_type = type
	# Join-causing characters (ZWJ, tatweel) take no forms of their own.
	for i in range(b.count):
		if ((b.glyphs[i].cp >= 0) && (ut_joining_type(b.glyphs[i].cp) == ut_join_c)): forms[i] = ut_form_none

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
				if (lig >= 0): gid = ttf_glyph_id(f, lig)
				if (gid != 0):
					g.gid = gid
					for k in range(i + 1, j + 1): b.glyphs[k].cluster = g.cluster
					otl_buffer_delete(b, j)
					for k in range(j, b.count): forms[k] = forms[k + 1]
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

const int ttf_attach_above = 1
const int ttf_attach_below = 2
const int ttf_attach_above_left = 3
const int ttf_attach_above_right = 4
const int ttf_attach_below_left = 5
const int ttf_attach_below_right = 6
const int ttf_attach_center = 7

# Where fallback placement puts a mark, from its combining class, with
# HarfBuzz's mapping of the script-specific Hebrew, Arabic, Thai, Lao and
# Tibetan classes. Other classes are only centred horizontally.
int ttf_mark_placement(int cp):
	int ccc = ut_combining_class(cp)
	if ((ccc == 19) || (ccc == 25)): return ttf_attach_above_left
	if (ccc == 24): return ttf_attach_above_right
	if ((ccc == 23) || (ccc == 26)): return ttf_attach_above
	if ((ccc >= 10) && (ccc <= 22) && (ccc != 21)): return ttf_attach_below
	if ((ccc == 29) || (ccc == 32)): return ttf_attach_below
	if ((ccc >= 27) && (ccc <= 36)): return ttf_attach_above
	if (ccc == 103): return ttf_attach_below_right
	if (ccc == 107): return ttf_attach_above_right
	if ((ccc == 118) || (ccc == 129) || (ccc == 132)): return ttf_attach_below
	if ((ccc == 122) || (ccc == 130)): return ttf_attach_above
	if ((ccc == 202) || (ccc == 220) || (ccc == 233)): return ttf_attach_below
	if ((ccc == 200) || (ccc == 218)): return ttf_attach_below_left
	if (ccc == 222): return ttf_attach_below_right
	if ((ccc == 214) || (ccc == 230) || (ccc == 234)): return ttf_attach_above
	if (ccc == 228): return ttf_attach_above_left
	if ((ccc == 216) || (ccc == 232)): return ttf_attach_above_right
	return ttf_attach_center

# Place nonspacing marks around their base from glyph boxes (HarfBuzz's
# fallback mark positioning): centred or edge-aligned, a gap of upem/16
# from the base's ink, stacking outward. Marks get no advance.
void ttf_fallback_marks(ttf_font* f, otl_buffer* b):
	int[4] base_box
	int[4] mark_box
	int gap = f.upem / 16
	int base = -1
	int top = 0
	int bottom = 0
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		if (!g.unicode_mark):
			base = i
			ttf_glyph_bbox(f, g.gid, &base_box[0])
			top = base_box[3]
			bottom = base_box[1]
			continue
		g.x_advance = 0
		if ((base < 0) || (g.attach_kind != 0)): continue
		ttf_glyph_bbox(f, g.gid, &mark_box[0])
		int placement = ttf_mark_placement(g.cp)
		# Attached classes (200-216) touch the base; the rest keep a gap.
		int ccc = ut_combining_class(g.cp)
		int space = gap
		if ((ccc >= 200) && (ccc <= 216)): space = 0
		# Horizontally the base spans its advance, not its ink (HarfBuzz
		# does this so zero-ink bases still place marks sensibly).
		int base_width = ttf_advance_units(f, b.glyphs[base].gid)
		int mark_width = mark_box[2] - mark_box[0]
		int dx = (base_width - mark_width) / 2 - mark_box[0]
		if ((placement == ttf_attach_above_left) || (placement == ttf_attach_below_left)): dx = 0 - mark_box[0]
		if ((placement == ttf_attach_above_right) || (placement == ttf_attach_below_right)): dx = base_width - mark_width - mark_box[0]
		int dy = 0
		if ((placement == ttf_attach_below) || (placement == ttf_attach_below_left) || (placement == ttf_attach_below_right)):
			dy = bottom - space - mark_box[3]
			bottom = mark_box[1] + dy
		else if (placement != ttf_attach_center):
			dy = top + space - mark_box[1]
			top = mark_box[3] + dy
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

int ttf_shape_indic(ttf_font* f, otl_buffer* b, char* scripts, int script_count, int language);

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
void ttf_recompose(ttf_font* f, otl_buffer* b):
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

int ttf_continues_cluster(int cp):
	int category = ut_category(cp)
	if ((category == ut_cat_mn) || (category == ut_cat_mc) || (category == ut_cat_me)): return 1
	return (cp == 0x200d) || ((cp >= 0x1160) && (cp <= 0x11ff)) || ((cp >= 0xfe00) && (cp <= 0xfe0f)) || ((cp >= 0xe0100) && (cp <= 0xe01ef)) || ((cp >= 0x1f3fb) && (cp <= 0x1f3ff))

void ttf_shape_add(ttf_font* f, otl_buffer* b, int cp, int source, int rtl):
	int gid = ttf_glyph_id(f, cp)
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

# Shape count codepoints (clusters[i] is each one's source position) as
# one run. rtl: 1 for a right-to-left run. script: a lib.unicode_text
# script id, or -1 to guess from the text. language: an OpenType
# language-system tag (otl_tag), or 0. Returns an owned buffer in visual
# order; free it with otl_buffer_free.
otl_buffer* ttf_shape(ttf_font* f, int32* cps, int32* clusters, int count, int rtl, int script, int language, int flags):
	otl_buffer* b = otl_buffer_new(count + 4)
	if (script < 0): script = ttf_guess_script(cps, count)
	int space = ttf_glyph_id(f, ' ')
	int32[16] parts
	for i in range(count):
		int pieces = 0
		parts[0] = cps[i]
		if (ttf_glyph_id(f, cps[i]) == 0): pieces = ttf_decompose_for(f, cps[i], &parts[0], 0)
		if (pieces == 0):
			parts[0] = cps[i]
			pieces = 1
		for p in range(pieces): ttf_shape_add(f, b, parts[p], clusters[i], rtl)
	ttf_reorder_marks(b)
	ttf_recompose(f, b)
	otl_set_classes(f, b)
	char[40] scripts
	int script_count = ttf_script_tags(script, &scripts[0])
	int[16] tags
	int[16] masks
	int n = 0
	char* code = ut_script_code(script)
	int joining = ttf_is_joining_script(code)
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
	otl_apply_stage(f, b, otl_gsub, &scripts[0], script_count, language, &tags[0], &masks[0], n, rtl)
	if ttf_code_is(code, c"Deva"): ttf_shape_indic(f, b, &scripts[0], script_count, language)
	if (joining):
		int has_forms = otl_has_feature(f, otl_gsub, &scripts[0], script_count, otl_tag(c"init")) || otl_has_feature(f, otl_gsub, &scripts[0], script_count, otl_tag(c"fina"))
		if (has_forms):
			char* order = c"isolfinamediinit"
			for k in range(4):
				tags[0] = otl_tag(&order[k * 4])
				masks[0] = ttf_mask_isol << k
				otl_apply_stage(f, b, otl_gsub, &scripts[0], script_count, language, &tags[0], &masks[0], 1, rtl)
		else:
			int32* forms = cast(int32*, malloc(b.count * 4 + 4))
			ttf_joining_forms(b, forms)
			ttf_arabic_fallback(f, b, forms)
			free(forms)
	n = 0
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"rlig"), ttf_mask_global, &n)
	otl_apply_stage(f, b, otl_gsub, &scripts[0], script_count, language, &tags[0], &masks[0], n, rtl)
	n = 0
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"rclt"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"calt"), ttf_mask_global, &n)
	if ((flags & ttf_shape_no_liga) == 0):
		ttf_stage1(&tags[0], &masks[0], otl_tag(c"liga"), ttf_mask_global, &n)
		ttf_stage1(&tags[0], &masks[0], otl_tag(c"clig"), ttf_mask_global, &n)
	otl_apply_stage(f, b, otl_gsub, &scripts[0], script_count, language, &tags[0], &masks[0], n, rtl)
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		g.x_advance = ttf_advance_units(f, g.gid)
		g.y_advance = 0
		g.x_offset = 0
		g.y_offset = 0
		g.attach = -1
		g.attach_kind = 0
	n = 0
	if ((flags & ttf_shape_no_kern) == 0): ttf_stage1(&tags[0], &masks[0], otl_tag(c"kern"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"mark"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"mkmk"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"curs"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"dist"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"abvm"), ttf_mask_global, &n)
	ttf_stage1(&tags[0], &masks[0], otl_tag(c"blwm"), ttf_mask_global, &n)
	int positioned = 0
	if (!ttf_code_is(code, c"Hebr") || otl_langsys(f, ttf_table(f, c"GPOS"), c"hebr", 1, 0)): positioned = otl_apply_stage(f, b, otl_gpos, &scripts[0], script_count, language, &tags[0], &masks[0], n, rtl)
	# The legacy kern table stands in for a missing GPOS 'kern' feature.
	if (((flags & ttf_shape_no_kern) == 0) && (!positioned || !otl_has_feature(f, otl_gpos, &scripts[0], script_count, otl_tag(c"kern")))): ttf_fallback_kern(f, b, rtl)
	# Like HarfBuzz: a font with no usable GPOS gets fallback mark
	# placement, except in Indic and Thai text, whose marks the font
	# designs in place. GPOS counts as unusable for Hebrew unless it has
	# the 'hebr' script (a HarfBuzz rule for broken legacy fonts).
	if (!positioned && !ttf_code_is(code, c"Deva") && !ttf_code_is(code, c"Thai") && !ttf_code_is(code, c"Laoo")): ttf_fallback_marks(f, b)
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		if ((g.props == otl_class_mark) && g.unicode_mark): g.x_advance = 0
		if ((g.cp >= 0) && ut_default_ignorable(g.cp)):
			g.gid = space
			g.x_advance = 0
			g.x_offset = 0
			g.attach_kind = 0
	otl_position_finish(b, rtl)
	if (rtl): otl_buffer_reverse(b)
	return b

# ---- Devanagari --------------------------------------------------------

# Indic character classes for the Devanagari block (U+0900..U+097F).
const int ttf_indic_other = 0
const int ttf_indic_consonant = 1
const int ttf_indic_halant = 2
const int ttf_indic_nukta = 3
const int ttf_indic_matra_pre = 4
const int ttf_indic_matra = 5
const int ttf_indic_vowel = 6
const int ttf_indic_mark = 7
const int ttf_indic_ra = 8
const int ttf_indic_zwj = 9

int ttf_indic_class(int cp):
	if (cp == 0x200d): return ttf_indic_zwj
	if ((cp < 0x0900) || (cp > 0x097f)): return ttf_indic_other
	if (cp == 0x0930): return ttf_indic_ra
	if (cp == 0x094d): return ttf_indic_halant
	if (cp == 0x093c): return ttf_indic_nukta
	if (cp == 0x093f): return ttf_indic_matra_pre
	if (((cp >= 0x093e) && (cp <= 0x094c)) || ((cp >= 0x094e) && (cp <= 0x094f)) || ((cp >= 0x0955) && (cp <= 0x0957)) || ((cp >= 0x0962) && (cp <= 0x0963)) || (cp == 0x093a) || (cp == 0x093b)): return ttf_indic_matra
	if (((cp >= 0x0915) && (cp <= 0x0939)) || ((cp >= 0x0958) && (cp <= 0x095f)) || ((cp >= 0x0978) && (cp <= 0x097f))): return ttf_indic_consonant
	if (((cp >= 0x0904) && (cp <= 0x0914)) || ((cp >= 0x0960) && (cp <= 0x0961)) || ((cp >= 0x0972) && (cp <= 0x0977))): return ttf_indic_vowel
	if ((cp >= 0x0900) && (cp <= 0x0903)): return ttf_indic_mark
	return ttf_indic_other

int ttf_indic_glyph_class(otl_glyph* g):
	if (g.cp < 0): return ttf_indic_other
	return ttf_indic_class(g.cp)

int ttf_indic_is_consonant(int cls):
	return (cls == ttf_indic_consonant) || (cls == ttf_indic_ra)

# Devanagari syllables: (Ra H)? (C N? H)* C N? (matras, marks)* — the
# initial Ra+halant becomes a reph (moved after the base and its
# post-base matras) and a pre-base matra (U+093F) moves before the
# consonant cluster. Then the dev2 basic features apply per syllable
# position masks and the presentation features globally.
int ttf_shape_indic(ttf_font* f, otl_buffer* b, char* scripts, int script_count, int language):
	# Reph and rakar need the font's forms for them (HarfBuzz asks
	# whether rphf/blwf would substitute; the feature's presence is close).
	int can_reph = otl_has_feature(f, otl_gsub, scripts, script_count, otl_tag(c"rphf"))
	int can_rakar = otl_has_feature(f, otl_gsub, scripts, script_count, otl_tag(c"blwf"))
	int can_half = otl_has_feature(f, otl_gsub, scripts, script_count, otl_tag(c"half"))
	int syllable = 0
	int i = 0
	while (i < b.count):
		int cls = ttf_indic_glyph_class(&b.glyphs[i])
		if (!ttf_indic_is_consonant(cls)):
			i = i + 1
			continue
		int start = i
		int has_reph = 0
		if (can_reph && (cls == ttf_indic_ra) && (i + 2 < b.count) && (ttf_indic_glyph_class(&b.glyphs[i + 1]) == ttf_indic_halant) && ttf_indic_is_consonant(ttf_indic_glyph_class(&b.glyphs[i + 2]))):
			has_reph = 1
		int at = i
		int base = i
		while (at < b.count):
			int c = ttf_indic_glyph_class(&b.glyphs[at])
			if (!ttf_indic_is_consonant(c)): break
			base = at
			at = at + 1
			if ((at < b.count) && (ttf_indic_glyph_class(&b.glyphs[at]) == ttf_indic_nukta)): at = at + 1
			if ((at < b.count) && (ttf_indic_glyph_class(&b.glyphs[at]) == ttf_indic_halant)):
				int after = at + 1
				if ((after < b.count) && (ttf_indic_glyph_class(&b.glyphs[after]) == ttf_indic_zwj)): after = after + 1
				if ((after < b.count) && ttf_indic_is_consonant(ttf_indic_glyph_class(&b.glyphs[after]))):
					at = after
					continue
				at = at + 1
				break
			break
		int end = at
		while ((end < b.count) && ((ttf_indic_glyph_class(&b.glyphs[end]) == ttf_indic_matra) || (ttf_indic_glyph_class(&b.glyphs[end]) == ttf_indic_matra_pre) || (ttf_indic_glyph_class(&b.glyphs[end]) == ttf_indic_mark) || (ttf_indic_glyph_class(&b.glyphs[end]) == ttf_indic_nukta) || (ttf_indic_glyph_class(&b.glyphs[end]) == ttf_indic_halant))): end = end + 1
		# A final Ra after a halant takes its below-base form (rakar), so
		# the base is the consonant before it.
		while (can_rakar && (base > start + 1) && (ttf_indic_glyph_class(&b.glyphs[base]) == ttf_indic_ra) && (ttf_indic_glyph_class(&b.glyphs[base - 1]) == ttf_indic_halant)):
			int previous = base - 2
			while ((previous > start) && !ttf_indic_is_consonant(ttf_indic_glyph_class(&b.glyphs[previous]))): previous = previous - 1
			base = previous
		if (has_reph && (base == start)): has_reph = 0
		# Masks: half forms for consonants before the base, below-base
		# forms after it, reph on the initial Ra+halant.
		syllable = syllable + 1
		for k in range(start, end):
			otl_glyph* g = &b.glyphs[k]
			g.syllable = syllable
			if (k < base): g.mask = g.mask | ttf_mask_half
			if (k > base): g.mask = g.mask | ttf_mask_blwf | ttf_mask_pstf
		if (has_reph):
			b.glyphs[start].mask = (b.glyphs[start].mask | ttf_mask_rphf) & ~ttf_mask_half
			b.glyphs[start + 1].mask = (b.glyphs[start + 1].mask | ttf_mask_rphf) & ~ttf_mask_half
		# Pre-base matra to the syllable start (after a reph's Ra+halant
		# keeps its logical place until rphf forms the reph).
		otl_glyph tmp
		for k in range(base + 1, end):
			if (ttf_indic_glyph_class(&b.glyphs[k]) == ttf_indic_matra_pre):
				otl_glyph_copy(&tmp, &b.glyphs[k])
				int m = k
				int target = start
				if (has_reph): target = start + 2
				# Without half forms a halant before the base stays visible,
				# and the matra goes after the last one (HarfBuzz's final
				# reordering).
				if (!can_half):
					for x in range(target, base):
						if (ttf_indic_glyph_class(&b.glyphs[x]) == ttf_indic_halant): target = x + 1
				while (m > target):
					otl_glyph_copy(&b.glyphs[m], &b.glyphs[m - 1])
					m = m - 1
				otl_glyph_copy(&b.glyphs[target], &tmp)
				# The matra and the consonants it moved over, through the base,
				# share one cluster, as in HarfBuzz.
				int through = min(k, base + 1)
				for x in range(target + 1, through + 1):
					if (b.glyphs[x].cluster < b.glyphs[target].cluster): b.glyphs[target].cluster = b.glyphs[x].cluster
				for x in range(target + 1, through + 1): b.glyphs[x].cluster = b.glyphs[target].cluster
		i = end
	int[16] tags
	int[16] masks
	char* basic = c"nuktakhnrphfrkrfblwfhalfvatucjct"
	int[8] basic_masks
	basic_masks[0] = ttf_mask_global
	basic_masks[1] = ttf_mask_global
	basic_masks[2] = ttf_mask_rphf
	basic_masks[3] = ttf_mask_global
	basic_masks[4] = ttf_mask_blwf
	basic_masks[5] = ttf_mask_half
	basic_masks[6] = ttf_mask_global
	basic_masks[7] = ttf_mask_global
	for k in range(8):
		tags[0] = otl_tag(&basic[k * 4])
		masks[0] = basic_masks[k]
		otl_apply_stage(f, b, otl_gsub, scripts, script_count, language, &tags[0], &masks[0], 1, 0)
	# Move a formed reph after the base and its post-base matras.
	i = 0
	while (i < b.count):
		otl_glyph* g = &b.glyphs[i]
		if (((g.mask & ttf_mask_rphf) == 0) || (g.cp != 0x0930)):
			i = i + 1
			continue
		int syllable_id = g.syllable
		int j = i + 1
		while ((j < b.count) && (syllable_id != 0) && (b.glyphs[j].syllable == syllable_id)): j = j + 1
		int consumed = (i + 1 >= b.count) || (b.glyphs[i + 1].cp != 0x094d)
		if (consumed && (j - 1 > i)):
			otl_glyph tmp
			otl_glyph_copy(&tmp, g)
			tmp.mask = tmp.mask & ~ttf_mask_rphf
			for k in range(i, j - 1): otl_glyph_copy(&b.glyphs[k], &b.glyphs[k + 1])
			otl_glyph_copy(&b.glyphs[j - 1], &tmp)
			int cluster = b.glyphs[i].cluster
			for k in range(i, j):
				if (b.glyphs[k].cluster < cluster): cluster = b.glyphs[k].cluster
			for k in range(i, j): b.glyphs[k].cluster = cluster
		else: b.glyphs[i].mask = b.glyphs[i].mask & ~ttf_mask_rphf
		i = j
	char* presentation = c"presabvsblwspstshaln"
	for k in range(5):
		tags[k] = otl_tag(&presentation[k * 4])
		masks[k] = ttf_mask_global
	otl_apply_stage(f, b, otl_gsub, scripts, script_count, language, &tags[0], &masks[0], 5, 0)
	return 1
