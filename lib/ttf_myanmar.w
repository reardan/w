/*
lib.ttf_myanmar: the Myanmar shaper behind lib.ttf_shape (issue #825), a
port of HarfBuzz 15's hb-ot-shaper-myanmar for fonts with the 'mym2'
script tag (HarfBuzz shapes 'mymr', DFLT and latn fonts with its default
shaper, and so does lib.ttf_shape: ttf_myanmar_applies).

	ttf_myanmar_shape(f, b, scripts, script_count, language, liga)

runs the GSUB pipeline of a Myanmar run over a normalized buffer: rvrn;
syllable segmentation (HarfBuzz's Ragel machine as a longest-match set
simulation, as lib.ttf_indic does); locl and ccmp per syllable; dotted
circles for broken clusters; initial reordering (kinzi, the base, medial
Ra and left vowels before it, below-base and post-base groups, by a
stable sort that merges the clusters of what moves); the basic features
rphf, pref, blwf and pstf one at a time, per syllable; then pres abvs
blws psts with rlig calt liga clig rclt. Mark advances are zeroed from
GDEF before GPOS, which lib.ttf_shape arranges.
*/
import lib.lib
import lib.ttf
import lib.ttf_indic
import lib.ttf_layout
import lib.ttf_sea
import lib.unicode_text

# Syllable types.
const int ttf_myanmar_consonant = 0
const int ttf_myanmar_broken = 1
const int ttf_myanmar_other = 2

# The machine's own symbols, renumbered below 31 so a set of them fits a
# word: HarfBuzz's numbers below 24, then As MH MR MW MY PT VS, and ML.
const int ttf_mym_as = 24
const int ttf_mym_mh = 25
const int ttf_mym_mr = 26
const int ttf_mym_mw = 27
const int ttf_mym_my = 28
const int ttf_mym_pt = 29
const int ttf_mym_vs = 30
const int ttf_mym_ml = 7
const int ttf_mym_smpst = 19

# The Myanmar machine's symbol for a HarfBuzz category; categories the
# machine does not name match only its 'any' rule.
int ttf_myanmar_symbol(int cat):
	if ((cat >= ttf_sea_c) && (cat <= ttf_sea_zwj)): return cat
	if ((cat == ttf_sea_sm) || (cat == ttf_sea_a) || (cat == ttf_sea_placeholder) || (cat == ttf_sea_dottedcircle) || (cat == ttf_sea_ra) || (cat == ttf_sea_cs)): return cat
	if ((cat >= ttf_sea_vabv) && (cat <= ttf_sea_vpst)): return cat
	if (cat == ttf_sea_smpst): return ttf_mym_smpst
	if (cat == ttf_sea_as): return ttf_mym_as
	if ((cat >= ttf_sea_mh) && (cat <= ttf_sea_vs)): return cat - ttf_sea_mh + ttf_mym_mh
	if (cat == ttf_sea_ml): return ttf_mym_ml
	return ttf_sea_x

# Like HarfBuzz: Myanmar text uses this shaper unless the font's GSUB
# script choice is DFLT, latn or the old 'mymr' tag.
int ttf_myanmar_applies(ttf_font* f, char* code, char* scripts, int script_count):
	if ((code[0] != 'M') || (code[1] != 'y') || (code[2] != 'm') || (code[3] != 'r')): return 0
	int chosen = ttf_indic_chosen_script(f, scripts, script_count)
	if (chosen < 0): return 1
	int tag = otl_tag(&scripts[chosen * 4])
	return (tag != otl_tag(c"DFLT")) && (tag != otl_tag(c"latn")) && (tag != otl_tag(c"mymr"))

# ---- syllables -----------------------------------------------------------

int my_f(int cat):
	return 1 << cat

int my_c():
	return my_f(ttf_sea_c) | my_f(ttf_sea_ra)

void my_closure_begin(ttf_ism* m, char* acc, char* frontier, char* src):
	ism_copy(m, acc, src)
	ism_copy(m, frontier, src)

# Add the positions of u not yet in acc to acc and (only those) to
# frontier. Returns whether any were new.
int my_closure_step(ttf_ism* m, char* acc, char* frontier, char* u):
	int grew = 0
	for i in range(m.width):
		frontier[i] = 0
		if (u[i] && !acc[i]):
			acc[i] = 1
			frontier[i] = 1
			grew = 1
	return grew

# s = s (DB As?)?, in place.
void my_db(ttf_ism* m, char* s):
	char* t = ism_new(m)
	ism_sym(m, s, t, my_f(ttf_sea_n))
	ism_opt(m, t, my_f(ttf_mym_as))
	ism_or(m, s, t)
	ism_drop(m, 1)

# s = s medial_group, in place; medial_group = MY? As? MR? ((MW MH? ML?
# | MH ML? | ML) As?)?
void my_medial_group(ttf_ism* m, char* s):
	ism_opt(m, s, my_f(ttf_mym_my))
	ism_opt(m, s, my_f(ttf_mym_as))
	ism_opt(m, s, my_f(ttf_mym_mr))
	char* t = ism_new(m)
	char* u = ism_new(m)
	ism_sym(m, s, t, my_f(ttf_mym_mw))
	ism_opt(m, t, my_f(ttf_mym_mh))
	ism_opt(m, t, my_f(ttf_mym_ml))
	ism_sym(m, s, u, my_f(ttf_mym_mh))
	ism_opt(m, u, my_f(ttf_mym_ml))
	ism_or(m, t, u)
	ism_sym(m, s, u, my_f(ttf_mym_ml))
	ism_or(m, t, u)
	ism_opt(m, t, my_f(ttf_mym_as))
	ism_or(m, s, t)
	ism_drop(m, 2)

# s = s main_vowel_group, in place; main_vowel_group = (VPre VS?)* VAbv*
# VBlw* A* (DB As?)?
void my_main_vowel_group(ttf_ism* m, char* s):
	char* frontier = ism_new(m)
	char* t = ism_new(m)
	ism_copy(m, frontier, s)
	int grew = 1
	while (grew):
		ism_sym(m, frontier, t, my_f(ttf_sea_vpre))
		ism_opt(m, t, my_f(ttf_mym_vs))
		grew = my_closure_step(m, s, frontier, t)
	ism_drop(m, 2)
	ism_star(m, s, my_f(ttf_sea_vabv))
	ism_star(m, s, my_f(ttf_sea_vblw))
	ism_star(m, s, my_f(ttf_sea_a))
	my_db(m, s)

# out = src post_vowel_group; post_vowel_group = VPst MH? ML? As* VAbv* A*
# (DB As?)?
void my_post_vowel_group(ttf_ism* m, char* src, char* out):
	ism_sym(m, src, out, my_f(ttf_sea_vpst))
	ism_opt(m, out, my_f(ttf_mym_mh))
	ism_opt(m, out, my_f(ttf_mym_ml))
	ism_star(m, out, my_f(ttf_mym_as))
	ism_star(m, out, my_f(ttf_sea_vabv))
	ism_star(m, out, my_f(ttf_sea_a))
	my_db(m, out)

# out = src tone_group; tone_group = sm | PT A* DB? As?
void my_tone_group(ttf_ism* m, char* src, char* out):
	char* t = ism_new(m)
	ism_sym(m, src, out, my_f(ttf_sea_sm) | my_f(ttf_mym_smpst))
	ism_sym(m, src, t, my_f(ttf_mym_pt))
	ism_star(m, t, my_f(ttf_sea_a))
	ism_opt(m, t, my_f(ttf_sea_n))
	ism_opt(m, t, my_f(ttf_mym_as))
	ism_or(m, out, t)
	ism_drop(m, 1)

# s = s complex_syllable_tail, in place; complex_syllable_tail = As*
# medial_group main_vowel_group post_vowel_group* tone_group* j?
void my_complex_tail(ttf_ism* m, char* s):
	ism_star(m, s, my_f(ttf_mym_as))
	my_medial_group(m, s)
	my_main_vowel_group(m, s)
	char* frontier = ism_new(m)
	char* t = ism_new(m)
	ism_copy(m, frontier, s)
	int grew = 1
	while (grew):
		my_post_vowel_group(m, frontier, t)
		grew = my_closure_step(m, s, frontier, t)
	ism_copy(m, frontier, s)
	grew = 1
	while (grew):
		my_tone_group(m, frontier, t)
		grew = my_closure_step(m, s, frontier, t)
	ism_drop(m, 2)
	ism_opt(m, s, my_f(ttf_sea_zwj) | my_f(ttf_sea_zwnj))

# out = src syllable_tail; syllable_tail = (H (c | IV) VS?)* (H |
# complex_syllable_tail)
void my_syllable_tail(ttf_ism* m, char* src, char* out):
	char* acc = ism_new(m)
	char* frontier = ism_new(m)
	char* t = ism_new(m)
	char* u = ism_new(m)
	my_closure_begin(m, acc, frontier, src)
	int grew = 1
	while (grew):
		ism_sym(m, frontier, t, my_f(ttf_sea_h))
		ism_sym(m, t, u, my_c() | my_f(ttf_sea_v))
		ism_opt(m, u, my_f(ttf_mym_vs))
		grew = my_closure_step(m, acc, frontier, u)
	ism_sym(m, acc, out, my_f(ttf_sea_h))
	my_complex_tail(m, acc)
	ism_or(m, out, acc)
	ism_drop(m, 4)

# t = src k?; k = Ra As H
void my_kinzi_opt(ttf_ism* m, char* src, char* out):
	char* t = ism_new(m)
	char* u = ism_new(m)
	ism_copy(m, out, src)
	ism_sym(m, src, t, my_f(ttf_sea_ra))
	ism_sym(m, t, u, my_f(ttf_mym_as))
	ism_sym(m, u, t, my_f(ttf_sea_h))
	ism_or(m, out, t)
	ism_drop(m, 2)

# Length and type of the syllable at m.start (longest match, earlier
# rules winning ties).
int my_match(ttf_ism* m, int* type):
	char* src = ism_new(m)
	char* t = ism_new(m)
	char* u = ism_new(m)
	char* out = ism_new(m)
	src[0] = 1
	int best = 0
	type[0] = ttf_myanmar_other
	# consonant_syllable = (k | CS)? (c | IV | GB | DOTTEDCIRCLE) VS?
	# syllable_tail
	my_kinzi_opt(m, src, t)
	ism_sym(m, src, u, my_f(ttf_sea_cs))
	ism_or(m, t, u)
	ism_sym(m, t, u, my_c() | my_f(ttf_sea_v) | my_f(ttf_sea_placeholder) | my_f(ttf_sea_dottedcircle))
	ism_opt(m, u, my_f(ttf_mym_vs))
	my_syllable_tail(m, u, out)
	int len = ism_longest(m, out)
	if (len > best):
		best = len
		type[0] = ttf_myanmar_consonant
	# j | SMPst
	if ((best < 1) && ((my_f(ism_cat(m, 0)) & (my_f(ttf_sea_zwj) | my_f(ttf_sea_zwnj) | my_f(ttf_mym_smpst))) != 0)):
		best = 1
		type[0] = ttf_myanmar_other
	# broken_cluster = k? VS? syllable_tail
	my_kinzi_opt(m, src, t)
	ism_opt(m, t, my_f(ttf_mym_vs))
	my_syllable_tail(m, t, out)
	len = ism_longest(m, out)
	if (len > best):
		best = len
		type[0] = ttf_myanmar_broken
	ism_drop(m, 4)
	if (best < 1):
		best = 1
		type[0] = ttf_myanmar_other
	return best

# Number every glyph's syllable (serial * 16 + type, the serial wrapping
# as HarfBuzz's does). Returns whether a broken cluster was found.
int ttf_myanmar_find_syllables(otl_buffer* b):
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
		int len = my_match(&m, &type)
		if (type == ttf_myanmar_broken): broken = 1
		for k in range(i, i + len): b.glyphs[k].syllable = serial * 16 + type
		serial = ttf_sea_next_serial(serial)
		i = i + len
	free(m.pool)
	return broken

# ---- reordering ------------------------------------------------------------

# HarfBuzz's is_consonant_myanmar (a ligated glyph is none).
int ttf_myanmar_is_consonant(otl_glyph* g):
	if ((g.subst & otl_subst_ligated) != 0): return 0
	int mask = my_f(ttf_sea_c) | my_f(ttf_sea_cs) | my_f(ttf_sea_ra) | my_f(ttf_sea_v) | my_f(ttf_sea_placeholder) | my_f(ttf_sea_dottedcircle)
	return (my_f(g.icat) & mask) != 0

# HarfBuzz's initial_reordering_consonant_syllable.
void ttf_myanmar_reorder(otl_buffer* b, int start, int end):
	otl_glyph* info = b.glyphs
	int base = end
	int has_reph = 0
	int limit = start
	if ((start + 3 <= end) && (info[start].icat == ttf_sea_ra) && (info[start + 1].icat == ttf_mym_as) && (info[start + 2].icat == ttf_sea_h)):
		limit = limit + 3
		base = start
		has_reph = 1
	if (!has_reph): base = limit
	for i in range(limit, end):
		if (ttf_myanmar_is_consonant(&info[i])):
			base = i
			break
	int i = start
	int kinzi_end = start
	if (has_reph): kinzi_end = start + 3
	while (i < kinzi_end):
		info[i].ipos = ut_ipos_after_main
		i = i + 1
	while (i < base):
		info[i].ipos = ut_ipos_pre_c
		i = i + 1
	if (i < end):
		info[i].ipos = ut_ipos_base_c
		i = i + 1
	int pos = ut_ipos_after_main
	while (i < end):
		int cat = info[i].icat
		if (cat == ttf_mym_mr): info[i].ipos = ut_ipos_pre_c
		else if (cat == ttf_sea_vpre): info[i].ipos = ut_ipos_pre_m
		else if (cat == ttf_mym_vs): info[i].ipos = info[i - 1].ipos
		else if ((pos == ut_ipos_after_main) && (cat == ttf_sea_vblw)):
			pos = ut_ipos_below_c
			info[i].ipos = pos
		else if ((pos == ut_ipos_below_c) && (cat == ttf_sea_a)): info[i].ipos = ut_ipos_before_sub
		else if ((pos == ut_ipos_below_c) && (cat == ttf_sea_vblw)): info[i].ipos = pos
		else if (pos == ut_ipos_below_c):
			pos = ut_ipos_after_sub
			info[i].ipos = pos
		else: info[i].ipos = pos
		i = i + 1
	# HarfBuzz's buffer sort: a stable insertion sort by position that
	# merges the clusters each move spans.
	for k in range(start + 1, end):
		int j = k
		while ((j > start) && (info[j - 1].ipos > info[k].ipos)): j = j - 1
		if (j == k): continue
		otl_merge_clusters(b, j, k + 1)
		otl_glyph tmp
		otl_glyph_copy(&tmp, &info[k])
		int x = k
		while (x > j):
			otl_glyph_copy(&info[x], &info[x - 1])
			x = x - 1
		otl_glyph_copy(&info[j], &tmp)
	# Flip a run of left vowels, then put each vowel's variation selector
	# back after it.
	int first_left = end
	int last_left = end
	for k in range(start, end):
		if (info[k].ipos == ut_ipos_pre_m):
			if (first_left == end): first_left = k
			last_left = k
	if (first_left < last_left):
		ttf_indic_reverse(b, first_left, last_left + 1)
		int at = first_left
		for j in range(first_left, last_left + 1):
			if (info[j].icat == ttf_sea_vpre):
				ttf_indic_reverse(b, at, j + 1)
				at = j + 1

# ---- driver ----------------------------------------------------------------

void ttf_myanmar_stage(ttf_font* f, otl_buffer* b, char* scripts, int script_count, int language, int* tags, int* masks, int n):
	otl_apply_stage(f, b, otl_gsub, scripts, script_count, language, tags, masks, n, 0)

# The Myanmar GSUB pipeline over b (glyphs carry ttf_shape's global mask,
# bit 0). liga: whether liga and clig apply.
void ttf_myanmar_shape(ttf_font* f, otl_buffer* b, char* scripts, int script_count, int language, int liga):
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		g.icat = ttf_myanmar_symbol(ttf_sea_category(g.cp))
		g.ipos = 0
	int[12] tags
	int[12] masks
	tags[0] = otl_tag(c"rvrn")
	masks[0] = 1 | otl_mask_hb
	ttf_myanmar_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], 1)
	int broken = ttf_myanmar_find_syllables(b)
	tags[0] = otl_tag(c"locl")
	tags[1] = otl_tag(c"ccmp")
	masks[0] = 1 | otl_mask_hb | otl_mask_per_syllable
	masks[1] = masks[0]
	ttf_myanmar_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], 2)
	if (broken): ttf_sea_dotted_circles(f, b, ttf_myanmar_broken, ttf_sea_dottedcircle)
	int start = 0
	while (start < b.count):
		int end = ttf_indic_syllable_end(b, start)
		int type = b.glyphs[start].syllable & 15
		if ((type == ttf_myanmar_consonant) || (type == ttf_myanmar_broken)): ttf_myanmar_reorder(b, start, end)
		start = end
	char* basic = c"rphfprefblwfpstf"
	for k in range(4):
		tags[0] = otl_tag(&basic[k * 4])
		masks[0] = 1 | otl_mask_hb | otl_mask_manual_joiners | otl_mask_auto_zwnj | otl_mask_per_syllable
		ttf_myanmar_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], 1)
	char* names = c"presabvsblwspstsrligcaltrcltligaclig"
	int n = 0
	for k in range(9):
		if ((k >= 7) && !liga): continue
		tags[n] = otl_tag(&names[k * 4])
		if (k < 4): masks[n] = 1 | otl_mask_hb | otl_mask_manual_joiners | otl_mask_auto_zwnj
		else: masks[n] = 1 | otl_mask_hb
		n = n + 1
	ttf_myanmar_stage(f, b, scripts, script_count, language, &tags[0], &masks[0], n)
