/*
lib.ttf_layout: an OpenType Layout engine over lib.ttf fonts (issue #459):
GSUB glyph substitution and GPOS glyph positioning, the portable
counterpart of HarfBuzz's table interpreter. lib.ttf_shape drives it with
script-specific features; this module only knows the tables.

Covers GDEF glyph classes, mark attachment classes and mark glyph sets;
ScriptList/LangSys/FeatureList selection; lookup flags (ignore bases,
ligatures or marks, mark filtering and attachment types); GSUB types 1-8
(single, multiple, alternate (first alternate), ligature, context, chaining
context, extension, reverse chaining); GPOS types 1-9 (single, pair,
cursive, mark-to-base, mark-to-ligature, mark-to-mark, context, chaining
context, extension). Device and variation tables are ignored, and nested
contextual lookups that change the glyph count adjust later match
positions by the change (HarfBuzz tracks this more precisely).

Positions are in font units. A glyph buffer keeps logical order;
otl_position_finish resolves mark offsets for the final visual direction.
Every table read goes through lib.ttf's bounds-checked readers, and
nesting and loop counts are capped, so a hostile font cannot read out of
bounds or loop forever.
https://learn.microsoft.com/typography/opentype/spec/chapter2
*/
import lib.lib
import lib.ttf
import lib.unicode_text

const int otl_class_base = 1
const int otl_class_ligature = 2
const int otl_class_mark = 3
const int otl_class_component = 4

const int otl_gsub = 0
const int otl_gpos = 1

const int otl_attach_mark = 1
const int otl_attach_cursive = 2
# A GPOS mark attachment: its y offset is final when made (see otl_attach).
const int otl_attach_gpos_mark = 3

const int otl_max_nesting = 8

# otl_glyph.subst bits (HarfBuzz's glyph props): any substitution, a
# ligature of several glyphs, an output of a multiple substitution.
const int otl_subst_substituted = 1
const int otl_subst_ligated = 2
const int otl_subst_multiplied = 4

# Flags carried in the high bits of a stage's feature masks. hb selects
# HarfBuzz's matching rules: input glyphs must carry the feature mask, a
# default-ignorable glyph is skipped only when it does not match, and ZWNJ
# is skipped in backtrack/lookahead context (input ZWJ too, unless
# manual_joiners). per_syllable keeps matches inside the starting glyph's
# syllable. Without hb the legacy rules apply: ZWJ and variation
# selectors are skipped unless an input sequence names them, ZWNJ never,
# and only the first glyph's mask is checked.
const int otl_mask_per_syllable = 0x10000000
const int otl_mask_manual_joiners = 0x20000000
const int otl_mask_hb = 0x40000000
const int otl_mask_flags = 0x70000000

struct otl_glyph:
	int gid
	int cluster
	int cp            # first source codepoint, or -1 for an inserted glyph
	int mask          # feature bits the glyph takes part in
	int props         # otl_class_* glyph class
	int unicode_mark  # nonspacing mark (Mn/Me) in the source text
	int lig_id        # ligature a mark was skipped inside, or 0
	int lig_comp      # 1-based component of that ligature, or the
					  # component count on the ligature glyph itself
	int x_advance
	int y_advance
	int x_offset
	int y_offset
	int attach        # index of the glyph this one is attached to, or -1
	int attach_kind
	int attach_dx
	int attach_dy
	int syllable      # shaper-defined syllable number, or 0
	int subst         # otl_subst_* bits: how GSUB has changed the glyph
	int icat          # shaper-defined character category (Indic)
	int ipos          # shaper-defined position (Indic)

struct otl_buffer:
	int count
	int capacity
	otl_glyph* glyphs
	int next_lig_id

struct otl_ctx:
	ttf_font* font
	otl_buffer* buffer
	int table          # GSUB or GPOS offset
	int kind           # otl_gsub / otl_gpos
	int lookup_list
	int gdef_classes   # GDEF GlyphClassDef, or 0
	int gdef_attach    # GDEF MarkAttachClassDef, or 0
	int gdef_sets      # GDEF MarkGlyphSetsDef, or 0
	int flag           # current lookup flag
	int mark_set       # current mark filtering set
	int depth
	int budget         # remaining subtable applications before giving up
	int rtl
	int next           # position after a successful application
	int hb             # otl_mask_hb matching (see the flag)
	int manual_joiners
	int per_syllable
	int lookup_mask    # the current lookup's feature mask, flags removed
	int syllable       # syllable of the glyph the lookup started at

otl_buffer* otl_buffer_new(int capacity):
	otl_buffer* b = new otl_buffer
	if (capacity < 8): capacity = 8
	b.capacity = capacity
	b.glyphs = cast(otl_glyph*, malloc(capacity * sizeof(otl_glyph)))
	b.count = 0
	b.next_lig_id = 1
	return b

void otl_buffer_free(otl_buffer* b):
	if (b == 0): return
	free(b.glyphs)
	free(b)

void otl_reserve(otl_buffer* b, int need):
	if (need <= b.capacity): return
	int grown = b.capacity * 2
	if (grown < need): grown = need
	b.glyphs = cast(otl_glyph*, realloc(b.glyphs, b.capacity * sizeof(otl_glyph), grown * sizeof(otl_glyph)))
	b.capacity = grown

void otl_glyph_copy(otl_glyph* dst, otl_glyph* src):
	dst.gid = src.gid
	dst.cluster = src.cluster
	dst.cp = src.cp
	dst.mask = src.mask
	dst.props = src.props
	dst.unicode_mark = src.unicode_mark
	dst.lig_id = src.lig_id
	dst.lig_comp = src.lig_comp
	dst.x_advance = src.x_advance
	dst.y_advance = src.y_advance
	dst.x_offset = src.x_offset
	dst.y_offset = src.y_offset
	dst.attach = src.attach
	dst.attach_kind = src.attach_kind
	dst.attach_dx = src.attach_dx
	dst.attach_dy = src.attach_dy
	dst.syllable = src.syllable
	dst.subst = src.subst
	dst.icat = src.icat
	dst.ipos = src.ipos

# Append one glyph for codepoint cp at source cluster.
void otl_buffer_add(otl_buffer* b, int gid, int cp, int cluster, int mask):
	otl_reserve(b, b.count + 1)
	otl_glyph* g = &b.glyphs[b.count]
	g.gid = gid
	g.cluster = cluster
	g.cp = cp
	g.mask = mask
	g.props = otl_class_base
	g.unicode_mark = 0
	g.lig_id = 0
	g.lig_comp = 0
	g.x_advance = 0
	g.y_advance = 0
	g.x_offset = 0
	g.y_offset = 0
	g.attach = -1
	g.attach_kind = 0
	g.attach_dx = 0
	g.attach_dy = 0
	g.syllable = 0
	g.subst = 0
	g.icat = 0
	g.ipos = 0
	b.count = b.count + 1

void otl_buffer_delete(otl_buffer* b, int at):
	for i in range(at, b.count - 1): otl_glyph_copy(&b.glyphs[i], &b.glyphs[i + 1])
	b.count = b.count - 1

# Insert a copy of glyph at before position at.
void otl_buffer_insert_copy(otl_buffer* b, int at, int from):
	otl_reserve(b, b.count + 1)
	int i = b.count
	while (i > at):
		otl_glyph_copy(&b.glyphs[i], &b.glyphs[i - 1])
		i = i - 1
	if (from >= at): from = from + 1
	otl_glyph_copy(&b.glyphs[at], &b.glyphs[from])
	b.count = b.count + 1

void otl_buffer_reverse(otl_buffer* b):
	otl_glyph tmp
	int lo = 0
	int hi = b.count - 1
	while (lo < hi):
		otl_glyph_copy(&tmp, &b.glyphs[lo])
		otl_glyph_copy(&b.glyphs[lo], &b.glyphs[hi])
		otl_glyph_copy(&b.glyphs[hi], &tmp)
		lo = lo + 1
		hi = hi - 1

# A tag as a big-endian integer ("liga" -> 0x6c696761).
int otl_tag(char* s):
	return ((s[0] & 255) << 24) | ((s[1] & 255) << 16) | ((s[2] & 255) << 8) | (s[3] & 255)

int otl_tag_at(ttf_font* f, int off):
	return (ttf_u16(f, off) << 16) | ttf_u16(f, off + 2)

# ---- GDEF ----------------------------------------------------------------

void otl_ctx_init(otl_ctx* c, ttf_font* f, otl_buffer* b, int kind):
	c.font = f
	c.buffer = b
	c.kind = kind
	c.table = 0
	if (kind == otl_gsub): c.table = ttf_table(f, c"GSUB")
	else: c.table = ttf_table(f, c"GPOS")
	c.lookup_list = 0
	if (c.table != 0): c.lookup_list = c.table + ttf_u16(f, c.table + 8)
	c.gdef_classes = 0
	c.gdef_attach = 0
	c.gdef_sets = 0
	int gdef = ttf_table(f, c"GDEF")
	if (gdef != 0):
		if (ttf_u16(f, gdef + 4) != 0): c.gdef_classes = gdef + ttf_u16(f, gdef + 4)
		if (ttf_u16(f, gdef + 10) != 0): c.gdef_attach = gdef + ttf_u16(f, gdef + 10)
		if ((ttf_u32(f, gdef) >= 65538) && (ttf_u16(f, gdef + 12) != 0)): c.gdef_sets = gdef + ttf_u16(f, gdef + 12)
	c.flag = 0
	c.mark_set = 0
	c.depth = 0
	c.budget = 1000000
	c.rtl = 0
	c.next = 0
	c.hb = 0
	c.manual_joiners = 0
	c.per_syllable = 0
	c.lookup_mask = -1
	c.syllable = 0

int otl_has_gdef_classes(ttf_font* f):
	int gdef = ttf_table(f, c"GDEF")
	return (gdef != 0) && (ttf_u16(f, gdef + 4) != 0)

# Glyph class for gid: GDEF when the font has a GlyphClassDef, else the
# synthesized class (marks from the source text, everything else a base).
int otl_glyph_class(otl_ctx* c, otl_glyph* g):
	if (c.gdef_classes != 0):
		int cls = ttf_class(c.font, c.gdef_classes, g.gid)
		if ((cls >= 1) && (cls <= 4)): return cls
		return otl_class_base
	return g.props

# Refresh every glyph's class from GDEF (after mapping, before lookups).
void otl_set_classes(ttf_font* f, otl_buffer* b):
	otl_ctx c
	otl_ctx_init(&c, f, b, otl_gsub)
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		if (c.gdef_classes != 0): g.props = otl_glyph_class(&c, g)
		else if (g.unicode_mark): g.props = otl_class_mark
		else: g.props = otl_class_base

int otl_in_mark_set(otl_ctx* c, int set, int gid):
	if (c.gdef_sets == 0): return 0
	if (set >= ttf_u16(c.font, c.gdef_sets + 2)): return 0
	int cov = c.gdef_sets + ttf_u32(c.font, c.gdef_sets + 4 + set * 4)
	return ttf_coverage(c.font, cov, gid) >= 0

# Whether glyph i is skipped by the current lookup flag's glyph classes.
int otl_skip_props(otl_ctx* c, int i):
	otl_glyph* g = &c.buffer.glyphs[i]
	int cls = g.props
	if ((c.flag & 2) && (cls == otl_class_base)): return 1
	if ((c.flag & 4) && (cls == otl_class_ligature)): return 1
	if ((c.flag & 8) && (cls == otl_class_mark)): return 1
	if (cls == otl_class_mark):
		if (c.flag & 16):
			if (!otl_in_mark_set(c, c.mark_set, g.gid)): return 1
		else if (c.flag & 65280):
			if (c.gdef_attach == 0): return 1
			if (ttf_class(c.font, c.gdef_attach, g.gid) != ((c.flag >> 8) & 255)): return 1
	return 0

# Whether glyph i is skipped by the current lookup flag (legacy rules).
int otl_skip(otl_ctx* c, int i):
	if (otl_skip_props(c, i)): return 1
	otl_glyph* g = &c.buffer.glyphs[i]
	if (c.hb): return 0
	# Invisible controls never block a match, except ZWNJ, which exists to
	# break joining and ligatures. Positioning skips every unsubstituted
	# default ignorable, ZWNJ included (as HarfBuzz does), except ZWJ in
	# a manual-joiner feature ('mark', 'mkmk').
	if ((c.kind == otl_gpos) && (g.cp >= 0) && ((g.subst & otl_subst_substituted) == 0) && ut_default_ignorable(g.cp)): return (g.cp != 0x200d) || !c.manual_joiners
	if ((g.cp == 0x200d) || ((g.cp >= 0x180b) && (g.cp <= 0x180d)) || ((g.cp >= 0xfe00) && (g.cp <= 0xfe0f)) || (g.cp == 0x2060) || (g.cp == 0xfeff)): return 1
	return 0

int otl_next_index(otl_ctx* c, int i):
	int j = i + 1
	while (j < c.buffer.count):
		if (!otl_skip(c, j)): return j
		j = j + 1
	return -1

int otl_prev_index(otl_ctx* c, int i):
	int j = i - 1
	while (j >= 0):
		if (!otl_skip(c, j)): return j
		j = j - 1
	return -1

# ---- matching ----------------------------------------------------------

# Under hb rules, whether glyph g may be skipped when it does not match
# (HarfBuzz's SKIP_MAYBE): an unsubstituted default ignorable, except ZWNJ
# in GSUB input or manual-joiner context, ZWJ in manual-joiner input, and
# hidden characters (CGJ, Mongolian variation selectors, tags) in GSUB.
int otl_hb_ignorable(otl_ctx* c, otl_glyph* g, int context):
	int cp = g.cp
	if ((cp < 0) || (g.subst & otl_subst_substituted) || !ut_default_ignorable(cp)): return 0
	if (c.kind == otl_gpos): return (cp != 0x200d) || context || !c.manual_joiners
	if (cp == 0x200c): return context && !c.manual_joiners
	if (cp == 0x200d): return context || !c.manual_joiners
	if ((cp == 0x034f) || ((cp >= 0x180b) && (cp <= 0x180d)) || (cp == 0x180f) || ((cp >= 0xe0020) && (cp <= 0xe007f))): return 0
	return 1

int otl_match_item(otl_ctx* c, int how, int data, int base, int k, int class_def, int i);

# HarfBuzz's skipping iterator: the first glyph in direction dir from at
# that matches item k (input glyphs must carry the lookup mask, context
# glyphs need not), or -1 when a glyph that cannot be skipped fails.
int otl_hb_find(otl_ctx* c, int how, int data, int base, int k, int class_def, int at, int dir, int context):
	int j = at + dir
	while ((j >= 0) && (j < c.buffer.count)):
		if (otl_skip_props(c, j)):
			j = j + dir
			continue
		otl_glyph* g = &c.buffer.glyphs[j]
		int ok = context || ((g.mask & c.lookup_mask) != 0)
		if (c.per_syllable && (c.syllable != 0) && (g.syllable != c.syllable)): ok = 0
		if (ok && otl_match_item(c, how, data, base, k, class_def, j)): return j
		if (!otl_hb_ignorable(c, g, context)): return -1
		j = j + dir
	return -1

const int otl_match_glyph = 0
const int otl_match_class = 1
const int otl_match_coverage = 2

# Whether glyph i matches item k of a sequence: glyph ids or classes at
# data (u16 each), or Coverage offsets relative to base.
int otl_match_item(otl_ctx* c, int how, int data, int base, int k, int class_def, int i):
	int gid = c.buffer.glyphs[i].gid
	int value = ttf_u16(c.font, data + k * 2)
	if (how == otl_match_glyph): return gid == value
	if (how == otl_match_class): return ttf_class(c.font, class_def, gid) == value
	return ttf_coverage(c.font, base + value, gid) >= 0

# Under the legacy rules, the next input glyph after at for item k: ZWJ
# and variation selectors are skipped unless the sequence names them
# itself (an emoji ZWJ sequence's ligature lists its joiners), as
# HarfBuzz tries a default ignorable before skipping it.
int otl_legacy_next_input(otl_ctx* c, int how, int data, int base, int k, int class_def, int at):
	int j = at + 1
	while (j < c.buffer.count):
		if (!otl_skip(c, j)): return j
		if (!otl_skip_props(c, j) && otl_match_item(c, how, data, base, k, class_def, j)): return j
		j = j + 1
	return -1

# Match count items forward from after position start; positions get
# the matched indices. Returns 1 on a full match.
int otl_match_forward(otl_ctx* c, int how, int data, int base, int count, int class_def, int start, int32* positions):
	int at = start
	for k in range(count):
		if (c.hb): at = otl_hb_find(c, how, data, base, k, class_def, at, 1, 0)
		else: at = otl_legacy_next_input(c, how, data, base, k, class_def, at)
		if (at < 0): return 0
		if (!otl_match_item(c, how, data, base, k, class_def, at)): return 0
		positions[k] = at
	return 1

int otl_match_backward(otl_ctx* c, int how, int data, int base, int count, int class_def, int start):
	int at = start
	for k in range(count):
		if (c.hb): at = otl_hb_find(c, how, data, base, k, class_def, at, -1, 1)
		else: at = otl_prev_index(c, at)
		if (at < 0): return 0
		if (!otl_match_item(c, how, data, base, k, class_def, at)): return 0
	return 1

# Lookahead: count items after position start, positions not recorded.
int otl_match_forward_from(otl_ctx* c, int how, int data, int base, int count, int class_def, int start):
	int at = start
	for k in range(count):
		if (c.hb): at = otl_hb_find(c, how, data, base, k, class_def, at, 1, 1)
		else: at = otl_next_index(c, at)
		if (at < 0): return 0
		if (!otl_match_item(c, how, data, base, k, class_def, at)): return 0
	return 1

# ---- lookups -----------------------------------------------------------

int otl_apply_lookup_at(otl_ctx* c, int lookup_index, int i);

# Apply nested lookup records (seqIndex, lookupIndex) at the matched
# input positions; c.next ends up after the matched input.
void otl_apply_records_hb(otl_ctx* c, int records, int record_count, int32* positions, int input_count):
	# HarfBuzz's apply_lookup: glyphs a nested lookup adds are taken to
	# follow the current position (so later records can address them),
	# and removed ones the positions after it.
	int count = input_count
	int end = positions[count - 1] + 1
	for r in range(record_count):
		int idx = ttf_u16(c.font, records + r * 4)
		int lookup = ttf_u16(c.font, records + r * 4 + 2)
		if (idx >= count): continue
		int orig_len = c.buffer.count
		if (positions[idx] >= orig_len): continue
		int applied = 0
		c.depth = c.depth + 1
		if (c.depth <= otl_max_nesting): applied = otl_apply_lookup_at(c, lookup, positions[idx])
		c.depth = c.depth - 1
		if (!applied): continue
		int delta = c.buffer.count - orig_len
		if (delta == 0): continue
		end = end + delta
		if (end < positions[idx]):
			delta = delta + positions[idx] - end
			end = positions[idx]
		int next = idx + 1
		if (delta > 0):
			if (delta + count > 64): break
		else:
			if (delta < next - count): delta = next - count
			next = next - delta
		# Shift positions[next..count) by delta places.
		if (delta > 0):
			int k = count - 1
			while (k >= next):
				positions[k + delta] = positions[k]
				k = k - 1
		else:
			for k in range(next, count): positions[k + delta] = positions[k]
		next = next + delta
		count = count + delta
		for j in range(idx + 1, next): positions[j] = positions[j - 1] + 1
		while (next < count):
			positions[next] = positions[next] + delta
			next = next + 1
	if (end < 0): end = 0
	c.next = end

void otl_apply_records(otl_ctx* c, int records, int record_count, int32* positions, int input_count):
	int saved_flag = c.flag
	int saved_set = c.mark_set
	if (c.hb):
		otl_apply_records_hb(c, records, record_count, positions, input_count)
		c.flag = saved_flag
		c.mark_set = saved_set
		return
	for r in range(record_count):
		int seq = ttf_u16(c.font, records + r * 4)
		int lookup = ttf_u16(c.font, records + r * 4 + 2)
		if (seq >= input_count): continue
		int before = c.buffer.count
		int at = positions[seq]
		if (at >= c.buffer.count): continue
		c.depth = c.depth + 1
		if (c.depth <= otl_max_nesting): otl_apply_lookup_at(c, lookup, at)
		c.depth = c.depth - 1
		int delta = c.buffer.count - before
		if (delta != 0):
			for k in range(seq + 1, input_count): positions[k] = positions[k] + delta
	c.flag = saved_flag
	c.mark_set = saved_set
	int last = positions[input_count - 1]
	if (last < 0): last = 0
	if (last >= c.buffer.count): last = c.buffer.count - 1
	c.next = last + 1

# Context (GSUB 5 / GPOS 7) subtable at i.
int otl_context(otl_ctx* c, int sub, int i):
	ttf_font* f = c.font
	int format = ttf_u16(f, sub)
	int32[64] positions
	positions[0] = i
	int gid = c.buffer.glyphs[i].gid
	if ((format == 1) || (format == 2)):
		int index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), gid)
		if (index < 0): return 0
		int class_def = 0
		int sets = sub + 6
		int set_count = ttf_u16(f, sub + 4)
		int set_index = index
		int how = otl_match_glyph
		if (format == 2):
			class_def = sub + ttf_u16(f, sub + 4)
			set_count = ttf_u16(f, sub + 6)
			sets = sub + 8
			set_index = ttf_class(f, class_def, gid)
			how = otl_match_class
		if (set_index >= set_count): return 0
		int set_off = ttf_u16(f, sets + set_index * 2)
		if (set_off == 0): return 0
		int set = sub + set_off
		int rules = ttf_u16(f, set)
		for r in range(rules):
			int rule = set + ttf_u16(f, set + 2 + r * 2)
			int glyph_count = ttf_u16(f, rule)
			int record_count = ttf_u16(f, rule + 2)
			if ((glyph_count == 0) || (glyph_count > 64)): continue
			if (otl_match_forward(c, how, rule + 4, 0, glyph_count - 1, class_def, i, &positions[1])):
				otl_apply_records(c, rule + 4 + (glyph_count - 1) * 2, record_count, &positions[0], glyph_count)
				return 1
		return 0
	if (format == 3):
		int glyph_count = ttf_u16(f, sub + 2)
		int record_count = ttf_u16(f, sub + 4)
		if ((glyph_count == 0) || (glyph_count > 64)): return 0
		if (ttf_coverage(f, sub + ttf_u16(f, sub + 6), gid) < 0): return 0
		if (!otl_match_forward(c, otl_match_coverage, sub + 8, sub, glyph_count - 1, 0, i, &positions[1])): return 0
		otl_apply_records(c, sub + 6 + glyph_count * 2, record_count, &positions[0], glyph_count)
		return 1
	return 0

# Chaining context (GSUB 6 / GPOS 8) subtable at i.
int otl_chain_context(otl_ctx* c, int sub, int i):
	ttf_font* f = c.font
	int format = ttf_u16(f, sub)
	int32[64] positions
	positions[0] = i
	int gid = c.buffer.glyphs[i].gid
	if ((format == 1) || (format == 2)):
		int index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), gid)
		if (index < 0): return 0
		int back_def = 0
		int input_def = 0
		int ahead_def = 0
		int set_count = ttf_u16(f, sub + 4)
		int sets = sub + 6
		int set_index = index
		int how = otl_match_glyph
		if (format == 2):
			back_def = sub + ttf_u16(f, sub + 4)
			input_def = sub + ttf_u16(f, sub + 6)
			ahead_def = sub + ttf_u16(f, sub + 8)
			set_count = ttf_u16(f, sub + 10)
			sets = sub + 12
			set_index = ttf_class(f, input_def, gid)
			how = otl_match_class
		if (set_index >= set_count): return 0
		int set_off = ttf_u16(f, sets + set_index * 2)
		if (set_off == 0): return 0
		int set = sub + set_off
		int rules = ttf_u16(f, set)
		for r in range(rules):
			int rule = set + ttf_u16(f, set + 2 + r * 2)
			int back_count = ttf_u16(f, rule)
			int input_at = rule + 2 + back_count * 2
			int input_count = ttf_u16(f, input_at)
			if ((input_count == 0) || (input_count > 64)): continue
			int ahead_at = input_at + 2 + (input_count - 1) * 2
			int ahead_count = ttf_u16(f, ahead_at)
			int records_at = ahead_at + 2 + ahead_count * 2
			int record_count = ttf_u16(f, records_at)
			if (!otl_match_forward(c, how, input_at + 2, 0, input_count - 1, input_def, i, &positions[1])): continue
			if (!otl_match_backward(c, how, rule + 2, 0, back_count, back_def, i)): continue
			if (!otl_match_forward_from(c, how, ahead_at + 2, 0, ahead_count, ahead_def, positions[input_count - 1])): continue
			otl_apply_records(c, records_at + 2, record_count, &positions[0], input_count)
			return 1
		return 0
	if (format == 3):
		int back_count = ttf_u16(f, sub + 2)
		int input_at = sub + 4 + back_count * 2
		int input_count = ttf_u16(f, input_at)
		if ((input_count == 0) || (input_count > 64)): return 0
		int ahead_at = input_at + 2 + input_count * 2
		int ahead_count = ttf_u16(f, ahead_at)
		int records_at = ahead_at + 2 + ahead_count * 2
		int record_count = ttf_u16(f, records_at)
		if (ttf_coverage(f, sub + ttf_u16(f, input_at + 2), gid) < 0): return 0
		if (!otl_match_forward(c, otl_match_coverage, input_at + 4, sub, input_count - 1, 0, i, &positions[1])): return 0
		if (!otl_match_backward(c, otl_match_coverage, sub + 4, sub, back_count, 0, i)): return 0
		if (!otl_match_forward_from(c, otl_match_coverage, ahead_at + 2, sub, ahead_count, 0, positions[input_count - 1])): return 0
		otl_apply_records(c, records_at + 2, record_count, &positions[0], input_count)
		return 1
	return 0

# ---- GSUB --------------------------------------------------------------

void otl_set_gid(otl_ctx* c, int i, int gid):
	otl_glyph* g = &c.buffer.glyphs[i]
	g.gid = gid
	g.subst = g.subst | otl_subst_substituted
	if (c.gdef_classes != 0): g.props = otl_glyph_class(c, g)

int otl_single_subst(otl_ctx* c, int sub, int i):
	ttf_font* f = c.font
	int gid = c.buffer.glyphs[i].gid
	int index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), gid)
	if (index < 0): return 0
	int format = ttf_u16(f, sub)
	if (format == 1): otl_set_gid(c, i, (gid + ttf_u16(f, sub + 4)) & 65535)
	else if (format == 2):
		if (index >= ttf_u16(f, sub + 4)): return 0
		otl_set_gid(c, i, ttf_u16(f, sub + 6 + index * 2))
	else: return 0
	c.next = i + 1
	return 1

int otl_multiple_subst(otl_ctx* c, int sub, int i):
	ttf_font* f = c.font
	int index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), c.buffer.glyphs[i].gid)
	if ((index < 0) || (index >= ttf_u16(f, sub + 4))): return 0
	int seq = sub + ttf_u16(f, sub + 6 + index * 2)
	int n = ttf_u16(f, seq)
	if (n == 0):
		otl_buffer_delete(c.buffer, i)
		c.next = i
		return 1
	if (n > 64): return 0
	otl_set_gid(c, i, ttf_u16(f, seq + 2))
	for k in range(1, n):
		otl_buffer_insert_copy(c.buffer, i + k, i + k - 1)
		otl_glyph* g = &c.buffer.glyphs[i + k]
		g.cp = -1
		g.unicode_mark = 0
		otl_set_gid(c, i + k, ttf_u16(f, seq + 2 + k * 2))
	if (n > 1):
		# Like HarfBuzz, the outputs are numbered components (0-based) of
		# the sequence unless the glyph was inside a ligature.
		int numbered = c.buffer.glyphs[i].lig_id == 0
		for k in range(n):
			otl_glyph* out = &c.buffer.glyphs[i + k]
			out.subst = out.subst | otl_subst_multiplied
			if (numbered): out.lig_comp = k
	c.next = i + n
	return 1

int otl_alternate_subst(otl_ctx* c, int sub, int i):
	ttf_font* f = c.font
	int index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), c.buffer.glyphs[i].gid)
	if ((index < 0) || (index >= ttf_u16(f, sub + 4))): return 0
	int set = sub + ttf_u16(f, sub + 6 + index * 2)
	if (ttf_u16(f, set) == 0): return 0
	otl_set_gid(c, i, ttf_u16(f, set + 2))
	c.next = i + 1
	return 1

int otl_ligature_subst(otl_ctx* c, int sub, int i):
	ttf_font* f = c.font
	otl_buffer* b = c.buffer
	int index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), b.glyphs[i].gid)
	if ((index < 0) || (index >= ttf_u16(f, sub + 4))): return 0
	int set = sub + ttf_u16(f, sub + 6 + index * 2)
	int count = ttf_u16(f, set)
	int32[64] positions
	for l in range(count):
		int lig = set + ttf_u16(f, set + 2 + l * 2)
		int components = ttf_u16(f, lig + 2)
		if ((components == 0) || (components > 64)): continue
		if (!otl_match_forward(c, otl_match_glyph, lig + 4, 0, components - 1, 0, i, &positions[0])): continue
		if (c.hb && (components == 1)):
			# HarfBuzz substitutes a one-glyph ligature in place, not as a
			# ligature.
			otl_set_gid(c, i, ttf_u16(f, lig))
			c.next = i + 1
			return 1
		int last = i
		if (components > 1): last = positions[components - 2]
		# Skipped marks between components belong to the component before
		# them, for mark-to-ligature attachment.
		int lig_id = b.next_lig_id
		b.next_lig_id = b.next_lig_id + 1
		int component = 1
		int next_component = 0
		for j in range(i + 1, last + 1):
			if ((next_component < components - 1) && (j == positions[next_component])):
				component = component + 1
				next_component = next_component + 1
			else:
				b.glyphs[j].lig_id = lig_id
				b.glyphs[j].lig_comp = component
			if (b.glyphs[j].cluster < b.glyphs[i].cluster): b.glyphs[i].cluster = b.glyphs[j].cluster
		# The merged cluster also takes in glyphs after the last component
		# that shared its cluster (its marks), like HarfBuzz.
		int tail_cluster = b.glyphs[last].cluster
		int tail = last + 1
		while ((tail < b.count) && (b.glyphs[tail].cluster == tail_cluster)): tail = tail + 1
		for j in range(i + 1, tail): b.glyphs[j].cluster = b.glyphs[i].cluster
		int k = components - 2
		while (k >= 0):
			otl_buffer_delete(b, positions[k])
			k = k - 1
		otl_glyph* g = &b.glyphs[i]
		g.gid = ttf_u16(f, lig)
		g.lig_id = lig_id
		g.lig_comp = components
		g.subst = (g.subst | otl_subst_substituted | otl_subst_ligated) & ~otl_subst_multiplied
		if (components == 1): g.subst = g.subst & ~otl_subst_ligated
		if (c.gdef_classes != 0): g.props = otl_glyph_class(c, g)
		else if (components > 1): g.props = otl_class_ligature
		c.next = i + 1
		return 1
	return 0

int otl_reverse_chain_subst(otl_ctx* c, int sub, int i):
	ttf_font* f = c.font
	if (ttf_u16(f, sub) != 1): return 0
	int index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), c.buffer.glyphs[i].gid)
	if (index < 0): return 0
	int back_count = ttf_u16(f, sub + 4)
	int ahead_at = sub + 6 + back_count * 2
	int ahead_count = ttf_u16(f, ahead_at)
	int subst_at = ahead_at + 2 + ahead_count * 2
	if (index >= ttf_u16(f, subst_at)): return 0
	if (!otl_match_backward(c, otl_match_coverage, sub + 6, sub, back_count, 0, i)): return 0
	if (!otl_match_forward_from(c, otl_match_coverage, ahead_at + 2, sub, ahead_count, 0, i)): return 0
	otl_set_gid(c, i, ttf_u16(f, subst_at + 2 + index * 2))
	c.next = i - 1
	return 1

# ---- GPOS --------------------------------------------------------------

# Apply a ValueRecord at rec (ValueFormat format) to glyph i.
void otl_apply_value(otl_ctx* c, int rec, int format, int i):
	otl_glyph* g = &c.buffer.glyphs[i]
	int at = rec
	if (format & 1):
		g.x_offset = g.x_offset + ttf_s16(c.font, at)
		at = at + 2
	if (format & 2):
		g.y_offset = g.y_offset + ttf_s16(c.font, at)
		at = at + 2
	if (format & 4):
		g.x_advance = g.x_advance + ttf_s16(c.font, at)
		at = at + 2
	if (format & 8): g.y_advance = g.y_advance + ttf_s16(c.font, at)

int otl_single_pos(otl_ctx* c, int sub, int i):
	ttf_font* f = c.font
	int index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), c.buffer.glyphs[i].gid)
	if (index < 0): return 0
	int format = ttf_u16(f, sub)
	int value_format = ttf_u16(f, sub + 4)
	if (format == 1): otl_apply_value(c, sub + 6, value_format, i)
	else if (format == 2):
		if (index >= ttf_u16(f, sub + 6)): return 0
		otl_apply_value(c, sub + 8 + index * ttf_value_size(value_format), value_format, i)
	else: return 0
	c.next = i + 1
	return 1

int otl_pair_pos(otl_ctx* c, int sub, int i):
	ttf_font* f = c.font
	int index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), c.buffer.glyphs[i].gid)
	if (index < 0): return 0
	int j = otl_next_index(c, i)
	if (j < 0): return 0
	int right = c.buffer.glyphs[j].gid
	int format = ttf_u16(f, sub)
	int vf1 = ttf_u16(f, sub + 4)
	int vf2 = ttf_u16(f, sub + 6)
	int size1 = ttf_value_size(vf1)
	int size2 = ttf_value_size(vf2)
	int rec = -1
	if (format == 1):
		if (index >= ttf_u16(f, sub + 8)): return 0
		int set = sub + ttf_u16(f, sub + 10 + index * 2)
		int n = ttf_u16(f, set)
		int stride = 2 + size1 + size2
		int lo = 0
		int hi = n - 1
		while (lo <= hi):
			int mid = (lo + hi) / 2
			int at = set + 2 + mid * stride
			int g = ttf_u16(f, at)
			if (g == right):
				rec = at + 2
				lo = hi + 1
			else if (g < right): lo = mid + 1
			else: hi = mid - 1
	else if (format == 2):
		int c1 = ttf_class(f, sub + ttf_u16(f, sub + 8), c.buffer.glyphs[i].gid)
		int c2 = ttf_class(f, sub + ttf_u16(f, sub + 10), right)
		if ((c1 >= ttf_u16(f, sub + 12)) || (c2 >= ttf_u16(f, sub + 14))): return 0
		rec = sub + 16 + (c1 * ttf_u16(f, sub + 14) + c2) * (size1 + size2)
	if (rec < 0): return 0
	otl_apply_value(c, rec, vf1, i)
	otl_apply_value(c, rec + size1, vf2, j)
	c.next = j
	if (vf2 != 0): c.next = j + 1
	return 1

void otl_anchor(ttf_font* f, int anchor, int* x, int* y):
	x[0] = ttf_s16(f, anchor + 2)
	y[0] = ttf_s16(f, anchor + 4)

int otl_cursive_pos(otl_ctx* c, int sub, int i):
	ttf_font* f = c.font
	if (ttf_u16(f, sub) != 1): return 0
	int cov = sub + ttf_u16(f, sub + 2)
	int count = ttf_u16(f, sub + 4)
	int exit_index = ttf_coverage(f, cov, c.buffer.glyphs[i].gid)
	if ((exit_index < 0) || (exit_index >= count)): return 0
	int exit_off = ttf_u16(f, sub + 6 + exit_index * 4 + 2)
	if (exit_off == 0): return 0
	int j = otl_next_index(c, i)
	if (j < 0): return 0
	int entry_index = ttf_coverage(f, cov, c.buffer.glyphs[j].gid)
	if ((entry_index < 0) || (entry_index >= count)): return 0
	int entry_off = ttf_u16(f, sub + 6 + entry_index * 4)
	if (entry_off == 0): return 0
	int exit_x = 0
	int exit_y = 0
	int entry_x = 0
	int entry_y = 0
	otl_anchor(f, sub + exit_off, &exit_x, &exit_y)
	otl_anchor(f, sub + entry_off, &entry_x, &entry_y)
	otl_glyph* a = &c.buffer.glyphs[i]
	otl_glyph* b = &c.buffer.glyphs[j]
	if (c.rtl):
		# Visual order puts j left of i: i's entry edge meets j's exit.
		int d = exit_x + a.x_offset
		a.x_advance = a.x_advance - d
		a.x_offset = a.x_offset - d
		b.x_advance = entry_x + b.x_offset
	else:
		a.x_advance = exit_x + a.x_offset
		int d = entry_x + b.x_offset
		b.x_advance = b.x_advance - d
		b.x_offset = b.x_offset - d
	b.y_offset = a.y_offset + exit_y - entry_y
	c.next = j
	return 1

# Attach mark i to glyph target, aligning mark_anchor with base_anchor.
void otl_attach(otl_ctx* c, int i, int target, int mark_anchor, int base_anchor):
	int mx = 0
	int my = 0
	int bx = 0
	int by = 0
	otl_anchor(c.font, mark_anchor, &mx, &my)
	otl_anchor(c.font, base_anchor, &bx, &by)
	otl_glyph* g = &c.buffer.glyphs[i]
	g.attach = target
	g.attach_kind = otl_attach_gpos_mark
	# Like HarfBuzz, attaching replaces the mark's offset (later lookups
	# add to it). The vertical offset is resolved now, from the base's
	# offset at this point; only the horizontal one follows the base when
	# positioning finishes.
	g.attach_dx = bx - mx
	g.attach_dy = 0
	g.x_offset = 0
	g.y_offset = by - my + c.buffer.glyphs[target].y_offset

# The MarkRecord of mark i in a MarkArray: its class and anchor offset.
int otl_mark_record(otl_ctx* c, int mark_array, int index, int* anchor):
	if (index >= ttf_u16(c.font, mark_array)): return -1
	int rec = mark_array + 2 + index * 4
	anchor[0] = mark_array + ttf_u16(c.font, rec + 2)
	return ttf_u16(c.font, rec)

# A glyph's ligature component as HarfBuzz reads it: 0 on a ligature.
int otl_lig_comp(otl_glyph* g):
	if (g.subst & otl_subst_ligated): return 0
	return g.lig_comp

# HarfBuzz's MarkBasePos accept(): false for a later component of a
# multiple substitution's output that follows the earlier one.
int otl_accept_base(otl_buffer* b, int j):
	otl_glyph* g = &b.glyphs[j]
	if (((g.subst & otl_subst_multiplied) == 0) || (otl_lig_comp(g) == 0) || (j == 0)): return 1
	otl_glyph* p = &b.glyphs[j - 1]
	if ((p.props == otl_class_mark) || ((p.subst & otl_subst_multiplied) == 0)): return 1
	return (g.lig_id != p.lig_id) || (otl_lig_comp(g) != otl_lig_comp(p) + 1)

# MarkBasePos (4) and MarkLigPos (5): attach to the previous non-mark.
int otl_mark_base_pos(otl_ctx* c, int sub, int i, int ligature):
	ttf_font* f = c.font
	otl_buffer* b = c.buffer
	if (ttf_u16(f, sub) != 1): return 0
	int mark_index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), b.glyphs[i].gid)
	if (mark_index < 0): return 0
	int j = i - 1
	int base_cov = sub + ttf_u16(f, sub + 4)
	while (j >= 0):
		otl_glyph* g = &b.glyphs[j]
		int skip = (g.props == otl_class_mark) || ((g.cp >= 0) && ((g.subst & otl_subst_substituted) == 0) && ut_default_ignorable(g.cp) && ((g.cp != 0x200d) || !c.manual_joiners))
		# HarfBuzz attaches to the first glyph of a multiple substitution's
		# output, unless a later one is itself a covered base.
		if (!skip && !ligature && !otl_accept_base(b, j) && (ttf_coverage(f, base_cov, g.gid) < 0)): skip = 1
		if (!skip): break
		j = j - 1
	if (j < 0): return 0
	int base_index = ttf_coverage(f, base_cov, b.glyphs[j].gid)
	if (base_index < 0): return 0
	int class_count = ttf_u16(f, sub + 6)
	int mark_anchor = 0
	int cls = otl_mark_record(c, sub + ttf_u16(f, sub + 8), mark_index, &mark_anchor)
	if ((cls < 0) || (cls >= class_count)): return 0
	int array = sub + ttf_u16(f, sub + 10)
	if (base_index >= ttf_u16(f, array)): return 0
	int base_anchor = 0
	if (ligature):
		int attach = array + ttf_u16(f, array + 2 + base_index * 2)
		int components = ttf_u16(f, attach)
		if (components == 0): return 0
		int component = components
		otl_glyph* m = &b.glyphs[i]
		if ((m.lig_id != 0) && (m.lig_id == b.glyphs[j].lig_id) && (m.lig_comp > 0)): component = m.lig_comp
		if (component > components): component = components
		int off = ttf_u16(f, attach + 2 + ((component - 1) * class_count + cls) * 2)
		if (off == 0): return 0
		base_anchor = attach + off
	else:
		int off = ttf_u16(f, array + 2 + (base_index * class_count + cls) * 2)
		if (off == 0): return 0
		base_anchor = array + off
	otl_attach(c, i, j, mark_anchor, base_anchor)
	c.next = i + 1
	return 1

int otl_mark_mark_pos(otl_ctx* c, int sub, int i):
	ttf_font* f = c.font
	otl_buffer* b = c.buffer
	if (ttf_u16(f, sub) != 1): return 0
	int mark_index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), b.glyphs[i].gid)
	if (mark_index < 0): return 0
	# The previous mark is searched with the Ignore* bits cleared, so a
	# base glyph between the two marks stops the match (as in HarfBuzz).
	int flag = c.flag
	c.flag = flag & (~14)
	int j = otl_prev_index(c, i)
	c.flag = flag
	if ((j < 0) || (b.glyphs[j].props != otl_class_mark)): return 0
	# Both marks must sit on the same base (or ligature component), unless
	# one of them is itself a ligature (HarfBuzz's rule; a ligature glyph
	# counts as component 0).
	int id1 = b.glyphs[i].lig_id
	int id2 = b.glyphs[j].lig_id
	int comp1 = otl_lig_comp(&b.glyphs[i])
	int comp2 = otl_lig_comp(&b.glyphs[j])
	if (id1 == id2):
		if ((id1 != 0) && (comp1 != comp2)): return 0
	else if (!(((id1 > 0) && (comp1 == 0)) || ((id2 > 0) && (comp2 == 0)))): return 0
	int base_index = ttf_coverage(f, sub + ttf_u16(f, sub + 4), b.glyphs[j].gid)
	if (base_index < 0): return 0
	int class_count = ttf_u16(f, sub + 6)
	int mark_anchor = 0
	int cls = otl_mark_record(c, sub + ttf_u16(f, sub + 8), mark_index, &mark_anchor)
	if ((cls < 0) || (cls >= class_count)): return 0
	int array = sub + ttf_u16(f, sub + 10)
	if (base_index >= ttf_u16(f, array)): return 0
	int off = ttf_u16(f, array + 2 + (base_index * class_count + cls) * 2)
	if (off == 0): return 0
	otl_attach(c, i, j, mark_anchor, array + off)
	c.next = i + 1
	return 1

# ---- dispatch ----------------------------------------------------------

int otl_apply_subtable(otl_ctx* c, int type, int sub, int i):
	if (c.kind == otl_gsub):
		if (type == 7):
			type = ttf_u16(c.font, sub + 2)
			sub = sub + ttf_u32(c.font, sub + 4)
		if (type == 1): return otl_single_subst(c, sub, i)
		if (type == 2): return otl_multiple_subst(c, sub, i)
		if (type == 3): return otl_alternate_subst(c, sub, i)
		if (type == 4): return otl_ligature_subst(c, sub, i)
		if (type == 5): return otl_context(c, sub, i)
		if (type == 6): return otl_chain_context(c, sub, i)
		if (type == 8): return otl_reverse_chain_subst(c, sub, i)
		return 0
	if (type == 9):
		type = ttf_u16(c.font, sub + 2)
		sub = sub + ttf_u32(c.font, sub + 4)
	if (type == 1): return otl_single_pos(c, sub, i)
	if (type == 2): return otl_pair_pos(c, sub, i)
	if (type == 3): return otl_cursive_pos(c, sub, i)
	if (type == 4): return otl_mark_base_pos(c, sub, i, 0)
	if (type == 5): return otl_mark_base_pos(c, sub, i, 1)
	if (type == 6): return otl_mark_mark_pos(c, sub, i)
	if (type == 7): return otl_context(c, sub, i)
	if (type == 8): return otl_chain_context(c, sub, i)
	return 0

# Offset of lookup lookup_index, or 0. Sets c.flag and c.mark_set.
int otl_lookup(otl_ctx* c, int lookup_index):
	if ((c.lookup_list == 0) || (lookup_index >= ttf_u16(c.font, c.lookup_list))): return 0
	int lookup = c.lookup_list + ttf_u16(c.font, c.lookup_list + 2 + lookup_index * 2)
	c.flag = ttf_u16(c.font, lookup + 2)
	c.mark_set = 0
	if (c.flag & 16): c.mark_set = ttf_u16(c.font, lookup + 6 + ttf_u16(c.font, lookup + 4) * 2)
	return lookup

# The effective type of a lookup (through extension subtables).
int otl_lookup_type(otl_ctx* c, int lookup):
	int type = ttf_u16(c.font, lookup)
	if (((c.kind == otl_gsub) && (type == 7)) || ((c.kind == otl_gpos) && (type == 9))):
		if (ttf_u16(c.font, lookup + 4) == 0): return type
		int sub = lookup + ttf_u16(c.font, lookup + 6)
		return ttf_u16(c.font, sub + 2)
	return type

# Apply one lookup once at position i (for nested contextual records).
int otl_apply_lookup_at(otl_ctx* c, int lookup_index, int i):
	int lookup = otl_lookup(c, lookup_index)
	if (lookup == 0): return 0
	if (!c.hb && otl_skip(c, i)): return 0
	int type = ttf_u16(c.font, lookup)
	int subs = ttf_u16(c.font, lookup + 4)
	for s in range(subs):
		c.budget = c.budget - 1
		if (c.budget < 0): return 0
		if (otl_apply_subtable(c, type, lookup + ttf_u16(c.font, lookup + 6 + s * 2), i)): return 1
	return 0

# Apply one lookup across the buffer to glyphs carrying mask.
void otl_apply_lookup(otl_ctx* c, int lookup_index, int mask):
	int lookup = otl_lookup(c, lookup_index)
	if (lookup == 0): return
	c.hb = (mask & otl_mask_hb) != 0
	c.manual_joiners = (mask & otl_mask_manual_joiners) != 0
	c.per_syllable = (mask & otl_mask_per_syllable) != 0
	mask = mask & ~otl_mask_flags
	c.lookup_mask = mask
	int type = ttf_u16(c.font, lookup)
	int subs = ttf_u16(c.font, lookup + 4)
	int reverse = (c.kind == otl_gsub) && (otl_lookup_type(c, lookup) == 8)
	int i = 0
	if (reverse): i = c.buffer.count - 1
	while ((i >= 0) && (i < c.buffer.count)):
		int applied = 0
		if ((c.buffer.glyphs[i].mask & mask) && !otl_skip(c, i)):
			c.syllable = c.buffer.glyphs[i].syllable
			for s in range(subs):
				c.budget = c.budget - 1
				if (c.budget < 0): return
				c.depth = 0
				if (otl_apply_subtable(c, type, lookup + ttf_u16(c.font, lookup + 6 + s * 2), i)):
					applied = 1
					break
			# Nested records change the current lookup's flags; restore them.
			otl_lookup(c, lookup_index)
		if (reverse): i = i - 1
		else if (applied && (c.next > i)): i = c.next
		else: i = i + 1

# ---- feature selection -------------------------------------------------

# The LangSys table for the first script in scripts (4-byte tags,
# packed in one string, count of them) and language tag (0 = default).
int otl_langsys(ttf_font* f, int table, char* scripts, int script_count, int language):
	if (table == 0): return 0
	int list = table + ttf_u16(f, table + 4)
	int count = ttf_u16(f, list)
	for s in range(script_count):
		int want = otl_tag(&scripts[s * 4])
		for i in range(count):
			int rec = list + 2 + i * 6
			if (otl_tag_at(f, rec) != want): continue
			int script = list + ttf_u16(f, rec + 4)
			if (language != 0):
				int langs = ttf_u16(f, script + 2)
				for l in range(langs):
					int lrec = script + 4 + l * 6
					if (otl_tag_at(f, lrec) == language): return script + ttf_u16(f, lrec + 4)
			if (ttf_u16(f, script) != 0): return script + ttf_u16(f, script)
			return 0
	return 0

# A lookup index with the feature mask it applies under.
struct otl_lookup_entry:
	int index
	int mask

# Collect the lookups of features (tags[k] applied under masks[k]) for
# one stage, sorted by lookup index with masks of shared lookups merged.
# Returns the entry count; entries has room for max entries.
int otl_collect(ttf_font* f, int table, int langsys, int* tags, int* masks, int feature_count, otl_lookup_entry* entries, int max):
	if ((table == 0) || (langsys == 0)): return 0
	int features = table + ttf_u16(f, table + 6)
	int feature_total = ttf_u16(f, features)
	int n = 0
	int index_count = ttf_u16(f, langsys + 4)
	for k in range(feature_count):
		for x in range(index_count + 1):
			int feature_index = 0
			if (x == 0):
				# The required feature, under the first requested feature's mask.
				feature_index = ttf_u16(f, langsys + 2)
				if ((feature_index == 65535) || (k != 0)): continue
			else: feature_index = ttf_u16(f, langsys + 6 + (x - 1) * 2)
			if (feature_index >= feature_total): continue
			int rec = features + 2 + feature_index * 6
			if ((x != 0) && (otl_tag_at(f, rec) != tags[k])): continue
			int feature = features + ttf_u16(f, rec + 4)
			int lookups = ttf_u16(f, feature + 2)
			for l in range(lookups):
				int lookup = ttf_u16(f, feature + 4 + l * 2)
				int found = 0
				for e in range(n):
					if (entries[e].index == lookup):
						entries[e].mask = entries[e].mask | masks[k]
						found = 1
				if (found || (n >= max)): continue
				int at = n
				while ((at > 0) && (entries[at - 1].index > lookup)):
					entries[at].index = entries[at - 1].index
					entries[at].mask = entries[at - 1].mask
					at = at - 1
				entries[at].index = lookup
				entries[at].mask = masks[k]
				n = n + 1
	return n

# Apply one stage of features from table kind (otl_gsub / otl_gpos).
# Returns 1 when the font has the table and script, else 0.
int otl_apply_stage(ttf_font* f, otl_buffer* b, int kind, char* scripts, int script_count, int language, int* tags, int* masks, int feature_count, int rtl):
	otl_ctx c
	otl_ctx_init(&c, f, b, kind)
	c.rtl = rtl
	int langsys = otl_langsys(f, c.table, scripts, script_count, language)
	if (langsys == 0): return 0
	otl_lookup_entry* entries = cast(otl_lookup_entry*, malloc(512 * sizeof(otl_lookup_entry)))
	int n = otl_collect(f, c.table, langsys, tags, masks, feature_count, entries, 512)
	for e in range(n): otl_apply_lookup(&c, entries[e].index, entries[e].mask)
	free(entries)
	return 1

# Whether any requested feature exists for the script (table kind).
int otl_has_feature(ttf_font* f, int kind, char* scripts, int script_count, int tag):
	otl_ctx c
	otl_ctx_init(&c, f, 0, kind)
	int langsys = otl_langsys(f, c.table, scripts, script_count, 0)
	if (langsys == 0): return 0
	int features = c.table + ttf_u16(f, c.table + 6)
	int index_count = ttf_u16(f, langsys + 4)
	for x in range(index_count):
		int feature_index = ttf_u16(f, langsys + 6 + x * 2)
		if (feature_index >= ttf_u16(f, features)): continue
		if (otl_tag_at(f, features + 2 + feature_index * 6) == tag): return 1
	return 0

# The GSUB lookups of feature tag in the selected language system,
# ascending and without duplicates (the required feature is not
# included). Returns the count; out has room for max.
int otl_feature_lookups(ttf_font* f, char* scripts, int script_count, int language, int tag, int32* out, int max):
	int table = ttf_table(f, c"GSUB")
	int langsys = otl_langsys(f, table, scripts, script_count, language)
	if (langsys == 0): return 0
	int features = table + ttf_u16(f, table + 6)
	int feature_total = ttf_u16(f, features)
	int n = 0
	for x in range(ttf_u16(f, langsys + 4)):
		int feature_index = ttf_u16(f, langsys + 6 + x * 2)
		if (feature_index >= feature_total): continue
		int rec = features + 2 + feature_index * 6
		if (otl_tag_at(f, rec) != tag): continue
		int feature = features + ttf_u16(f, rec + 4)
		for l in range(ttf_u16(f, feature + 2)):
			int lookup = ttf_u16(f, feature + 4 + l * 2)
			int at = n
			int found = 0
			for e in range(n):
				if (out[e] == lookup): found = 1
			if (found || (n >= max)): continue
			while ((at > 0) && (out[at - 1] > lookup)):
				out[at] = out[at - 1]
				at = at - 1
			out[at] = lookup
			n = n + 1
	return n

# Whether the input sequence of a context rule (count items after the
# first glyph, how/class_def as in otl_match_item) matches glyphs[1..].
int otl_would_input(otl_ctx* c, int how, int data, int base, int class_def, int32* glyphs, int count):
	ttf_font* f = c.font
	for k in range(1, count):
		int value = ttf_u16(f, data + (k - 1) * 2)
		if (how == otl_match_glyph):
			if (glyphs[k] != value): return 0
		else if (how == otl_match_class):
			if (ttf_class(f, class_def, glyphs[k]) != value): return 0
		else if (ttf_coverage(f, base + value, glyphs[k]) < 0): return 0
	return 1

# The coverage table a GSUB subtable is keyed on (its first input
# glyph's), after resolving extensions.
int otl_subtable_coverage(otl_ctx* c, int type, int sub):
	ttf_font* f = c.font
	if (type == 7):
		type = ttf_u16(f, sub + 2)
		sub = sub + ttf_u32(f, sub + 4)
	int format = ttf_u16(f, sub)
	if ((type == 5) && (format == 3)): return sub + ttf_u16(f, sub + 6)
	if ((type == 6) && (format == 3)):
		int input_at = sub + 4 + ttf_u16(f, sub + 2) * 2
		return sub + ttf_u16(f, input_at + 2)
	return sub + ttf_u16(f, sub + 2)

# HarfBuzz's would_apply for one GSUB subtable: whether it would
# substitute exactly glyphs[0..count). zero_context rejects chaining
# rules with backtrack or lookahead. Like HarfBuzz, class-based and
# coverage-based contexts do not recheck the first glyph's coverage.
int otl_would_subtable(otl_ctx* c, int type, int sub, int32* glyphs, int count, int zero_context):
	ttf_font* f = c.font
	if (type == 7):
		type = ttf_u16(f, sub + 2)
		sub = sub + ttf_u32(f, sub + 4)
	int format = ttf_u16(f, sub)
	if ((type == 1) || (type == 2) || (type == 3) || (type == 8)):
		return (count == 1) && (ttf_coverage(f, sub + ttf_u16(f, sub + 2), glyphs[0]) >= 0)
	if (type == 4):
		int index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), glyphs[0])
		if ((index < 0) || (index >= ttf_u16(f, sub + 4))): return 0
		int set = sub + ttf_u16(f, sub + 6 + index * 2)
		for l in range(ttf_u16(f, set)):
			int lig = set + ttf_u16(f, set + 2 + l * 2)
			if (ttf_u16(f, lig + 2) != count): continue
			if (otl_would_input(c, otl_match_glyph, lig + 4, 0, 0, glyphs, count)): return 1
		return 0
	if ((type != 5) && (type != 6)): return 0
	if (format == 3):
		if (type == 5):
			if (ttf_u16(f, sub + 2) != count): return 0
			return otl_would_input(c, otl_match_coverage, sub + 8, sub, 0, glyphs, count)
		int back_count = ttf_u16(f, sub + 2)
		int input_at = sub + 4 + back_count * 2
		int input_count = ttf_u16(f, input_at)
		int ahead_count = ttf_u16(f, input_at + 2 + input_count * 2)
		if (zero_context && ((back_count != 0) || (ahead_count != 0))): return 0
		if (input_count != count): return 0
		return otl_would_input(c, otl_match_coverage, input_at + 4, sub, 0, glyphs, count)
	if ((format != 1) && (format != 2)): return 0
	int set_index = 0
	int set_count = 0
	int sets = 0
	int class_def = 0
	int how = otl_match_glyph
	if (format == 1):
		set_index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), glyphs[0])
		set_count = ttf_u16(f, sub + 4)
		sets = sub + 6
	else if (type == 5):
		class_def = sub + ttf_u16(f, sub + 4)
		set_index = ttf_class(f, class_def, glyphs[0])
		set_count = ttf_u16(f, sub + 6)
		sets = sub + 8
		how = otl_match_class
	else:
		class_def = sub + ttf_u16(f, sub + 6)
		set_index = ttf_class(f, class_def, glyphs[0])
		set_count = ttf_u16(f, sub + 10)
		sets = sub + 12
		how = otl_match_class
	if ((set_index < 0) || (set_index >= set_count)): return 0
	int set_off = ttf_u16(f, sets + set_index * 2)
	if (set_off == 0): return 0
	int set = sub + set_off
	for r in range(ttf_u16(f, set)):
		int rule = set + ttf_u16(f, set + 2 + r * 2)
		if (type == 5):
			if (ttf_u16(f, rule) != count): continue
			if (otl_would_input(c, how, rule + 4, 0, class_def, glyphs, count)): return 1
			continue
		int back_count = ttf_u16(f, rule)
		int input_at = rule + 2 + back_count * 2
		int input_count = ttf_u16(f, input_at)
		if (input_count == 0): continue
		int ahead_count = ttf_u16(f, input_at + 2 + (input_count - 1) * 2)
		if (zero_context && ((back_count != 0) || (ahead_count != 0))): continue
		if (input_count != count): continue
		if (otl_would_input(c, how, input_at + 2, 0, class_def, glyphs, count)): return 1
	return 0

# HarfBuzz's hb_ot_layout_lookup_would_substitute over a list of GSUB
# lookups: whether any would substitute glyphs[0..count) as a whole.
int otl_would_substitute(ttf_font* f, int32* lookups, int lookup_count, int32* glyphs, int count, int zero_context):
	if (count < 1): return 0
	otl_ctx c
	otl_ctx_init(&c, f, 0, otl_gsub)
	for l in range(lookup_count):
		int lookup = otl_lookup(&c, lookups[l])
		if (lookup == 0): continue
		int type = ttf_u16(f, lookup)
		int subs = ttf_u16(f, lookup + 4)
		# The lookup's coverage digest must have the first glyph.
		int covered = 0
		for s in range(subs):
			int sub = lookup + ttf_u16(f, lookup + 6 + s * 2)
			if (ttf_coverage(f, otl_subtable_coverage(&c, type, sub), glyphs[0]) >= 0): covered = 1
		if (!covered): continue
		for s in range(subs):
			if (otl_would_subtable(&c, type, lookup + ttf_u16(f, lookup + 6 + s * 2), glyphs, count, zero_context)): return 1
	return 0

# HarfBuzz's merge_clusters: glyphs start..end-1 take their smallest
# cluster, widened to whole clusters at both ends.
void otl_merge_clusters(otl_buffer* b, int start, int end):
	if (end > b.count): end = b.count
	if (end - start < 2): return
	int cluster = b.glyphs[start].cluster
	for i in range(start + 1, end):
		if (b.glyphs[i].cluster < cluster): cluster = b.glyphs[i].cluster
	if (cluster != b.glyphs[end - 1].cluster):
		while ((end < b.count) && (b.glyphs[end - 1].cluster == b.glyphs[end].cluster)): end = end + 1
	if (cluster != b.glyphs[start].cluster):
		while ((start > 0) && (b.glyphs[start - 1].cluster == b.glyphs[start].cluster)): start = start - 1
	for i in range(start, end): b.glyphs[i].cluster = cluster

# ---- finishing ---------------------------------------------------------

# Resolve mark attachments into offsets for the final visual direction;
# the buffer is still in logical order. Run after advances are final.
void otl_position_finish(otl_buffer* b, int rtl):
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		if (((g.attach_kind != otl_attach_mark) && (g.attach_kind != otl_attach_gpos_mark)) || (g.attach < 0) || (g.attach >= i)): continue
		otl_glyph* base = &b.glyphs[g.attach]
		int between = 0
		if (rtl):
			for k in range(g.attach + 1, i + 1): between = between + b.glyphs[k].x_advance
			g.x_offset = base.x_offset + g.attach_dx + g.x_offset + between
		else:
			for k in range(g.attach, i): between = between + b.glyphs[k].x_advance
			g.x_offset = base.x_offset + g.attach_dx + g.x_offset - between
		if (g.attach_kind == otl_attach_mark): g.y_offset = base.y_offset + g.attach_dy + g.y_offset
