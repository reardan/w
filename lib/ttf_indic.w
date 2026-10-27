/*
lib.ttf_indic: the Indic shaper behind lib.ttf_shape (issue #459), a port
of HarfBuzz's hb-ot-shaper-indic for Devanagari, Bengali, Gurmukhi,
Gujarati, Oriya, Tamil, Telugu, Kannada and Malayalam.

	ttf_indic_shape(plan, b)

runs the whole GSUB pipeline of an Indic run over a normalized buffer:
rvrn; syllable segmentation (HarfBuzz's Ragel machine, re-expressed as a
longest-match set simulation); per-syllable locl/ccmp; initial reordering
(base consonant search with would-substitute consonant positions, reph,
pre-base matras, split-matra parts, post-base ownership, the stable
position sort and its cluster merges, old-spec halant moves, feature
masks, pref marking, joiner effects and dotted circles for broken
clusters); the basic features one at a time (nukt akhn rphf rkrf pref
blwf abvf half pstf vatu cjct); final reordering (pre-base matra, reph
by the script's reph position, pref glyph, init); and the presentation
features (init pres abvs blws psts haln with rlig calt clig rclt).
Character categories and positions come from lib.unicode_text
(ut_indic_category / ut_indic_position), the per-script settings from
HarfBuzz's indic_configs.

lib.ttf_shape adds the vowel-constraint dotted circles of
hb-ot-shaper-vowel-constraints (e.g. U+0905 U+093E), and a font whose
chosen tag is a 'dev3'-style one shapes with lib.ttf_use instead, as in
HarfBuzz. Not ported: syllables longer than ttf_indic_window characters,
which are split.
*/
import lib.lib
import lib.ttf
import lib.ttf_layout
import lib.unicode_text

# Feature masks; bit 0 is ttf_shape's global mask and bits 1-4 its
# Arabic positional forms.
const int ttf_indic_mask_rphf = 32
const int ttf_indic_mask_half = 64
const int ttf_indic_mask_pref = 128
const int ttf_indic_mask_blwf = 256
const int ttf_indic_mask_pstf = 512
const int ttf_indic_mask_abvf = 1024
const int ttf_indic_mask_init = 2048

const int ttf_reph_implicit = 0     # Ra,H forms reph
const int ttf_reph_explicit = 1     # Ra,H,ZWJ forms reph
const int ttf_reph_log_repha = 2    # an encoded repha needs reordering

const int ttf_blwf_pre_and_post = 0
const int ttf_blwf_post_only = 1

# Syllable types (low four bits of otl_glyph.syllable).
const int ttf_syl_consonant = 0
const int ttf_syl_vowel = 1
const int ttf_syl_standalone = 2
const int ttf_syl_symbol = 3
const int ttf_syl_broken = 4
const int ttf_syl_non_indic = 5

# Longest syllable the segmenter considers.
const int ttf_indic_window = 128

struct ttf_indic_plan:
	ttf_font* font
	char* scripts
	int script_count
	int language
	int script        # 1..9: Deva Beng Guru Gujr Orya Taml Telu Knda Mlym
	int virama_glyph
	int reph_pos
	int reph_mode
	int blwf_mode
	int old_spec
	int zero_context
	int mask_rphf     # feature masks, 0 when the font lacks the feature
	int mask_pref
	int mask_blwf
	int mask_abvf
	int mask_half
	int mask_pstf
	int mask_init
	int32* rphf
	int rphf_count
	int32* pref
	int pref_count
	int32* blwf
	int blwf_count
	int32* pstf
	int pstf_count
	int32* vatu
	int vatu_count

const int ttf_indic_deva = 1
const int ttf_indic_beng = 2
const int ttf_indic_guru = 3
const int ttf_indic_gujr = 4
const int ttf_indic_orya = 5
const int ttf_indic_taml = 6
const int ttf_indic_telu = 7
const int ttf_indic_knda = 8
const int ttf_indic_mlym = 9

# The Indic script number (ttf_indic_deva ..) of an ISO 15924 code, or 0.
int ttf_indic_script(char* code):
	char* codes = c"DevaBengGuruGujrOryaTamlTeluKndaMlym"
	for k in range(9):
		if ((code[0] == codes[k * 4]) && (code[1] == codes[k * 4 + 1]) && (code[2] == codes[k * 4 + 2]) && (code[3] == codes[k * 4 + 3])): return k + 1
	return 0

# Index of the first of scripts (4-byte tags) in the GSUB ScriptList
# (HarfBuzz's chosen script), or -1.
int ttf_indic_chosen_script(ttf_font* f, char* scripts, int script_count):
	int table = ttf_table(f, c"GSUB")
	if (table == 0): return -1
	int list = table + ttf_u16(f, table + 4)
	int count = ttf_u16(f, list)
	for s in range(script_count):
		int want = otl_tag(&scripts[s * 4])
		for i in range(count):
			if (otl_tag_at(f, list + 2 + i * 6) == want): return s
	return -1

# Like HarfBuzz: an Indic script uses this shaper unless the font's GSUB
# script choice falls back to DFLT or latn (a font made for other
# scripts), when it shapes as default text.
int ttf_indic_applies(ttf_font* f, char* code, char* scripts, int script_count):
	if (ttf_indic_script(code) == 0): return 0
	int chosen = ttf_indic_chosen_script(f, scripts, script_count)
	if (chosen < 0): return 1
	int tag = otl_tag(&scripts[chosen * 4])
	return (tag != otl_tag(c"DFLT")) && (tag != otl_tag(c"latn"))

# Whether the selected language system has feature tag (GSUB or GPOS).
int ttf_indic_has_feature(ttf_font* f, char* scripts, int script_count, int language, int tag):
	for kind in range(2):
		int table = ttf_table(f, c"GSUB")
		if (kind == 1): table = ttf_table(f, c"GPOS")
		int langsys = otl_langsys(f, table, scripts, script_count, language)
		if (langsys == 0): continue
		int features = table + ttf_u16(f, table + 6)
		for x in range(ttf_u16(f, langsys + 4)):
			int feature_index = ttf_u16(f, langsys + 6 + x * 2)
			if (feature_index >= ttf_u16(f, features)): continue
			if (otl_tag_at(f, features + 2 + feature_index * 6) == tag): return 1
	return 0

int ttf_indic_feature_mask(ttf_indic_plan* p, char* tag, int mask):
	if (ttf_indic_has_feature(p.font, p.scripts, p.script_count, p.language, otl_tag(tag))): return mask
	return 0

int32* ttf_indic_lookups(ttf_indic_plan* p, char* tag, int* count):
	int32* out = cast(int32*, malloc(256 * 4))
	count[0] = otl_feature_lookups(p.font, p.scripts, p.script_count, p.language, otl_tag(tag), out, 256)
	return out

# HarfBuzz's data_create_indic for script (ttf_indic_*), with the GSUB
# script tags the run selected from.
ttf_indic_plan* ttf_indic_plan_new(ttf_font* f, int script, char* scripts, int script_count, int language):
	ttf_indic_plan* p = new ttf_indic_plan
	p.font = f
	p.scripts = scripts
	p.script_count = script_count
	p.language = language
	p.script = script
	# indic_configs: virama, reph position, reph mode, blwf mode.
	char* viramas = c"\x09\x4d\x09\xcd\x0a\x4d\x0a\xcd\x0b\x4d\x0b\xcd\x0c\x4d\x0c\xcd\x0d\x4d"
	char* reph_pos = c"\x0a\x09\x07\x0a\x05\x0c\x0c\x0c\x05"
	char* reph_mode = c"\x00\x00\x00\x00\x00\x00\x01\x00\x02"
	char* blwf_mode = c"\x00\x00\x00\x00\x00\x00\x01\x01\x00"
	int k = script - 1
	int virama = ((viramas[k * 2] & 255) << 8) | (viramas[k * 2 + 1] & 255)
	p.virama_glyph = ttf_glyph_id(f, virama)
	p.reph_pos = reph_pos[k]
	p.reph_mode = reph_mode[k]
	p.blwf_mode = blwf_mode[k]
	int chosen = ttf_indic_chosen_script(f, scripts, script_count)
	p.old_spec = 1
	if ((chosen >= 0) && (scripts[chosen * 4 + 3] == '2')): p.old_spec = 0
	p.zero_context = !p.old_spec && (script != ttf_indic_mlym)
	p.mask_rphf = ttf_indic_feature_mask(p, c"rphf", ttf_indic_mask_rphf)
	p.mask_pref = ttf_indic_feature_mask(p, c"pref", ttf_indic_mask_pref)
	p.mask_blwf = ttf_indic_feature_mask(p, c"blwf", ttf_indic_mask_blwf)
	p.mask_abvf = ttf_indic_feature_mask(p, c"abvf", ttf_indic_mask_abvf)
	p.mask_half = ttf_indic_feature_mask(p, c"half", ttf_indic_mask_half)
	p.mask_pstf = ttf_indic_feature_mask(p, c"pstf", ttf_indic_mask_pstf)
	p.mask_init = ttf_indic_feature_mask(p, c"init", ttf_indic_mask_init)
	int n = 0
	p.rphf = ttf_indic_lookups(p, c"rphf", &n)
	p.rphf_count = n
	p.pref = ttf_indic_lookups(p, c"pref", &n)
	p.pref_count = n
	p.blwf = ttf_indic_lookups(p, c"blwf", &n)
	p.blwf_count = n
	p.pstf = ttf_indic_lookups(p, c"pstf", &n)
	p.pstf_count = n
	p.vatu = ttf_indic_lookups(p, c"vatu", &n)
	p.vatu_count = n
	return p

void ttf_indic_plan_free(ttf_indic_plan* p):
	free(p.rphf)
	free(p.pref)
	free(p.blwf)
	free(p.pstf)
	free(p.vatu)
	free(p)

# ---- categories ----------------------------------------------------------

int ttf_icat_flag(int cat):
	return 1 << cat

int ttf_indic_consonant_flags():
	return ttf_icat_flag(ut_icat_c) | ttf_icat_flag(ut_icat_cs) | ttf_icat_flag(ut_icat_ra) | ttf_icat_flag(ut_icat_cm) | ttf_icat_flag(ut_icat_v) | ttf_icat_flag(ut_icat_placeholder) | ttf_icat_flag(ut_icat_dottedcircle)

int ttf_indic_joiner_flags():
	return ttf_icat_flag(ut_icat_zwj) | ttf_icat_flag(ut_icat_zwnj)

int ttf_indic_matra_flags():
	return ttf_icat_flag(ut_icat_m) | ttf_icat_flag(ut_icat_mpst)

int ttf_indic_ligated(otl_glyph* g):
	return (g.subst & otl_subst_ligated) != 0

int ttf_indic_ligated_and_didnt_multiply(otl_glyph* g):
	return ((g.subst & otl_subst_ligated) != 0) && ((g.subst & otl_subst_multiplied) == 0)

# HarfBuzz's is_one_of: a ligated glyph is none of them.
int ttf_indic_is_one_of(otl_glyph* g, int flags):
	if (ttf_indic_ligated(g)): return 0
	return (ttf_icat_flag(g.icat) & flags) != 0

int ttf_indic_is_consonant(otl_glyph* g):
	return ttf_indic_is_one_of(g, ttf_indic_consonant_flags())

int ttf_indic_is_joiner(otl_glyph* g):
	return ttf_indic_is_one_of(g, ttf_indic_joiner_flags())

int ttf_indic_is_halant(otl_glyph* g):
	return ttf_indic_is_one_of(g, ttf_icat_flag(ut_icat_h))

# ---- syllables -----------------------------------------------------------

# HarfBuzz's Ragel syllable machine as a set simulation: each grammar
# rule maps the set of positions it may start at to the set it may end
# at, over a window of the buffer. A set is a byte per position.
struct ttf_ism:
	otl_buffer* buffer
	int start
	int len
	int width
	char* pool
	int top

char* ism_new(ttf_ism* m):
	char* s = &m.pool[m.top * m.width]
	m.top = m.top + 1
	for i in range(m.width): s[i] = 0
	return s

void ism_drop(ttf_ism* m, int n):
	m.top = m.top - n

int ism_cat(ttf_ism* m, int i):
	return m.buffer.glyphs[m.start + i].icat

# out = src followed by one glyph of a category in mask.
void ism_sym(ttf_ism* m, char* src, char* out, int mask):
	for i in range(m.width): out[i] = 0
	for i in range(m.len):
		if (src[i] && ((ttf_icat_flag(ism_cat(m, i)) & mask) != 0)): out[i + 1] = 1

void ism_or(ttf_ism* m, char* dst, char* src):
	for i in range(m.width):
		if (src[i]): dst[i] = 1

void ism_copy(ttf_ism* m, char* dst, char* src):
	for i in range(m.width): dst[i] = src[i]

# s = s (X)?, in place.
void ism_opt(ttf_ism* m, char* s, int mask):
	char* t = ism_new(m)
	ism_sym(m, s, t, mask)
	ism_or(m, s, t)
	ism_drop(m, 1)

# s = s (X)*, in place.
void ism_star(ttf_ism* m, char* s, int mask):
	char* t = ism_new(m)
	char* u = ism_new(m)
	ism_copy(m, t, s)
	int grew = 1
	while (grew):
		ism_sym(m, t, u, mask)
		grew = 0
		for i in range(m.width):
			t[i] = 0
			if (u[i] && !s[i]):
				s[i] = 1
				t[i] = 1
				grew = 1
	ism_drop(m, 2)

int ism_f(int cat):
	return ttf_icat_flag(cat)

# n = ((ZWNJ? RS)? (N N?)?)
void ism_n(ttf_ism* m, char* src, char* out):
	char* t = ism_new(m)
	ism_copy(m, t, src)
	ism_opt(m, t, ism_f(ut_icat_zwnj))
	ism_copy(m, out, src)
	char* u = ism_new(m)
	ism_sym(m, t, u, ism_f(ut_icat_rs))
	ism_or(m, out, u)
	ism_sym(m, out, t, ism_f(ut_icat_n))
	ism_sym(m, t, u, ism_f(ut_icat_n))
	ism_or(m, out, t)
	ism_or(m, out, u)
	ism_drop(m, 2)

# cn = c ZWJ? n?
void ism_cn(ttf_ism* m, char* src, char* out):
	char* t = ism_new(m)
	ism_sym(m, src, t, ism_f(ut_icat_c) | ism_f(ut_icat_ra))
	ism_opt(m, t, ism_f(ut_icat_zwj))
	ism_n(m, t, out)
	ism_drop(m, 1)

# reph = (Ra H | Repha)
void ism_reph(ttf_ism* m, char* src, char* out):
	char* t = ism_new(m)
	ism_sym(m, src, t, ism_f(ut_icat_ra))
	ism_sym(m, t, out, ism_f(ut_icat_h))
	ism_sym(m, src, t, ism_f(ut_icat_repha))
	ism_or(m, out, t)
	ism_drop(m, 1)

int ism_sm():
	return ism_f(ut_icat_sm) | ism_f(ut_icat_smpst)

int ism_z():
	return ism_f(ut_icat_zwj) | ism_f(ut_icat_zwnj)

# matra_group = z* (M | sm? MPst) N? H?
void ism_matra_group(ttf_ism* m, char* src, char* out):
	char* t = ism_new(m)
	char* u = ism_new(m)
	ism_copy(m, t, src)
	ism_star(m, t, ism_z())
	ism_sym(m, t, out, ism_f(ut_icat_m))
	ism_opt(m, t, ism_sm())
	ism_sym(m, t, u, ism_f(ut_icat_mpst))
	ism_or(m, out, u)
	ism_opt(m, out, ism_f(ut_icat_n))
	ism_opt(m, out, ism_f(ut_icat_h))
	ism_drop(m, 2)

# syllable_tail = (z? sm sm? ZWNJ?)? (A | VD)*
void ism_syllable_tail(ttf_ism* m, char* src, char* out):
	char* t = ism_new(m)
	char* u = ism_new(m)
	ism_copy(m, t, src)
	ism_opt(m, t, ism_z())
	ism_sym(m, t, u, ism_sm())
	ism_opt(m, u, ism_sm())
	ism_opt(m, u, ism_f(ut_icat_zwnj))
	ism_copy(m, out, src)
	ism_or(m, out, u)
	ism_star(m, out, ism_f(ut_icat_a))
	ism_drop(m, 2)

# halant_group = z? H (ZWJ N?)?
void ism_halant_group(ttf_ism* m, char* src, char* out):
	char* t = ism_new(m)
	char* u = ism_new(m)
	ism_copy(m, t, src)
	ism_opt(m, t, ism_z())
	ism_sym(m, t, out, ism_f(ut_icat_h))
	ism_sym(m, out, u, ism_f(ut_icat_zwj))
	ism_opt(m, u, ism_f(ut_icat_n))
	ism_or(m, out, u)
	ism_drop(m, 2)

# complex_syllable_tail = (halant_group cn)* CM? (halant_group | H ZWNJ
# | matra_group*) syllable_tail
void ism_complex_tail(ttf_ism* m, char* src, char* out):
	char* acc = ism_new(m)
	char* frontier = ism_new(m)
	char* t = ism_new(m)
	char* u = ism_new(m)
	ism_copy(m, acc, src)
	ism_copy(m, frontier, src)
	int grew = 1
	while (grew):
		ism_halant_group(m, frontier, t)
		ism_cn(m, t, u)
		grew = 0
		for i in range(m.width):
			frontier[i] = 0
			if (u[i] && !acc[i]):
				acc[i] = 1
				frontier[i] = 1
				grew = 1
	ism_opt(m, acc, ism_f(ut_icat_cm))
	# final_halant_group
	char* fin = ism_new(m)
	ism_halant_group(m, acc, fin)
	ism_sym(m, acc, t, ism_f(ut_icat_h))
	ism_sym(m, t, u, ism_f(ut_icat_zwnj))
	ism_or(m, fin, u)
	# matra_group*
	ism_copy(m, frontier, acc)
	grew = 1
	while (grew):
		ism_matra_group(m, frontier, u)
		grew = 0
		for i in range(m.width):
			frontier[i] = 0
			if (u[i] && !acc[i]):
				acc[i] = 1
				frontier[i] = 1
				grew = 1
	ism_or(m, acc, fin)
	ism_syllable_tail(m, acc, out)
	ism_drop(m, 5)

int ism_longest(ttf_ism* m, char* s):
	int best = 0
	for i in range(m.width):
		if (s[i]): best = i
	return best

# Length and type of the syllable starting at m.start (Ragel's longest
# match, earlier rules winning ties).
int ism_match(ttf_ism* m, int* type):
	char* src = ism_new(m)
	char* t = ism_new(m)
	char* u = ism_new(m)
	char* out = ism_new(m)
	src[0] = 1
	int best = 0
	type[0] = ttf_syl_non_indic
	# consonant_syllable = (Repha | CS)? cn complex_syllable_tail
	ism_copy(m, t, src)
	ism_opt(m, t, ism_f(ut_icat_repha) | ism_f(ut_icat_cs))
	ism_cn(m, t, u)
	ism_complex_tail(m, u, out)
	int len = ism_longest(m, out)
	if (len > best):
		best = len
		type[0] = ttf_syl_consonant
	# vowel_syllable = reph? V n? (ZWJ | complex_syllable_tail)
	ism_reph(m, src, t)
	ism_or(m, t, src)
	ism_sym(m, t, u, ism_f(ut_icat_v))
	ism_n(m, u, t)
	ism_complex_tail(m, t, out)
	ism_sym(m, t, u, ism_f(ut_icat_zwj))
	ism_or(m, out, u)
	len = ism_longest(m, out)
	if (len > best):
		best = len
		type[0] = ttf_syl_vowel
	# standalone_cluster = ((Repha | CS)? PLACEHOLDER | reph? DOTTEDCIRCLE)
	# n? complex_syllable_tail
	ism_copy(m, t, src)
	ism_opt(m, t, ism_f(ut_icat_repha) | ism_f(ut_icat_cs))
	ism_sym(m, t, u, ism_f(ut_icat_placeholder))
	ism_reph(m, src, t)
	ism_or(m, t, src)
	ism_sym(m, t, out, ism_f(ut_icat_dottedcircle))
	ism_or(m, u, out)
	ism_n(m, u, t)
	ism_complex_tail(m, t, out)
	len = ism_longest(m, out)
	if (len > best):
		best = len
		type[0] = ttf_syl_standalone
	# symbol_cluster = Symbol N? syllable_tail
	ism_sym(m, src, t, ism_f(ut_icat_symbol))
	ism_opt(m, t, ism_f(ut_icat_n))
	ism_syllable_tail(m, t, out)
	len = ism_longest(m, out)
	if (len > best):
		best = len
		type[0] = ttf_syl_symbol
	# SMPst alone is a non-Indic cluster.
	if ((best < 1) && (ism_cat(m, 0) == ut_icat_smpst)):
		best = 1
		type[0] = ttf_syl_non_indic
	# broken_cluster = reph? n? complex_syllable_tail
	ism_reph(m, src, t)
	ism_or(m, t, src)
	ism_n(m, t, u)
	ism_complex_tail(m, u, out)
	len = ism_longest(m, out)
	if (len > best):
		best = len
		type[0] = ttf_syl_broken
	ism_drop(m, 4)
	if (best < 1):
		best = 1
		type[0] = ttf_syl_non_indic
	return best

# Number every glyph's syllable: serial * 16 + type. Returns whether a
# broken cluster was found.
int ttf_indic_find_syllables(otl_buffer* b):
	ttf_ism m
	m.buffer = b
	m.width = ttf_indic_window + 1
	m.pool = cast(char*, malloc(64 * m.width))
	m.top = 0
	int broken = 0
	int serial = 1
	int i = 0
	while (i < b.count):
		m.start = i
		m.len = b.count - i
		if (m.len > ttf_indic_window): m.len = ttf_indic_window
		m.top = 0
		int type = 0
		int len = ism_match(&m, &type)
		if (type == ttf_syl_broken): broken = 1
		for k in range(i, i + len): b.glyphs[k].syllable = serial * 16 + type
		serial = serial + 1
		i = i + len
	free(m.pool)
	return broken

# The end of the syllable starting at start.
int ttf_indic_syllable_end(otl_buffer* b, int start):
	int end = start + 1
	while ((end < b.count) && (b.glyphs[end].syllable == b.glyphs[start].syllable)): end = end + 1
	return end

# Dotted circles (U+25CC) open each broken cluster, after any repha.
void ttf_indic_dotted_circles(ttf_font* f, otl_buffer* b):
	int circle = ttf_glyph_id(f, 0x25cc)
	if (circle == 0): return
	int last = 0
	int i = 0
	while (i < b.count):
		int syllable = b.glyphs[i].syllable
		if ((syllable == last) || ((syllable & 15) != ttf_syl_broken)):
			i = i + 1
			continue
		last = syllable
		int at = i
		while ((at < b.count) && (b.glyphs[at].syllable == syllable) && (b.glyphs[at].icat == ut_icat_repha)): at = at + 1
		otl_buffer_insert_copy(b, at, i)
		otl_glyph* g = &b.glyphs[at]
		g.gid = circle
		g.cp = 0x25cc
		g.props_cp = 0x25cc
		g.icat = ut_icat_dottedcircle
		g.ipos = ut_ipos_end
		g.props = 0
		g.unicode_mark = 0
		g.subst = 0
		g.lig_id = 0
		g.lig_comp = 0
		# The circle keeps the cluster, mask and syllable of the cluster's
		# first glyph, which it was copied from.
		i = at + 1

# ---- buffer helpers ------------------------------------------------------

void ttf_indic_swap(otl_buffer* b, int x, int y):
	otl_glyph tmp
	otl_glyph_copy(&tmp, &b.glyphs[x])
	otl_glyph_copy(&b.glyphs[x], &b.glyphs[y])
	otl_glyph_copy(&b.glyphs[y], &tmp)

void ttf_indic_reverse(otl_buffer* b, int start, int end):
	int lo = start
	int hi = end - 1
	while (lo < hi):
		ttf_indic_swap(b, lo, hi)
		lo = lo + 1
		hi = hi - 1

# Move glyph from to position to, shifting the glyphs between.
void ttf_indic_move(otl_buffer* b, int from, int to):
	otl_glyph tmp
	otl_glyph_copy(&tmp, &b.glyphs[from])
	if (from < to):
		for k in range(from, to): otl_glyph_copy(&b.glyphs[k], &b.glyphs[k + 1])
	else:
		int k = from
		while (k > to):
			otl_glyph_copy(&b.glyphs[k], &b.glyphs[k - 1])
			k = k - 1
	otl_glyph_copy(&b.glyphs[to], &tmp)

int ttf_indic_would(ttf_indic_plan* p, int32* lookups, int count, int g0, int g1, int g2, int n):
	int32[3] glyphs
	glyphs[0] = g0
	glyphs[1] = g1
	glyphs[2] = g2
	return otl_would_substitute(p.font, lookups, count, &glyphs[0], n, p.zero_context)

# HarfBuzz's consonant_position_from_face: below-base when blwf or vatu
# would form with the virama on either side, post-base for pstf or pref,
# else base.
int ttf_indic_consonant_position(ttf_indic_plan* p, int consonant):
	int v = p.virama_glyph
	if (ttf_indic_would(p, p.blwf, p.blwf_count, v, consonant, 0, 2) || ttf_indic_would(p, p.blwf, p.blwf_count, consonant, v, 0, 2) || ttf_indic_would(p, p.vatu, p.vatu_count, v, consonant, 0, 2) || ttf_indic_would(p, p.vatu, p.vatu_count, consonant, v, 0, 2)): return ut_ipos_below_c
	if (ttf_indic_would(p, p.pstf, p.pstf_count, v, consonant, 0, 2) || ttf_indic_would(p, p.pstf, p.pstf_count, consonant, v, 0, 2)): return ut_ipos_post_c
	if (ttf_indic_would(p, p.pref, p.pref_count, v, consonant, 0, 2) || ttf_indic_would(p, p.pref, p.pref_count, consonant, v, 0, 2)): return ut_ipos_post_c
	return ut_ipos_base_c

# ---- initial reordering --------------------------------------------------

void ttf_indic_initial_consonant(ttf_indic_plan* p, otl_buffer* b, int start, int end):
	otl_glyph* info = b.glyphs
	# Kannada Ra,H,ZWJ behaves like Ra,ZWJ,H.
	if ((p.script == ttf_indic_knda) && (start + 3 <= end) && ttf_indic_is_one_of(&info[start], ttf_icat_flag(ut_icat_ra)) && ttf_indic_is_one_of(&info[start + 1], ttf_icat_flag(ut_icat_h)) && ttf_indic_is_one_of(&info[start + 2], ttf_icat_flag(ut_icat_zwj))):
		otl_merge_clusters(b, start + 1, start + 3)
		ttf_indic_swap(b, start + 1, start + 2)
	# 1. Find the base consonant.
	int base = end
	int has_reph = 0
	int limit = start
	int implicit = (p.reph_mode == ttf_reph_implicit) && (start + 3 <= end) && !ttf_indic_is_joiner(&info[start + 2])
	int explicit = (p.reph_mode == ttf_reph_explicit) && (start + 3 <= end) && (info[start + 2].icat == ut_icat_zwj)
	if ((p.mask_rphf != 0) && (start + 3 <= end) && (implicit || explicit)):
		int third = 0
		if (p.reph_mode == ttf_reph_explicit): third = info[start + 2].gid
		if (ttf_indic_would(p, p.rphf, p.rphf_count, info[start].gid, info[start + 1].gid, third, 2) || ((p.reph_mode == ttf_reph_explicit) && ttf_indic_would(p, p.rphf, p.rphf_count, info[start].gid, info[start + 1].gid, third, 3))):
			limit = limit + 2
			while ((limit < end) && ttf_indic_is_joiner(&info[limit])): limit = limit + 1
			base = start
			has_reph = 1
	else if ((p.reph_mode == ttf_reph_log_repha) && (info[start].icat == ut_icat_repha)):
		limit = limit + 1
		while ((limit < end) && ttf_indic_is_joiner(&info[limit])): limit = limit + 1
		base = start
		has_reph = 1
	int i = end
	int seen_below = 0
	while (1):
		i = i - 1
		if (ttf_indic_is_consonant(&info[i])):
			if ((info[i].ipos != ut_ipos_below_c) && ((info[i].ipos != ut_ipos_post_c) || seen_below)):
				base = i
				break
			if (info[i].ipos == ut_ipos_below_c): seen_below = 1
			base = i
		else:
			# A ZWJ after a halant stops the search (an explicit half form).
			if ((start < i) && (info[i].icat == ut_icat_zwj) && (info[i - 1].icat == ut_icat_h)): break
		if (i <= limit): break
	# With no other consonant, the Ra is the base and forms no reph.
	if (has_reph && (base == start) && (limit - base <= 2)): has_reph = 0
	# Reorder characters.
	for k in range(start, base):
		if (info[k].ipos > ut_ipos_pre_c): info[k].ipos = ut_ipos_pre_c
	if (base < end): info[base].ipos = ut_ipos_base_c
	if (has_reph): info[start].ipos = ut_ipos_ra_to_become_reph
	# Old-spec tags move the first post-base halant after the last
	# consonant (except over another halant in Kannada).
	if (p.old_spec):
		int no_double = p.script == ttf_indic_knda
		for k in range(base + 1, end):
			if (info[k].icat == ut_icat_h):
				int j = end - 1
				while (j > k):
					if (ttf_indic_is_consonant(&info[j]) || (no_double && (info[j].icat == ut_icat_h))): break
					j = j - 1
				if ((info[j].icat != ut_icat_h) && (j > k)): ttf_indic_move(b, k, j)
				break
	# Attach misc marks to the previous character to move with it.
	int last_pos = ut_ipos_start
	int misc = ttf_indic_joiner_flags() | ttf_icat_flag(ut_icat_n) | ttf_icat_flag(ut_icat_rs) | ttf_icat_flag(ut_icat_cm) | ttf_icat_flag(ut_icat_h)
	for k in range(start, end):
		if ((ttf_icat_flag(info[k].icat) & misc) != 0):
			info[k].ipos = last_pos
			if ((info[k].icat == ut_icat_h) && (info[k].ipos == ut_ipos_pre_m)):
				# A halant does not move with a left matra.
				int j = k
				while (j > start):
					if (info[j - 1].ipos != ut_ipos_pre_m):
						info[k].ipos = info[j - 1].ipos
						break
					j = j - 1
		else if (info[k].ipos != ut_ipos_smvd):
			if ((info[k].icat == ut_icat_mpst) && (k > start) && (info[k - 1].icat == ut_icat_sm)): info[k - 1].ipos = info[k].ipos
			last_pos = info[k].ipos
	# Post-base consonants own what comes before them since the last
	# consonant or matra.
	int last = base
	for k in range(base + 1, end):
		if (ttf_indic_is_consonant(&info[k])):
			for j in range(last + 1, k):
				if (info[j].ipos < ut_ipos_smvd): info[j].ipos = info[k].ipos
			last = k
		else if ((ttf_icat_flag(info[k].icat) & ttf_indic_matra_flags()) != 0): last = k
	# Stable sort by position; like HarfBuzz, the syllable field tracks
	# where each glyph came from meanwhile.
	int n = end - start
	int syllable = info[start].syllable
	for k in range(start, end): info[k].syllable = k - start
	for k in range(start + 1, end):
		int j = k
		while ((j > start) && (info[j - 1].ipos > info[j].ipos)):
			ttf_indic_swap(b, j - 1, j)
			j = j - 1
	# Find the base again; flip a run of left matras.
	int first_left = end
	int last_left = end
	base = end
	for k in range(start, end):
		if (info[k].ipos == ut_ipos_base_c):
			base = k
			break
		if (info[k].ipos == ut_ipos_pre_m):
			if (first_left == end): first_left = k
			last_left = k
	if (first_left < last_left):
		ttf_indic_reverse(b, first_left, last_left + 1)
		int at = first_left
		for j in range(first_left, last_left + 1):
			if ((ttf_icat_flag(info[j].icat) & ttf_indic_matra_flags()) != 0):
				ttf_indic_reverse(b, at, j + 1)
				at = j + 1
	# Merge the clusters of whatever moved across or after the base.
	if (p.old_spec || (n > 127)): otl_merge_clusters(b, base, end)
	else:
		for k in range(base, end):
			if (info[k].syllable >= 0):
				int lo = k
				int hi = k
				int j = start + info[k].syllable
				while (j != k):
					if (j < lo): lo = j
					if (j > hi): hi = j
					int next = start + info[j].syllable
					info[j].syllable = -1
					j = next
				if (lo < base): lo = base
				otl_merge_clusters(b, lo, hi + 1)
	for k in range(start, end): info[k].syllable = syllable
	# Feature masks.
	int r = start
	while ((r < end) && (info[r].ipos == ut_ipos_ra_to_become_reph)):
		info[r].mask = info[r].mask | p.mask_rphf
		r = r + 1
	int mask = p.mask_half
	if (!p.old_spec && (p.blwf_mode == ttf_blwf_pre_and_post)): mask = mask | p.mask_blwf
	for j in range(start, base): info[j].mask = info[j].mask | mask
	mask = p.mask_blwf | p.mask_abvf | p.mask_pstf
	for j in range(base + 1, end): info[j].mask = info[j].mask | mask
	# Old-spec Devanagari eyelash Ra takes the below form.
	if (p.old_spec && (p.script == ttf_indic_deva)):
		for j in range(start, base - 1):
			if ((info[j].icat == ut_icat_ra) && (info[j + 1].icat == ut_icat_h) && ((j + 2 == base) || (info[j + 2].icat != ut_icat_zwj))):
				info[j].mask = info[j].mask | p.mask_blwf
				info[j + 1].mask = info[j + 1].mask | p.mask_blwf
	# Mark a Halant,Ra pair for pre-base reordering.
	if ((p.mask_pref != 0) && (base + 2 < end)):
		for j in range(base + 1, end - 1):
			if (ttf_indic_would(p, p.pref, p.pref_count, info[j].gid, info[j + 1].gid, 0, 2)):
				info[j].mask = info[j].mask | p.mask_pref
				info[j + 1].mask = info[j + 1].mask | p.mask_pref
				break
	# A ZWNJ disables half forms back to the previous consonant.
	for j in range(start + 1, end):
		if (ttf_indic_is_joiner(&info[j])):
			int non_joiner = info[j].icat == ut_icat_zwnj
			int x = j
			while (1):
				x = x - 1
				if (non_joiner): info[x].mask = info[x].mask & ~p.mask_half
				if ((x <= start) || ttf_indic_is_consonant(&info[x])): break

void ttf_indic_initial(ttf_indic_plan* p, otl_buffer* b):
	if (p.virama_glyph != 0):
		for i in range(b.count):
			if (b.glyphs[i].ipos == ut_ipos_base_c): b.glyphs[i].ipos = ttf_indic_consonant_position(p, b.glyphs[i].gid)
	int start = 0
	while (start < b.count):
		int end = ttf_indic_syllable_end(b, start)
		int type = b.glyphs[start].syllable & 15
		if ((type != ttf_syl_symbol) && (type != ttf_syl_non_indic)): ttf_indic_initial_consonant(p, b, start, end)
		start = end

# ---- final reordering ----------------------------------------------------

# General categories Cf, Cn, Co, Cs, letters and marks (HarfBuzz's
# FORMAT..NON_SPACING_MARK range): no word start before them.
int ttf_indic_joins_word(otl_glyph* g):
	if (g.cp < 0): return 1
	int cat = ut_category(g.cp)
	# Cf, Cs and Co are the last three category numbers.
	return (cat <= ut_cat_me) || (cat >= ut_cat_cf)

void ttf_indic_final_syllable(ttf_indic_plan* p, otl_buffer* b, int start, int end):
	otl_glyph* info = b.glyphs
	# A virama glyph that ligated and multiplied back out is a halant.
	if (p.virama_glyph != 0):
		for i in range(start, end):
			if ((info[i].gid == p.virama_glyph) && ttf_indic_ligated(&info[i]) && ((info[i].subst & otl_subst_multiplied) != 0)):
				info[i].icat = ut_icat_h
				info[i].subst = info[i].subst & ~(otl_subst_ligated | otl_subst_multiplied)
	int try_pref = p.mask_pref != 0
	# Find the base again.
	int base = start
	while (base < end):
		if (info[base].ipos >= ut_ipos_base_c):
			if (try_pref && (base + 1 < end)):
				for i in range(base + 1, end):
					if ((info[i].mask & p.mask_pref) != 0):
						if (!(((info[i].subst & otl_subst_substituted) != 0) && ttf_indic_ligated_and_didnt_multiply(&info[i]))):
							# A pref candidate that formed nothing: the base is here.
							base = i
							while ((base < end) && ttf_indic_is_halant(&info[base])): base = base + 1
							if (base < end): info[base].ipos = ut_ipos_base_c
							try_pref = 0
						break
				if (base == end): break
			# Malayalam skips unformed below (not post) forms.
			if (p.script == ttf_indic_mlym):
				int x = base + 1
				while (x < end):
					while ((x < end) && ttf_indic_is_joiner(&info[x])): x = x + 1
					if ((x == end) || !ttf_indic_is_halant(&info[x])): break
					x = x + 1
					while ((x < end) && ttf_indic_is_joiner(&info[x])): x = x + 1
					if ((x < end) && ttf_indic_is_consonant(&info[x]) && (info[x].ipos == ut_ipos_below_c)):
						base = x
						info[base].ipos = ut_ipos_base_c
					x = x + 1
			if ((start < base) && (info[base].ipos > ut_ipos_base_c)): base = base - 1
			break
		base = base + 1
	if ((base == end) && (start < base) && ttf_indic_is_one_of(&info[base - 1], ttf_icat_flag(ut_icat_zwj))): base = base - 1
	if (base < end):
		while ((start < base) && ttf_indic_is_one_of(&info[base], ttf_icat_flag(ut_icat_n) | ttf_icat_flag(ut_icat_h))): base = base - 1
	# Pre-base matras move after the last standalone halant.
	int mh = ttf_indic_matra_flags() | ttf_icat_flag(ut_icat_h)
	if ((start + 1 < end) && (start < base)):
		int new_pos = base - 1
		if (base == end): new_pos = base - 2
		if ((p.script != ttf_indic_mlym) && (p.script != ttf_indic_taml)):
			int searching = 1
			while (searching):
				searching = 0
				while ((new_pos > start) && !ttf_indic_is_one_of(&info[new_pos], mh)): new_pos = new_pos - 1
				if (ttf_indic_is_halant(&info[new_pos]) && (info[new_pos].ipos != ut_ipos_pre_m)):
					# A ZWJ after the halant keeps the matra before it.
					if ((new_pos + 1 < end) && (info[new_pos + 1].icat == ut_icat_zwj) && (new_pos > start)):
						new_pos = new_pos - 1
						searching = 1
				else: new_pos = start
		if ((start < new_pos) && (info[new_pos].ipos != ut_ipos_pre_m)):
			int at = new_pos
			while (at > start):
				if (info[at - 1].ipos == ut_ipos_pre_m):
					int old_pos = at - 1
					if ((old_pos < base) && (base <= new_pos)): base = base - 1
					ttf_indic_move(b, old_pos, new_pos)
					otl_merge_clusters(b, new_pos, min(end, base + 1))
					new_pos = new_pos - 1
				at = at - 1
		else:
			for i in range(start, base):
				if (info[i].ipos == ut_ipos_pre_m):
					otl_merge_clusters(b, i, min(end, base + 1))
					break
	# Reorder reph: an encoded repha that did not ligate, or a Ra,H that
	# formed one.
	if ((start + 1 < end) && (info[start].ipos == ut_ipos_ra_to_become_reph) && ((info[start].icat == ut_icat_repha) != ttf_indic_ligated_and_didnt_multiply(&info[start]))):
		int new_reph = -1
		int step5 = p.reph_pos == ut_ipos_after_post
		# 2. After the first explicit halant between the reph and the base.
		if (!step5):
			new_reph = start + 1
			while ((new_reph < base) && !ttf_indic_is_halant(&info[new_reph])): new_reph = new_reph + 1
			if ((new_reph < base) && ttf_indic_is_halant(&info[new_reph])):
				if ((new_reph + 1 < base) && ttf_indic_is_joiner(&info[new_reph + 1])): new_reph = new_reph + 1
			else: new_reph = -1
		# 3. After the main consonant.
		if (!step5 && (new_reph < 0) && (p.reph_pos == ut_ipos_after_main)):
			new_reph = base
			while ((new_reph + 1 < end) && (info[new_reph + 1].ipos <= ut_ipos_after_main)): new_reph = new_reph + 1
			if (new_reph >= end): new_reph = -1
		# 4. Before the first post-base form, matra or modifier.
		if (!step5 && (new_reph < 0) && (p.reph_pos == ut_ipos_after_sub)):
			new_reph = base
			while ((new_reph + 1 < end) && (info[new_reph + 1].ipos != ut_ipos_post_c) && (info[new_reph + 1].ipos != ut_ipos_after_post) && (info[new_reph + 1].ipos != ut_ipos_smvd)): new_reph = new_reph + 1
			if (new_reph >= end): new_reph = -1
		# 5. As step 2.
		if (new_reph < 0):
			new_reph = start + 1
			while ((new_reph < base) && !ttf_indic_is_halant(&info[new_reph])): new_reph = new_reph + 1
			if ((new_reph < base) && ttf_indic_is_halant(&info[new_reph])):
				if ((new_reph + 1 < base) && ttf_indic_is_joiner(&info[new_reph + 1])): new_reph = new_reph + 1
			else: new_reph = -1
		# 6. The end of the syllable, before vedic signs.
		if (new_reph < 0):
			new_reph = end - 1
			while ((new_reph > start) && (info[new_reph].ipos == ut_ipos_smvd)): new_reph = new_reph - 1
			# After a Matra,Halant the reph goes before the halant. (As in
			# HarfBuzz, each matra steps back once, and the scan stops
			# at the moving position.)
			if (ttf_indic_is_halant(&info[new_reph])):
				int m = base + 1
				while (m < new_reph):
					if ((ttf_icat_flag(info[m].icat) & ttf_indic_matra_flags()) != 0): new_reph = new_reph - 1
					m = m + 1
		otl_merge_clusters(b, start, new_reph + 1)
		ttf_indic_move(b, start, new_reph)
		if ((start < base) && (base <= new_reph)): base = base - 1
	# Reorder a formed pre-base-reordering consonant.
	if (try_pref && (base + 1 < end)):
		for i in range(base + 1, end):
			if ((info[i].mask & p.mask_pref) != 0):
				if (ttf_indic_ligated_and_didnt_multiply(&info[i])):
					int new_pos = base
					if ((p.script != ttf_indic_mlym) && (p.script != ttf_indic_taml)):
						while ((new_pos > start) && !ttf_indic_is_one_of(&info[new_pos - 1], mh)): new_pos = new_pos - 1
					if ((new_pos > start) && ttf_indic_is_halant(&info[new_pos - 1])):
						if ((new_pos < end) && ttf_indic_is_joiner(&info[new_pos])): new_pos = new_pos + 1
					otl_merge_clusters(b, new_pos, i + 1)
					ttf_indic_move(b, i, new_pos)
					if ((new_pos <= base) && (base < i)): base = base + 1
				break
	# init applies to a left matra at a word start.
	if (info[start].ipos == ut_ipos_pre_m):
		if ((start == 0) || !ttf_indic_joins_word(&info[start - 1])): info[start].mask = info[start].mask | p.mask_init

void ttf_indic_final(ttf_indic_plan* p, otl_buffer* b):
	int start = 0
	while (start < b.count):
		int end = ttf_indic_syllable_end(b, start)
		ttf_indic_final_syllable(p, b, start, end)
		start = end

# ---- driver ----------------------------------------------------------------

void ttf_indic_stage(ttf_indic_plan* p, otl_buffer* b, int* tags, int* masks, int n):
	otl_apply_stage(p.font, b, otl_gsub, p.scripts, p.script_count, p.language, tags, masks, n, 0)

# One basic feature as its own stage (manual joiners, per syllable).
void ttf_indic_basic(ttf_indic_plan* p, otl_buffer* b, char* tag, int mask):
	if (mask == 0): return
	int[1] tags
	int[1] masks
	tags[0] = otl_tag(tag)
	masks[0] = mask | otl_mask_hb | otl_mask_manual_joiners | otl_mask_per_syllable
	ttf_indic_stage(p, b, &tags[0], &masks[0], 1)

# The Indic GSUB pipeline over b: glyphs carry ttf_shape's global mask
# (bit 0). liga: whether clig applies (liga itself is off for Indic).
void ttf_indic_shape(ttf_indic_plan* p, otl_buffer* b, int liga):
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		g.icat = ut_icat_x
		g.ipos = ut_ipos_end
		if (g.cp >= 0):
			g.icat = ut_indic_category(g.cp)
			g.ipos = ut_indic_position(g.cp)
	int[12] tags
	int[12] masks
	tags[0] = otl_tag(c"rvrn")
	masks[0] = 1 | otl_mask_hb
	ttf_indic_stage(p, b, &tags[0], &masks[0], 1)
	otl_apply_common(p.font, b, p.scripts, p.script_count, p.language, 0)
	int broken = ttf_indic_find_syllables(b)
	tags[0] = otl_tag(c"locl")
	tags[1] = otl_tag(c"ccmp")
	masks[0] = 1 | otl_mask_hb | otl_mask_per_syllable
	masks[1] = masks[0]
	ttf_indic_stage(p, b, &tags[0], &masks[0], 2)
	if (broken): ttf_indic_dotted_circles(p.font, b)
	ttf_indic_initial(p, b)
	ttf_indic_basic(p, b, c"nukt", 1)
	ttf_indic_basic(p, b, c"akhn", 1)
	ttf_indic_basic(p, b, c"rphf", p.mask_rphf)
	ttf_indic_basic(p, b, c"rkrf", 1)
	ttf_indic_basic(p, b, c"pref", p.mask_pref)
	ttf_indic_basic(p, b, c"blwf", p.mask_blwf)
	ttf_indic_basic(p, b, c"abvf", p.mask_abvf)
	ttf_indic_basic(p, b, c"half", p.mask_half)
	ttf_indic_basic(p, b, c"pstf", p.mask_pstf)
	ttf_indic_basic(p, b, c"vatu", 1)
	ttf_indic_basic(p, b, c"cjct", 1)
	ttf_indic_final(p, b)
	int flags = otl_mask_hb | otl_mask_manual_joiners | otl_mask_per_syllable
	char* names = c"initpresabvsblwspstshalnrligcaltrcltclig"
	int n = 0
	for k in range(10):
		if ((k == 9) && !liga): continue
		tags[n] = otl_tag(&names[k * 4])
		if (k == 0): masks[n] = p.mask_init | flags
		else if (k < 6): masks[n] = 1 | flags
		else: masks[n] = 1 | otl_mask_hb
		if ((k == 0) && (p.mask_init == 0)): continue
		n = n + 1
	ttf_indic_stage(p, b, &tags[0], &masks[0], n)
