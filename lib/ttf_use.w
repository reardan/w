/*
lib.ttf_use: the Universal Shaping Engine behind lib.ttf_shape (issue
#825), a port of HarfBuzz 15's hb-ot-shaper-use.

	ttf_use_shape(f, b, scripts, script_count, language, code, forms, rtl, liga)

runs the whole GSUB pipeline of a USE run over a normalized buffer: rvrn;
syllable segmentation (HarfBuzz's Ragel cluster machine, re-expressed as
a longest-match set simulation like lib.ttf_indic's); the rphf and
topographical (isol/init/medi/fina, or Arabic joining) masks; the
per-syllable locl/ccmp/nukt/akhn stage; rphf with the repha recorded,
pref with the pre-base form recorded as VPre; the rkrf/abvf/blwf/half/
pstf/vatu/cjct stage; dotted circles for broken clusters; reordering
(repha towards the end before the first post-base glyph, pre-base vowels
and pre-base forms to the start or after the last halant); the
topographical features; and the presentation features (abvs blws haln
pres psts with rlig calt clig liga rclt).

HarfBuzz sends the USE scripts (Tibetan, Sinhala, Javanese, Balinese,
Tai Tham, Batak, Mongolian, ...) here unless the font's GSUB script
choice falls back to DFLT or latn, and also the nine Indic scripts when
the chosen tag is a 'dev3'-style one (ttf_use_applies). The categories
come from lib.ttf_use_data, generated from HarfBuzz 15.0.0's table
(tools/unicode/use_categories.txt). Syllables longer than
ttf_use_window characters are split.
*/
import lib.lib
import lib.ttf
import lib.ttf_indic
import lib.ttf_layout
import lib.ttf_use_data
import lib.unicode_text

# USE categories, numbered as in HarfBuzz's hb-ot-shaper-use-machine.rl.
const int ttf_use_o = 0
const int ttf_use_b = 1
const int ttf_use_n = 4
const int ttf_use_gb = 5
const int ttf_use_cgj = 6
const int ttf_use_sub = 11
const int ttf_use_h = 12
const int ttf_use_hn = 13
const int ttf_use_zwnj = 14
const int ttf_use_wj = 16
const int ttf_use_r = 18
const int ttf_use_vpre = 22
const int ttf_use_vmpre = 23
const int ttf_use_fabv = 24
const int ttf_use_fblw = 25
const int ttf_use_fpst = 26
const int ttf_use_mabv = 27
const int ttf_use_mblw = 28
const int ttf_use_mpst = 29
const int ttf_use_mpre = 30
const int ttf_use_cmabv = 31
const int ttf_use_cmblw = 32
const int ttf_use_vabv = 33
const int ttf_use_vblw = 34
const int ttf_use_vpst = 35
const int ttf_use_vmabv = 37
const int ttf_use_vmblw = 38
const int ttf_use_vmpst = 39
const int ttf_use_smabv = 41
const int ttf_use_smblw = 42
const int ttf_use_cs = 43
const int ttf_use_is = 44
const int ttf_use_fmabv = 45
const int ttf_use_fmblw = 46
const int ttf_use_fmpst = 47
const int ttf_use_sk = 48
const int ttf_use_g = 49
const int ttf_use_j = 50
const int ttf_use_sb = 51
const int ttf_use_se = 52
const int ttf_use_hvm = 53
const int ttf_use_hm = 54
const int ttf_use_hr = 55
const int ttf_use_rk = 56

# Syllable types (low four bits of otl_glyph.syllable), HarfBuzz's
# use_syllable_type_t.
const int ttf_use_virama_terminated = 0
const int ttf_use_sakot_terminated = 1
const int ttf_use_standard = 2
const int ttf_use_number_joiner_terminated = 3
const int ttf_use_numeral = 4
const int ttf_use_symbol = 5
const int ttf_use_hieroglyph = 6
const int ttf_use_broken = 7
const int ttf_use_non_cluster = 8

# Feature masks; bit 0 is ttf_shape's global mask.
const int ttf_use_mask_rphf = 32
const int ttf_use_mask_isol = 64
const int ttf_use_mask_init = 128
const int ttf_use_mask_medi = 256
const int ttf_use_mask_fina = 512

# Longest syllable the segmenter considers.
const int ttf_use_window = 128

# The USE category of cp (ttf_use_*).
int ttf_use_category(int cp):
	if ((cp < 0) || (cp > 1114111)): return ttf_use_o
	return ut_range_value(ttd_use(), ttd_use_count(), cp)

int ttf_use_code_in(char* code, char* codes):
	int n = strlen(codes) / 4
	for k in range(n):
		if ((code[0] == codes[k * 4]) && (code[1] == codes[k * 4 + 1]) && (code[2] == codes[k * 4 + 2]) && (code[3] == codes[k * 4 + 3])): return 1
	return 0

# The scripts HarfBuzz 15's hb_ot_shaper_categorize sends to USE (those
# lib.unicode_text knows; later ones are Unknown there).
int ttf_use_script(char* code):
	char* a = c"TibtMongSinhBuhdHanoTglgTagbLimbTaleBugiKharSyloTfngBaliNkooPhagChamKaliLepcRjngSaurSundEgypJavaKthiMteiLanaTavtBatkBrahMandCakmPlrdShrdTakr"
	char* b = c"DuplGranKhojSindMahjManiModiHmngPhlpSiddTirhAhomMultAdlmBhksMarcNewaGonmSoyoZanbDogrGongRohgMakaMedfSogoSogdElymNandHmnpWchoChrsDiakKitsYezi"
	char* tail = c"CpmnOugrTnsaTotoVithKawiNagmGaraGukhKraiOnaoSunuTodrTutgBerfSidtTayoTolsJurcPcunSeal"
	return ttf_use_code_in(code, a) || ttf_use_code_in(code, b) || ttf_use_code_in(code, tail)

# Scripts whose USE shaping takes Arabic joining masks (HarfBuzz's
# has_arabic_joining).
int ttf_use_joining_script(char* code):
	return ttf_use_code_in(code, c"AdlmChrsRohgMandManiMongNkooOugrPhagPhlpSogd")

# Like HarfBuzz: a USE script shapes here unless the font's GSUB script
# choice falls back to DFLT or latn; an Indic script does when the chosen
# tag is a 'dev3'-style one.
int ttf_use_applies(ttf_font* f, char* code, char* scripts, int script_count):
	int chosen = ttf_indic_chosen_script(f, scripts, script_count)
	if (ttf_indic_script(code) != 0): return (chosen >= 0) && (scripts[chosen * 4 + 3] == '3')
	if (!ttf_use_script(code)): return 0
	if (chosen < 0): return 1
	int tag = otl_tag(&scripts[chosen * 4])
	return (tag != otl_tag(c"DFLT")) && (tag != otl_tag(c"latn"))

# HarfBuzz's vowel constraints for the USE scripts other than the Indic
# ones (lib.ttf_shape's ttf_indic_vowel_constraint has those): whether a
# dotted circle goes between a and b.
int ttf_use_vowel_constraint(char* code, int a, int b):
	if (ttf_use_code_in(code, c"Sinh")):
		if (a == 0x0d85): return (b == 0x0dcf) || (b == 0x0dd0) || (b == 0x0dd1)
		if ((a == 0x0d8b) || (a == 0x0d8f) || (a == 0x0d94)): return b == 0x0ddf
		if (a == 0x0d8d): return b == 0x0dd8
		if (a == 0x0d91): return (b == 0x0dca) || (b == 0x0dd9) || (b == 0x0dda) || (b == 0x0ddc) || (b == 0x0ddd) || (b == 0x0dde)
		return 0
	if (ttf_use_code_in(code, c"Brah")):
		if (a == 0x11005): return b == 0x11038
		if (a == 0x1100b): return b == 0x1103e
		if (a == 0x1100f): return b == 0x11042
		return 0
	if (ttf_use_code_in(code, c"Khoj")):
		if (a == 0x11200): return (b == 0x1122c) || (b == 0x11231) || (b == 0x11233)
		if (a == 0x11206): return b == 0x1122c
		if (a == 0x1122c): return (b == 0x11230) || (b == 0x11231)
		if (a == 0x11240): return b == 0x1122e
		return 0
	if (ttf_use_code_in(code, c"Sind")):
		if (a == 0x112b0): return (b == 0x112e0) || ((b >= 0x112e5) && (b <= 0x112e8))
		return 0
	if (ttf_use_code_in(code, c"Tirh")):
		if (a == 0x11481): return b == 0x114b0
		if ((a == 0x1148b) || (a == 0x1148d)): return b == 0x114ba
		if (a == 0x114aa): return (b == 0x114b5) || (b == 0x114b6)
		return 0
	if (ttf_use_code_in(code, c"Modi")):
		if ((a == 0x11600) || (a == 0x11601)): return (b == 0x11639) || (b == 0x1163a)
		return 0
	if (ttf_use_code_in(code, c"Takr")):
		if (a == 0x11680): return (b == 0x116ad) || (b == 0x116b4) || (b == 0x116b5)
		if (a == 0x11686): return b == 0x116b2
		return 0
	return 0

# HarfBuzz's normalizer decomposition without short circuit (USE has no
# decompose override): cp fully decomposed whenever the font has the
# parts, even when it has cp itself. Appends to out; returns the count,
# or 0 when cp stays whole.
int ttf_use_decompose(ttf_font* f, int cp, int32* out, int depth):
	int a = 0
	int b = 0
	if ((depth > 4) || !ut_decompose(cp, &a, &b)): return 0
	if ((b != 0) && (ttf_glyph_id(f, b) == 0)): return 0
	int n = ttf_use_decompose(f, a, out, depth + 1)
	if ((n == 0) && (ttf_glyph_id(f, a) != 0)):
		out[0] = a
		n = 1
	if (n == 0): return 0
	if (b != 0):
		out[n] = b
		n = n + 1
	return n

# HarfBuzz's modified combining class, which lib.ttf_shape's
# ttf_modified_ccc also uses: Hebrew points renumbered so dagesh, the
# shin and sin dots and the like sort first, Arabic shadda before the
# other harakat, the Telugu length marks (84, 91) before the virama,
# Thai SARA U/UU (103) before PHINTHU, Tibetan U before I; Tai Tham SAKOT
# and Tibetan PADMA last, Tibetan TSA-PHRU before U.
int ttf_use_modified_ccc(int cp):
	if ((cp == 0x1a60) || (cp == 0x0fc6)): return 254
	if (cp == 0x0f39): return 127
	int ccc = ut_combining_class(cp)
	if ((ccc >= 10) && (ccc <= 26)):
		char* hebrew = c"\x16\x0f\x10\x11\x17\x12\x13\x14\x15\x0e\x18\x0c\x19\x0d\x0a\x0b\x1a"
		return hebrew[ccc - 10]
	if ((ccc >= 27) && (ccc <= 32)): return ccc + 1
	if (ccc == 33): return 27
	if (ccc == 84): return 4
	if (ccc == 91): return 5
	if (ccc == 103): return 3
	if (ccc == 130): return 132
	if (ccc == 132): return 131
	return ccc

int ttf_use_is_mark_category(int category):
	return (category == ut_cat_mn) || (category == ut_cat_mc) || (category == ut_cat_me)

# HarfBuzz's all_simple: no character after the first is a mark (Mn, Mc,
# Me), so the normalizer neither reorders nor recomposes.
int ttf_use_all_simple(int32* cps, int count):
	for i in range(1, count):
		if (ttf_use_is_mark_category(ut_category(cps[i]))): return 0
	return 1

# HarfBuzz's recomposition with compose_use: a mark composes into the
# last starter when nothing between them has an equal or higher
# combining class, the starter is not itself a mark (split matras stay
# split) and the font has the composite.
void ttf_use_recompose(ttf_font* f, otl_buffer* b):
	if (b.count == 0): return
	int starter = 0
	int i = 1
	while (i < b.count):
		otl_glyph* g = &b.glyphs[i]
		int mark = (g.cp >= 0) && ttf_use_is_mark_category(ut_category(g.cp))
		otl_glyph* s = &b.glyphs[starter]
		if (mark && (s.cp >= 0) && ((starter == i - 1) || (ttf_use_modified_ccc(b.glyphs[i - 1].cp) < ttf_use_modified_ccc(g.cp)))):
			int composed = -1
			if (!ttf_use_is_mark_category(ut_category(s.cp))): composed = ut_compose(s.cp, g.cp)
			int gid = 0
			if (composed >= 0): gid = ttf_glyph_id(f, composed)
			if (gid != 0):
				if (g.cluster < s.cluster): s.cluster = g.cluster
				s.cp = composed
				s.gid = gid
				s.unicode_mark = ut_is_nonspacing_mark(composed)
				otl_buffer_delete(b, i)
				continue
		if ((g.cp < 0) || (ttf_use_modified_ccc(g.cp) == 0)): starter = i
		i = i + 1

# ---- the cluster machine -------------------------------------------------

# HarfBuzz's Ragel machine as a set simulation over the filtered
# categories (see ttf_use_find_syllables): each grammar rule maps the set
# of positions it may start at to the set it may end at. A set is a byte
# per position.
struct ttf_usm:
	int32* cats
	int len
	int width
	char* pool
	int top

char* usm_new(ttf_usm* m):
	char* s = &m.pool[m.top * m.width]
	m.top = m.top + 1
	for i in range(m.width): s[i] = 0
	return s

void usm_drop(ttf_usm* m, int n):
	m.top = m.top - n

void usm_copy(ttf_usm* m, char* dst, char* src):
	for i in range(m.width): dst[i] = src[i]

void usm_or(ttf_usm* m, char* dst, char* src):
	for i in range(m.width):
		if (src[i]): dst[i] = 1

# out = src followed by one symbol of category a, b, c or d (-1: unused).
void usm_sym(ttf_usm* m, char* src, char* out, int a, int b, int c, int d):
	for i in range(m.width): out[i] = 0
	for i in range(m.len):
		if (src[i]):
			int cat = m.cats[i]
			if ((cat == a) || (cat == b) || (cat == c) || (cat == d)): out[i + 1] = 1

void usm_sym1(ttf_usm* m, char* src, char* out, int a):
	usm_sym(m, src, out, a, -1, -1, -1)

# s = s (X)?, in place.
void usm_opt(ttf_usm* m, char* s, int a, int b):
	char* t = usm_new(m)
	usm_sym(m, s, t, a, b, -1, -1)
	usm_or(m, s, t)
	usm_drop(m, 1)

# s = s (X)*, in place.
void usm_star(ttf_usm* m, char* s, int a):
	char* t = usm_new(m)
	char* u = usm_new(m)
	usm_copy(m, t, s)
	int grew = 1
	while (grew):
		usm_sym1(m, t, u, a)
		grew = 0
		for i in range(m.width):
			t[i] = 0
			if (u[i] && !s[i]):
				s[i] = 1
				t[i] = 1
				grew = 1
	usm_drop(m, 2)

# Folds the new positions of step into acc, leaving only them in
# frontier; returns whether there were any.
int usm_grow(ttf_usm* m, char* acc, char* frontier, char* step):
	int grew = 0
	for i in range(m.width):
		frontier[i] = 0
		if (step[i] && !acc[i]):
			acc[i] = 1
			frontier[i] = 1
			grew = 1
	return grew

# consonant_modifiers = CMAbv* CMBlw* ((h B | SUB) CMAbv* CMBlw*)*
void usm_consonant_modifiers(ttf_usm* m, char* src, char* out):
	char* frontier = usm_new(m)
	char* t = usm_new(m)
	char* u = usm_new(m)
	usm_copy(m, out, src)
	usm_star(m, out, ttf_use_cmabv)
	usm_star(m, out, ttf_use_cmblw)
	usm_copy(m, frontier, out)
	int grew = 1
	while (grew):
		usm_sym(m, frontier, t, ttf_use_h, ttf_use_hvm, ttf_use_is, ttf_use_sk)
		usm_sym1(m, t, u, ttf_use_b)
		usm_sym1(m, frontier, t, ttf_use_sub)
		usm_or(m, u, t)
		usm_star(m, u, ttf_use_cmabv)
		usm_star(m, u, ttf_use_cmblw)
		grew = usm_grow(m, out, frontier, u)
	usm_drop(m, 3)

# complex_syllable_middle = consonant_modifiers medial_consonants
# dependent_vowels vowel_modifiers (Sk B)*
void usm_middle(ttf_usm* m, char* src, char* out):
	char* t = usm_new(m)
	char* u = usm_new(m)
	usm_consonant_modifiers(m, src, t)
	# medial_consonants = MPre? MAbv? MBlw? MPst?
	usm_opt(m, t, ttf_use_mpre, -1)
	usm_opt(m, t, ttf_use_mabv, -1)
	usm_opt(m, t, ttf_use_mblw, -1)
	usm_opt(m, t, ttf_use_mpst, -1)
	# dependent_vowels = VPre* VAbv* VBlw* VPst* | H
	usm_copy(m, out, t)
	usm_star(m, out, ttf_use_vpre)
	usm_star(m, out, ttf_use_vabv)
	usm_star(m, out, ttf_use_vblw)
	usm_star(m, out, ttf_use_vpst)
	usm_sym1(m, t, u, ttf_use_h)
	usm_or(m, out, u)
	# vowel_modifiers = HVM? VMPre* VMAbv* VMBlw* VMPst*
	usm_opt(m, out, ttf_use_hvm, -1)
	usm_star(m, out, ttf_use_vmpre)
	usm_star(m, out, ttf_use_vmabv)
	usm_star(m, out, ttf_use_vmblw)
	usm_star(m, out, ttf_use_vmpst)
	# (Sk B)*
	char* frontier = usm_new(m)
	usm_copy(m, frontier, out)
	int grew = 1
	while (grew):
		usm_sym1(m, frontier, t, ttf_use_sk)
		usm_sym1(m, t, u, ttf_use_b)
		grew = usm_grow(m, out, frontier, u)
	usm_drop(m, 3)

# complex_syllable_tail = complex_syllable_middle final_consonants
# final_modifiers
void usm_complex_tail(ttf_usm* m, char* src, char* out):
	char* t = usm_new(m)
	usm_middle(m, src, t)
	# final_consonants = FAbv* FBlw* FPst*
	usm_star(m, t, ttf_use_fabv)
	usm_star(m, t, ttf_use_fblw)
	usm_star(m, t, ttf_use_fpst)
	# final_modifiers = FMAbv* FMBlw* | FMPst?
	usm_copy(m, out, t)
	usm_star(m, out, ttf_use_fmabv)
	usm_star(m, out, ttf_use_fmblw)
	usm_opt(m, t, ttf_use_fmpst, -1)
	usm_or(m, out, t)
	usm_drop(m, 1)

# s = s (HN N)*, in place.
void usm_hn_n_star(ttf_usm* m, char* s):
	char* frontier = usm_new(m)
	char* t = usm_new(m)
	char* u = usm_new(m)
	usm_copy(m, frontier, s)
	int grew = 1
	while (grew):
		usm_sym1(m, frontier, t, ttf_use_hn)
		usm_sym1(m, t, u, ttf_use_n)
		grew = usm_grow(m, s, frontier, u)
	usm_drop(m, 3)

# number_joiner_terminated_cluster_tail = (HN N)* HN
void usm_njt_tail(ttf_usm* m, char* src, char* out):
	char* t = usm_new(m)
	usm_copy(m, t, src)
	usm_hn_n_star(m, t)
	usm_sym1(m, t, out, ttf_use_hn)
	usm_drop(m, 1)

# numeral_cluster_tail = (HN N)+
void usm_numeral_tail(ttf_usm* m, char* src, char* out):
	char* t = usm_new(m)
	usm_sym1(m, src, t, ttf_use_hn)
	usm_sym1(m, t, out, ttf_use_n)
	usm_hn_n_star(m, out)
	usm_drop(m, 1)

# symbol_cluster_tail = SMAbv+ SMBlw* | SMBlw+
void usm_symbol_tail(ttf_usm* m, char* src, char* out):
	char* t = usm_new(m)
	usm_sym1(m, src, out, ttf_use_smabv)
	usm_star(m, out, ttf_use_smabv)
	usm_star(m, out, ttf_use_smblw)
	usm_sym1(m, src, t, ttf_use_smblw)
	usm_star(m, t, ttf_use_smblw)
	usm_or(m, out, t)
	usm_drop(m, 1)

# virama_terminated_cluster_tail = consonant_modifiers (IS | RK)
void usm_virama_tail(ttf_usm* m, char* src, char* out):
	char* t = usm_new(m)
	usm_consonant_modifiers(m, src, t)
	usm_sym(m, t, out, ttf_use_is, ttf_use_rk, -1, -1)
	usm_drop(m, 1)

# sakot_terminated_cluster_tail = complex_syllable_middle Sk
void usm_sakot_tail(ttf_usm* m, char* src, char* out):
	char* t = usm_new(m)
	usm_middle(m, src, t)
	usm_sym1(m, t, out, ttf_use_sk)
	usm_drop(m, 1)

# tail = complex_syllable_tail | sakot_terminated_cluster_tail |
# symbol_cluster_tail | virama_terminated_cluster_tail
void usm_tail(ttf_usm* m, char* src, char* out):
	char* t = usm_new(m)
	usm_complex_tail(m, src, out)
	usm_sakot_tail(m, src, t)
	usm_or(m, out, t)
	usm_symbol_tail(m, src, t)
	usm_or(m, out, t)
	usm_virama_tail(m, src, t)
	usm_or(m, out, t)
	usm_drop(m, 1)

# complex_syllable_start = (R | CS)? (B | GB)
void usm_start(ttf_usm* m, char* src, char* out):
	char* t = usm_new(m)
	usm_copy(m, t, src)
	usm_opt(m, t, ttf_use_r, ttf_use_cs)
	usm_sym(m, t, out, ttf_use_b, ttf_use_gb, -1, -1)
	usm_drop(m, 1)

# G HR? HM? SE*, from src into out.
void usm_glyph_group(ttf_usm* m, char* src, char* out):
	usm_sym1(m, src, out, ttf_use_g)
	usm_opt(m, out, ttf_use_hr, -1)
	usm_opt(m, out, ttf_use_hm, -1)
	usm_star(m, out, ttf_use_se)

# hieroglyph_cluster = SB* G HR? HM? SE* (J SB* (G HR? HM? SE*)?)*
void usm_hieroglyph(ttf_usm* m, char* src, char* out):
	char* t = usm_new(m)
	char* u = usm_new(m)
	char* frontier = usm_new(m)
	usm_copy(m, t, src)
	usm_star(m, t, ttf_use_sb)
	usm_glyph_group(m, t, out)
	usm_copy(m, frontier, out)
	int grew = 1
	while (grew):
		usm_sym1(m, frontier, t, ttf_use_j)
		usm_star(m, t, ttf_use_sb)
		usm_glyph_group(m, t, u)
		usm_or(m, t, u)
		grew = usm_grow(m, out, frontier, t)
	usm_drop(m, 3)

int usm_longest(ttf_usm* m, char* s):
	int best = 0
	for i in range(m.width):
		if (s[i]): best = i
	return best

# Length and type of the syllable starting at the window's first symbol:
# Ragel's longest match, earlier rules winning ties. Every cluster rule
# but FMPst and other takes an optional trailing ZWNJ.
int usm_match(ttf_usm* m, int* type):
	char* src = usm_new(m)
	char* t = usm_new(m)
	char* u = usm_new(m)
	char* out = usm_new(m)
	src[0] = 1
	int best = 0
	type[0] = ttf_use_non_cluster
	for rule in range(7):
		for i in range(m.width): out[i] = 0
		if (rule == 0):
			usm_start(m, src, t)
			usm_virama_tail(m, t, out)
		if (rule == 1):
			usm_start(m, src, t)
			usm_sakot_tail(m, t, out)
		if (rule == 2):
			usm_start(m, src, t)
			usm_complex_tail(m, t, out)
		if (rule == 3):
			usm_sym1(m, src, t, ttf_use_n)
			usm_njt_tail(m, t, out)
		if (rule == 4):
			usm_sym1(m, src, out, ttf_use_n)
			usm_numeral_tail(m, out, t)
			usm_or(m, out, t)
		if (rule == 5):
			usm_sym(m, src, out, ttf_use_o, ttf_use_gb, ttf_use_sb, -1)
			usm_tail(m, out, t)
			usm_or(m, out, t)
		if (rule == 6): usm_hieroglyph(m, src, out)
		usm_opt(m, out, ttf_use_zwnj, -1)
		int len = usm_longest(m, out)
		if (len > best):
			best = len
			type[0] = rule
	if ((best < 1) && (m.cats[0] == ttf_use_fmpst)):
		best = 1
		type[0] = ttf_use_non_cluster
	# broken_cluster = R? (tail | number_joiner_terminated_cluster_tail |
	# numeral_cluster_tail)
	usm_copy(m, t, src)
	usm_opt(m, t, ttf_use_r, -1)
	usm_tail(m, t, out)
	usm_njt_tail(m, t, u)
	usm_or(m, out, u)
	usm_numeral_tail(m, t, u)
	usm_or(m, out, u)
	usm_opt(m, out, ttf_use_zwnj, -1)
	int broken = usm_longest(m, out)
	if (broken > best):
		best = broken
		type[0] = ttf_use_broken
	usm_drop(m, 4)
	if (best < 1):
		best = 1
		type[0] = ttf_use_non_cluster
	return best

# Number every glyph's syllable: serial (1..15, wrapping as HarfBuzz's
# does) * 16 + type. Like HarfBuzz, the machine skips CGJ (which
# includes ZWJ) and a ZWNJ before a mark; they take the syllable they
# fall in. Returns whether a broken cluster was found.
int ttf_use_find_syllables(otl_buffer* b):
	int32* index = cast(int32*, malloc(b.count * 4 + 4))
	int32* cats = cast(int32*, malloc(b.count * 4 + 4))
	int n = 0
	for i in range(b.count):
		b.glyphs[i].syllable = 0
		int cat = b.glyphs[i].icat
		if (cat == ttf_use_cgj): continue
		if (cat == ttf_use_zwnj):
			int j = i + 1
			while ((j < b.count) && (b.glyphs[j].icat == ttf_use_cgj)): j = j + 1
			if ((j < b.count) && (b.glyphs[j].cp >= 0) && ttf_use_is_mark_category(ut_category(b.glyphs[j].cp))): continue
		index[n] = i
		cats[n] = cat
		n = n + 1
	index[n] = b.count
	ttf_usm m
	m.pool = cast(char*, malloc(96 * (ttf_use_window + 1)))
	int broken = 0
	int serial = 1
	int at = 0
	while (at < n):
		m.cats = &cats[at]
		# No syllable runs past an O or WJ after its first symbol (only a
		# symbol cluster starts with O), which keeps the sets word-sized.
		m.len = 1
		while ((at + m.len < n) && (m.len < ttf_use_window) && (cats[at + m.len] != ttf_use_o) && (cats[at + m.len] != ttf_use_wj)): m.len = m.len + 1
		m.width = m.len + 1
		m.top = 0
		int type = 0
		int len = usm_match(&m, &type)
		if (type == ttf_use_broken): broken = 1
		for k in range(index[at], index[at + len]): b.glyphs[k].syllable = serial * 16 + type
		serial = serial + 1
		if (serial == 16): serial = 1
		at = at + len
	free(m.pool)
	free(index)
	free(cats)
	return broken

# The end of the syllable starting at start.
int ttf_use_syllable_end(otl_buffer* b, int start):
	int end = start + 1
	while ((end < b.count) && (b.glyphs[end].syllable == b.glyphs[start].syllable)): end = end + 1
	return end

# ---- masks ---------------------------------------------------------------

# rphf applies to a syllable's repha, or else to its first three glyphs.
void ttf_use_rphf_mask(otl_buffer* b):
	int start = 0
	while (start < b.count):
		int end = ttf_use_syllable_end(b, start)
		int limit = end - start
		if (limit > 3): limit = 3
		if (b.glyphs[start].icat == ttf_use_r): limit = 1
		for i in range(start, start + limit): b.glyphs[i].mask = b.glyphs[i].mask | ttf_use_mask_rphf
		start = end

# Topographical forms per cluster: a cluster joins the one before it
# unless either is a hieroglyph or non-cluster. masks holds the isol,
# init, medi and fina masks (0 when the font lacks the feature).
void ttf_use_topographical(otl_buffer* b, int* masks):
	int all = masks[0] | masks[1] | masks[2] | masks[3]
	if (all == 0): return
	int last_start = 0
	int last_form = -1
	int start = 0
	while (start < b.count):
		int end = ttf_use_syllable_end(b, start)
		int type = b.glyphs[start].syllable & 15
		if ((type == ttf_use_hieroglyph) || (type == ttf_use_non_cluster)): last_form = -1
		else:
			# Forms: 0 isol, 1 init, 2 medi, 3 fina.
			int join = (last_form == 3) || (last_form == 0)
			if (join):
				if (last_form == 3): last_form = 2
				else: last_form = 1
				for i in range(last_start, start): b.glyphs[i].mask = (b.glyphs[i].mask & ~all) | masks[last_form]
			last_form = 0
			if (join): last_form = 3
			for i in range(start, end): b.glyphs[i].mask = (b.glyphs[i].mask & ~all) | masks[last_form]
		last_start = start
		start = end

void ttf_use_clear_substituted(otl_buffer* b):
	for i in range(b.count): b.glyphs[i].subst = b.glyphs[i].subst & ~otl_subst_substituted

# A substituted repha (in the rphf-masked start of a syllable) becomes R.
void ttf_use_record_rphf(otl_buffer* b):
	int start = 0
	while (start < b.count):
		int end = ttf_use_syllable_end(b, start)
		int i = start
		while ((i < end) && ((b.glyphs[i].mask & ttf_use_mask_rphf) != 0)):
			if ((b.glyphs[i].subst & otl_subst_substituted) != 0):
				b.glyphs[i].icat = ttf_use_r
				break
			i = i + 1
		start = end

# A substituted pre-base form behaves as VPre.
void ttf_use_record_pref(otl_buffer* b):
	int start = 0
	while (start < b.count):
		int end = ttf_use_syllable_end(b, start)
		for i in range(start, end):
			if ((b.glyphs[i].subst & otl_subst_substituted) != 0):
				b.glyphs[i].icat = ttf_use_vpre
				break
		start = end

# ---- reordering ------------------------------------------------------------

# Dotted circles (U+25CC, category B) open each broken cluster, after
# any repha.
void ttf_use_dotted_circles(ttf_font* f, otl_buffer* b):
	int circle = ttf_glyph_id(f, 0x25cc)
	if (circle == 0): return
	int last = 0
	int i = 0
	while (i < b.count):
		int syllable = b.glyphs[i].syllable
		if ((syllable == last) || ((syllable & 15) != ttf_use_broken)):
			i = i + 1
			continue
		last = syllable
		int at = i
		while ((at < b.count) && (b.glyphs[at].syllable == syllable) && (b.glyphs[at].icat == ttf_use_r)): at = at + 1
		otl_buffer_insert_copy(b, at, i)
		otl_glyph* g = &b.glyphs[at]
		g.gid = circle
		g.cp = 0x25cc
		g.icat = ttf_use_b
		g.props = 0
		g.unicode_mark = 0
		g.subst = 0
		g.lig_id = 0
		g.lig_comp = 0
		i = at + 1

int ttf_use_is_halant(otl_glyph* g):
	return ((g.icat == ttf_use_h) || (g.icat == ttf_use_hvm) || (g.icat == ttf_use_is)) && ((g.subst & otl_subst_ligated) == 0)

int ttf_use_is_post_base(otl_glyph* g):
	int c = g.icat
	if ((c == ttf_use_fabv) || (c == ttf_use_fblw) || (c == ttf_use_fpst) || (c == ttf_use_fmabv) || (c == ttf_use_fmblw) || (c == ttf_use_fmpst)): return 1
	if ((c == ttf_use_mabv) || (c == ttf_use_mblw) || (c == ttf_use_mpst) || (c == ttf_use_mpre)): return 1
	if ((c == ttf_use_vabv) || (c == ttf_use_vblw) || (c == ttf_use_vpst) || (c == ttf_use_vpre)): return 1
	if ((c == ttf_use_vmabv) || (c == ttf_use_vmblw) || (c == ttf_use_vmpst) || (c == ttf_use_vmpre)): return 1
	return ttf_use_is_halant(g)

void ttf_use_reorder_syllable(otl_buffer* b, int start, int end):
	int type = b.glyphs[start].syllable & 15
	if ((type != ttf_use_virama_terminated) && (type != ttf_use_sakot_terminated) && (type != ttf_use_standard) && (type != ttf_use_symbol) && (type != ttf_use_broken)): return
	otl_glyph* info = b.glyphs
	# A repha moves towards the end, before the first post-base glyph.
	if ((info[start].icat == ttf_use_r) && (end - start > 1)):
		for i in range(start + 1, end):
			int post = ttf_use_is_post_base(&info[i])
			if (post || (i == end - 1)):
				int to = i
				if (post): to = i - 1
				otl_merge_clusters(b, start, to + 1)
				ttf_indic_move(b, start, to)
				break
	# Pre-base vowels and pre-base forms move to the start, or after the
	# last halant.
	int j = start
	for i in range(start, end):
		int cat = info[i].icat
		if (ttf_use_is_halant(&info[i])): j = i + 1
		else if (((cat == ttf_use_vpre) || (cat == ttf_use_vmpre)) && (otl_lig_comp(&info[i]) == 0) && (j < i)):
			otl_merge_clusters(b, j, i + 1)
			ttf_indic_move(b, i, j)

# ---- driver ------------------------------------------------------------------

void ttf_use_stage(ttf_font* f, otl_buffer* b, char* scripts, int script_count, int language, int* tags, int* masks, int n, int rtl):
	otl_apply_stage(f, b, otl_gsub, scripts, script_count, language, tags, masks, n, rtl)

void ttf_use_feature(int* tags, int* masks, int* n, char* tag, int mask):
	tags[n[0]] = otl_tag(tag)
	masks[n[0]] = mask
	n[0] = n[0] + 1

# The USE GSUB pipeline over b (normalized, glyphs carrying ttf_shape's
# global mask in bit 0). forms: the Arabic joining form (ut_form_*) of
# each glyph for a joining script, else 0. liga: whether liga and clig
# apply.
void ttf_use_shape(ttf_font* f, otl_buffer* b, char* scripts, int script_count, int language, char* code, int32* forms, int rtl, int liga):
	for i in range(b.count): b.glyphs[i].icat = ttf_use_category(b.glyphs[i].cp)
	int[4] topo
	char* topo_tags = c"isolinitmedifina"
	int has_rphf = ttf_indic_has_feature(f, scripts, script_count, language, otl_tag(c"rphf"))
	for k in range(4):
		topo[k] = 0
		if (ttf_indic_has_feature(f, scripts, script_count, language, otl_tag(&topo_tags[k * 4]))): topo[k] = ttf_use_mask_isol << k
	if (forms != 0):
		# Arabic joining masks; Mongolian variation selectors take their
		# base's form.
		int mongolian = ttf_use_code_in(code, c"Mong")
		for i in range(b.count):
			int form = forms[i]
			if (mongolian && (i > 0) && (((b.glyphs[i].cp >= 0x180b) && (b.glyphs[i].cp <= 0x180d)) || (b.glyphs[i].cp == 0x180f))):
				form = forms[i - 1]
				forms[i] = form
			int mask = 0
			if (form == ut_form_isol): mask = topo[0]
			if (form == ut_form_init): mask = topo[1]
			if (form == ut_form_medi): mask = topo[2]
			if (form == ut_form_fina): mask = topo[3]
			b.glyphs[i].mask = b.glyphs[i].mask | mask
	int[16] tags
	int[16] masks
	int n = 0
	int hb = otl_mask_hb
	int syllabic = otl_mask_hb | otl_mask_per_syllable
	int manual_zwj = otl_mask_hb | otl_mask_per_syllable | otl_mask_manual_joiners | otl_mask_auto_zwnj
	ttf_use_feature(&tags[0], &masks[0], &n, c"rvrn", 1 | hb)
	ttf_use_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], n, rtl)
	int broken = ttf_use_find_syllables(b)
	if (has_rphf): ttf_use_rphf_mask(b)
	if (forms == 0): ttf_use_topographical(b, &topo[0])
	n = 0
	ttf_use_feature(&tags[0], &masks[0], &n, c"locl", 1 | syllabic)
	ttf_use_feature(&tags[0], &masks[0], &n, c"ccmp", 1 | syllabic)
	ttf_use_feature(&tags[0], &masks[0], &n, c"nukt", 1 | syllabic)
	ttf_use_feature(&tags[0], &masks[0], &n, c"akhn", 1 | manual_zwj)
	ttf_use_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], n, rtl)
	ttf_use_clear_substituted(b)
	if (has_rphf):
		n = 0
		ttf_use_feature(&tags[0], &masks[0], &n, c"rphf", ttf_use_mask_rphf | manual_zwj)
		ttf_use_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], n, rtl)
		ttf_use_record_rphf(b)
	ttf_use_clear_substituted(b)
	n = 0
	ttf_use_feature(&tags[0], &masks[0], &n, c"pref", 1 | manual_zwj)
	ttf_use_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], n, rtl)
	ttf_use_record_pref(b)
	n = 0
	char* basic = c"rkrfabvfblwfhalfpstfvatucjct"
	for k in range(7): ttf_use_feature(&tags[0], &masks[0], &n, &basic[k * 4], 1 | manual_zwj)
	ttf_use_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], n, rtl)
	if (broken): ttf_use_dotted_circles(f, b)
	int start = 0
	while (start < b.count):
		int end = ttf_use_syllable_end(b, start)
		ttf_use_reorder_syllable(b, start, end)
		start = end
	for i in range(b.count): b.glyphs[i].syllable = 0
	n = 0
	for k in range(4):
		if (topo[k] != 0): ttf_use_feature(&tags[0], &masks[0], &n, &topo_tags[k * 4], topo[k] | hb)
	if (n > 0): ttf_use_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], n, rtl)
	n = 0
	int presentation = otl_mask_hb | otl_mask_manual_joiners | otl_mask_auto_zwnj
	char* other = c"abvsblwshalnprespsts"
	for k in range(5): ttf_use_feature(&tags[0], &masks[0], &n, &other[k * 4], 1 | presentation)
	ttf_use_feature(&tags[0], &masks[0], &n, c"rlig", 1 | hb)
	ttf_use_feature(&tags[0], &masks[0], &n, c"calt", 1 | hb)
	ttf_use_feature(&tags[0], &masks[0], &n, c"rclt", 1 | hb)
	if (liga):
		ttf_use_feature(&tags[0], &masks[0], &n, c"liga", 1 | hb)
		ttf_use_feature(&tags[0], &masks[0], &n, c"clig", 1 | hb)
	ttf_use_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], n, rtl)
