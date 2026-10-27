/*
lib.ttf_khmer: the Khmer shaper behind lib.ttf_shape (issue #825), a port
of HarfBuzz 15's hb-ot-shaper-khmer.

	ttf_khmer_shape(f, b, scripts, script_count, language, liga)

runs the GSUB pipeline of a Khmer run over a normalized buffer: rvrn;
syllable segmentation (HarfBuzz's Ragel machine as a longest-match set
simulation, as lib.ttf_indic does); dotted circles for broken clusters;
reordering (a Coeng,Ro pair moves to the front of its syllable as a
pre-base form, a left vowel moves to the front, and the pref, blwf, abvf,
pstf and cfar masks are set); then locl, ccmp and the basic features
pref blwf abvf pstf cfar in one stage, per syllable; then pres abvs blws
psts with rlig calt clig rclt ('liga' is off for Khmer). Like HarfBuzz,
Khmer zeroes no mark advances and has no fallback positioning, which
lib.ttf_shape arranges. The split vowels U+17BE..U+17C0, U+17C4 and
U+17C5 decompose into U+17C1 plus themselves (ttf_khmer_decompose).
*/
import lib.lib
import lib.ttf
import lib.ttf_indic
import lib.ttf_layout
import lib.ttf_sea

# Feature masks (bit 0 is ttf_shape's global mask).
const int ttf_khmer_mask_pref = 32
const int ttf_khmer_mask_blwf = 64
const int ttf_khmer_mask_abvf = 128
const int ttf_khmer_mask_pstf = 256
const int ttf_khmer_mask_cfar = 512

# Syllable types.
const int ttf_khmer_consonant = 0
const int ttf_khmer_broken = 1
const int ttf_khmer_other = 2

# The Khmer machine's symbol for a HarfBuzz category; categories the
# machine does not name match only its 'any' rule.
int ttf_khmer_symbol(int cat):
	if ((cat == ttf_sea_c) || (cat == ttf_sea_v) || (cat == ttf_sea_h) || (cat == ttf_sea_zwnj) || (cat == ttf_sea_zwj) || (cat == ttf_sea_placeholder) || (cat == ttf_sea_dottedcircle) || (cat == ttf_sea_ra)): return cat
	if ((cat >= ttf_sea_vabv) && (cat <= ttf_sea_vpst)): return cat
	if ((cat >= ttf_sea_robatic) && (cat <= ttf_sea_ygroup)): return cat
	return ttf_sea_x

# HarfBuzz's decompose_khmer: the split vowels the Unicode data does not
# decompose, as (U+17C1, the vowel itself). Returns 1 with a and b set.
int ttf_khmer_split(int cp, int* a, int* b):
	if ((cp == 0x17be) || (cp == 0x17bf) || (cp == 0x17c0) || (cp == 0x17c4) || (cp == 0x17c5)):
		a[0] = 0x17c1
		b[0] = cp
		return 1
	return 0

# ---- syllables -----------------------------------------------------------

int km_f(int cat):
	return 1 << cat

int km_c():
	return km_f(ttf_sea_c) | km_f(ttf_sea_ra) | km_f(ttf_sea_v)

int km_joiner():
	return km_f(ttf_sea_zwj) | km_f(ttf_sea_zwnj)

# cn = c ((ZWJ | ZWNJ)? Robatic)?
void km_cn(ttf_ism* m, char* src, char* out):
	char* t = ism_new(m)
	char* u = ism_new(m)
	ism_sym(m, src, out, km_c())
	ism_copy(m, t, out)
	ism_opt(m, t, km_joiner())
	ism_sym(m, t, u, km_f(ttf_sea_robatic))
	ism_or(m, out, u)
	ism_drop(m, 2)

# s = s xgroup, in place; xgroup = (joiner* Xgroup)*
void km_xgroup(ttf_ism* m, char* s):
	char* frontier = ism_new(m)
	char* t = ism_new(m)
	char* u = ism_new(m)
	ism_copy(m, frontier, s)
	int grew = 1
	while (grew):
		ism_copy(m, t, frontier)
		ism_star(m, t, km_joiner())
		ism_sym(m, t, u, km_f(ttf_sea_xgroup))
		grew = 0
		for i in range(m.width):
			frontier[i] = 0
			if (u[i] && !s[i]):
				s[i] = 1
				frontier[i] = 1
				grew = 1
	ism_drop(m, 3)

# s = s matra_group, in place; matra_group = VPre? xgroup VBlw? xgroup
# (joiner? VAbv)? xgroup VPst?
void km_matra_group(ttf_ism* m, char* s):
	ism_opt(m, s, km_f(ttf_sea_vpre))
	km_xgroup(m, s)
	ism_opt(m, s, km_f(ttf_sea_vblw))
	km_xgroup(m, s)
	char* t = ism_new(m)
	char* u = ism_new(m)
	ism_copy(m, t, s)
	ism_opt(m, t, km_joiner())
	ism_sym(m, t, u, km_f(ttf_sea_vabv))
	ism_or(m, s, u)
	ism_drop(m, 2)
	km_xgroup(m, s)
	ism_opt(m, s, km_f(ttf_sea_vpst))

# s = s syllable_tail, in place; syllable_tail = xgroup matra_group xgroup
# (H c)? ygroup
void km_syllable_tail(ttf_ism* m, char* s):
	km_xgroup(m, s)
	km_matra_group(m, s)
	km_xgroup(m, s)
	char* t = ism_new(m)
	char* u = ism_new(m)
	ism_sym(m, s, t, km_f(ttf_sea_h))
	ism_sym(m, t, u, km_c())
	ism_or(m, s, u)
	ism_drop(m, 2)
	ism_star(m, s, km_f(ttf_sea_ygroup))

# broken_cluster = Robatic? (H cn)* (H | syllable_tail)
void km_broken(ttf_ism* m, char* src, char* out):
	char* acc = ism_new(m)
	char* frontier = ism_new(m)
	char* t = ism_new(m)
	char* u = ism_new(m)
	ism_copy(m, acc, src)
	ism_opt(m, acc, km_f(ttf_sea_robatic))
	ism_copy(m, frontier, acc)
	int grew = 1
	while (grew):
		ism_sym(m, frontier, t, km_f(ttf_sea_h))
		km_cn(m, t, u)
		grew = 0
		for i in range(m.width):
			frontier[i] = 0
			if (u[i] && !acc[i]):
				acc[i] = 1
				frontier[i] = 1
				grew = 1
	ism_sym(m, acc, out, km_f(ttf_sea_h))
	km_syllable_tail(m, acc)
	ism_or(m, out, acc)
	ism_drop(m, 4)

# Length and type of the syllable at m.start (longest match, earlier
# rules winning ties).
int km_match(ttf_ism* m, int* type):
	char* src = ism_new(m)
	char* t = ism_new(m)
	char* u = ism_new(m)
	char* out = ism_new(m)
	src[0] = 1
	int best = 0
	type[0] = ttf_khmer_other
	# consonant_syllable = (cn | PLACEHOLDER | DOTTEDCIRCLE) broken_cluster
	km_cn(m, src, t)
	ism_sym(m, src, u, km_f(ttf_sea_placeholder) | km_f(ttf_sea_dottedcircle))
	ism_or(m, t, u)
	km_broken(m, t, out)
	int len = ism_longest(m, out)
	if (len > best):
		best = len
		type[0] = ttf_khmer_consonant
	km_broken(m, src, out)
	len = ism_longest(m, out)
	if (len > best):
		best = len
		type[0] = ttf_khmer_broken
	ism_drop(m, 4)
	if (best < 1):
		best = 1
		type[0] = ttf_khmer_other
	return best

# Number every glyph's syllable (serial * 16 + type, the serial wrapping
# as HarfBuzz's does). Returns whether a broken cluster was found.
int ttf_khmer_find_syllables(otl_buffer* b):
	ttf_ism m
	m.buffer = b
	m.width = ttf_indic_window + 1
	m.pool = cast(char*, malloc(64 * m.width))
	int broken = 0
	int serial = 1
	int i = 0
	while (i < b.count):
		m.start = i
		m.len = b.count - i
		if (m.len > ttf_indic_window): m.len = ttf_indic_window
		m.top = 0
		int type = 0
		int len = km_match(&m, &type)
		if (type == ttf_khmer_broken): broken = 1
		for k in range(i, i + len): b.glyphs[k].syllable = serial * 16 + type
		serial = ttf_sea_next_serial(serial)
		i = i + len
	free(m.pool)
	return broken

# ---- reordering ------------------------------------------------------------

# Move the glyph at from to position to (to < from), shifting the glyphs
# between up by one.
void ttf_khmer_move_back(otl_buffer* b, int from, int to):
	otl_glyph tmp
	otl_glyph_copy(&tmp, &b.glyphs[from])
	int k = from
	while (k > to):
		otl_glyph_copy(&b.glyphs[k], &b.glyphs[k - 1])
		k = k - 1
	otl_glyph_copy(&b.glyphs[to], &tmp)

# HarfBuzz's reorder_consonant_syllable for a consonant syllable or a
# broken cluster (after its dotted circle).
void ttf_khmer_reorder(otl_buffer* b, int start, int end, int* masks):
	otl_glyph* info = b.glyphs
	int post = masks[1] | masks[2] | masks[3]
	for i in range(start + 1, end): info[i].mask = info[i].mask | post
	int coengs = 0
	for i in range(start + 1, end):
		# A Coeng,Ro pair moves before the base and takes 'pref' (as in
		# HarfBuzz, the loop goes on from the shifted position).
		if ((info[i].icat == ttf_sea_h) && (coengs <= 2) && (i + 1 < end)):
			coengs = coengs + 1
			if (info[i + 1].icat == ttf_sea_ra):
				info[i].mask = info[i].mask | masks[0]
				info[i + 1].mask = info[i + 1].mask | masks[0]
				otl_merge_clusters(b, start, i + 2)
				ttf_khmer_move_back(b, i, start)
				ttf_khmer_move_back(b, i + 1, start + 1)
				# What follows takes 'cfar'.
				if (masks[4] != 0):
					for j in range(i + 2, end): info[j].mask = info[j].mask | masks[4]
				coengs = 2
		else if (info[i].icat == ttf_sea_vpre):
			# A left vowel moves to the front.
			otl_merge_clusters(b, start, i + 1)
			ttf_khmer_move_back(b, i, start)

# ---- driver ----------------------------------------------------------------

void ttf_khmer_stage(ttf_font* f, otl_buffer* b, char* scripts, int script_count, int language, int* tags, int* masks, int n):
	otl_apply_stage(f, b, otl_gsub, scripts, script_count, language, tags, masks, n, 0)

int ttf_khmer_feature_mask(ttf_font* f, char* scripts, int script_count, int language, char* tag, int mask):
	if (ttf_indic_has_feature(f, scripts, script_count, language, otl_tag(tag))): return mask
	return 0

# The Khmer GSUB pipeline over b (glyphs carry ttf_shape's global mask,
# bit 0). liga: whether clig applies.
void ttf_khmer_shape(ttf_font* f, otl_buffer* b, char* scripts, int script_count, int language, int liga):
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		g.icat = ttf_khmer_symbol(ttf_sea_category(g.cp))
		g.ipos = 0
	int[12] tags
	int[12] masks
	tags[0] = otl_tag(c"rvrn")
	masks[0] = 1 | otl_mask_hb
	ttf_khmer_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], 1)
	otl_apply_common(f, b, scripts, script_count, language, 0)
	int broken = ttf_khmer_find_syllables(b)
	if (broken): ttf_sea_dotted_circles(f, b, ttf_khmer_broken, ttf_sea_dottedcircle)
	# pref blwf abvf pstf cfar, 0 when the font lacks the feature.
	int[5] feature_masks
	char* basic = c"prefblwfabvfpstfcfar"
	for k in range(5): feature_masks[k] = ttf_khmer_feature_mask(f, scripts, script_count, language, &basic[k * 4], ttf_khmer_mask_pref << k)
	int start = 0
	while (start < b.count):
		int end = ttf_indic_syllable_end(b, start)
		int type = b.glyphs[start].syllable & 15
		if ((type == ttf_khmer_consonant) || (type == ttf_khmer_broken)): ttf_khmer_reorder(b, start, end, &feature_masks[0])
		start = end
	int flags = otl_mask_hb | otl_mask_manual_joiners | otl_mask_per_syllable
	tags[0] = otl_tag(c"locl")
	masks[0] = 1 | otl_mask_hb | otl_mask_per_syllable
	tags[1] = otl_tag(c"ccmp")
	masks[1] = masks[0]
	int n = 2
	for k in range(5):
		if (feature_masks[k] == 0): continue
		tags[n] = otl_tag(&basic[k * 4])
		masks[n] = feature_masks[k] | flags
		n = n + 1
	ttf_khmer_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], n)
	char* names = c"presabvsblwspstsrligcaltrcltclig"
	n = 0
	for k in range(8):
		if ((k == 7) && !liga): continue
		tags[n] = otl_tag(&names[k * 4])
		if (k < 4): masks[n] = 1 | otl_mask_hb | otl_mask_manual_joiners
		else: masks[n] = 1 | otl_mask_hb
		n = n + 1
	ttf_khmer_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], n)
