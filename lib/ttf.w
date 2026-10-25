/*
lib.ttf: TrueType reader + rasterizer, used both at build time (the UI
atlas baker, tools/generate_ui_atlas.w) and at run time
(graphics.ui.font's ui_font_load_ttf, issue #379).

Covers: table directory, head (unitsPerEm, indexToLocFormat), maxp,
cmap formats 4 and 12, hhea/hmtx, post (underline metrics), OS/2
(strikeout metrics), long+short loca, and glyf outlines — simple
glyphs plus composites (offset, uniform/x-y/2x2 scaled components;
point-matched anchors fail loudly). Quadratic contours are flattened
to line segments and filled by the non-zero winding rule over 4x4
subsamples per pixel (unhinted grayscale coverage). 'OTTO' fonts with
CFF outlines load too: Type 2 charstrings with global and local
subroutines, name-keyed or CID-keyed (FDSelect), cubics flattened the
same way; ttf_glyph_bbox gives their control-point bounds. Glyphs
rasterize unhinted here; lib.ttf_hint adds an opt-in vertical light
autohinter for both outline formats, through the ttf_points recorder
below. ttf_subset handles only glyf fonts.

Fonts come from a path (ttf_load) or from bytes already in memory
(ttf_load_bytes, for hosts without a filesystem). Every table read is
bounds-checked against the blob, so a truncated or hostile file yields
zeros and a failed load rather than an out-of-bounds read.

Coordinates: rasterizer output is y-down bitmap space with integer
metrics — bearing_x (left edge relative to the pen), bearing_top
(rows above the baseline), advance in whole pixels.
*/
import lib.lib
import lib.stream
import structures.string
import lib.bytes
import lib.mem


struct ttf_font:
	char* data
	int size
	int upem
	int loc_long        # 1 = 32-bit loca entries, 0 = 16-bit halved
	int glyph_count
	int cmap4           # offset of the format-4 cmap subtable, or 0
	int cmap12          # offset of the format-12 cmap subtable, or 0
	int loca
	int glyf
	int hmtx
	int num_hmetrics
	int ascent          # font units, positive up
	int descent         # font units, positive (magnitude)
	int underline_pos   # font units, top of the underline, positive up
	int underline_thick # font units
	int strike_pos      # font units, top of the strikeout, positive up
	int strike_thick    # font units
	int kern            # offset of a format-0 kern subtable, or 0
	int kern_pairs      # its pair count
	int gpos_feature    # offset of the GPOS 'kern' Feature table, or 0
	int gpos_lookup_list # offset of the GPOS LookupList
	int cff             # offset of the 'CFF ' table ('OTTO' fonts), or 0
	int cff_charstrings # its CharStrings INDEX
	int cff_gsubrs      # its Global Subr INDEX
	int cff_subrs       # the Private DICT's local Subrs INDEX, or 0
	int cff_fdarray     # CID-keyed: the Font DICT INDEX, or 0
	int cff_fdselect    # CID-keyed: the FDSelect table
	char* hint_metrics  # lib.ttf_hint's per-face blue zones (one block), or 0


# Out-of-range reads yield 0: a truncated file degrades to a failed
# load or an empty glyph instead of reading past the blob.
int ttf_u8(ttf_font* f, int off):
	if ((off < 0) || (off >= f.size)): return 0
	return f.data[off] & 255


int ttf_u16(ttf_font* f, int off):
	return (ttf_u8(f, off) << 8) | ttf_u8(f, off + 1)


int ttf_s16(ttf_font* f, int off):
	int v = ttf_u16(f, off)
	if (v >= 32768): v = v - 65536
	return v


int ttf_u32(ttf_font* f, int off):
	return (ttf_u16(f, off) << 16) | ttf_u16(f, off + 2)


# Offset of a table by 4-char tag, or 0 when absent or not wholly
# inside the blob.
int ttf_table(ttf_font* f, char* tag):
	int count = ttf_u16(f, 4)
	for i in range(count):
		int rec = 12 + i * 16
		if ((ttf_u8(f, rec) == tag[0]) && (ttf_u8(f, rec + 1) == tag[1]) && (ttf_u8(f, rec + 2) == tag[2]) && (ttf_u8(f, rec + 3) == tag[3])):
			int off = ttf_u32(f, rec + 8)
			int length = ttf_u32(f, rec + 12)
			if ((off <= 0) || (length < 0) || (off > f.size - length)): return 0
			return off
	return 0


# Byte length of a table by tag, or 0 when absent.
int ttf_table_length(ttf_font* f, char* tag):
	int count = ttf_u16(f, 4)
	for i in range(count):
		int rec = 12 + i * 16
		if ((ttf_u8(f, rec) == tag[0]) && (ttf_u8(f, rec + 1) == tag[1]) && (ttf_u8(f, rec + 2) == tag[2]) && (ttf_u8(f, rec + 3) == tag[3])):
			return ttf_u32(f, rec + 12)
	return 0


# Read a whole file into memory. Returns the bytes (caller frees) and
# stores the length in size[0], or 0 after printing why.
char* ttf_read_file(char* path, int* size):
	wstream* in = stream_open_read(path)
	if (in == 0):
		print_error(c"ttf: cannot open ")
		print_error(path)
		print_error(c"\n")
		return 0
	string_builder* blob = string_new()
	stream_read_all(in, blob)
	stream_close(in)
	char* data = blob.data
	size[0] = blob.length
	free(blob)
	return data


int ttf_load_bytes(ttf_font* f, char* data, int size);
void ttf_index_kerning(ttf_font* f);
int ttf_cff_init(ttf_font* f);


# Load and index a TrueType file. Returns 1, or 0 after printing what
# was missing (bad path, absent table, no usable cmap). f owns the
# bytes; ttf_free releases them.
int ttf_load(ttf_font* f, char* path):
	int size = 0
	char* data = ttf_read_file(path, &size)
	if (data == 0): return 0
	if (ttf_load_bytes(f, data, size) == 0):
		free(data)
		f.data = 0
		return 0
	return 1


# Index a font already in memory. f borrows data (it is not copied):
# keep it alive while f is in use. Returns 1, or 0 after printing why.
int ttf_load_bytes(ttf_font* f, char* data, int size):
	f.data = data
	f.size = size
	f.hint_metrics = 0
	f.cmap4 = 0
	f.cmap12 = 0
	if (size < 12):
		print_error(c"ttf: file too short\n")
		return 0
	int version = ttf_u32(f, 0)
	f.cff = 0
	if (version == 1330926671):
		# 'OTTO': CFF (Type 2 charstring) outlines.
		f.cff = ttf_table(f, c"CFF ")
		if ((f.cff == 0) || !ttf_cff_init(f)):
			print_error(c"ttf: unreadable CFF table\n")
			return 0
	else if ((version != 65536) && (version != 1953658213)):
		# 0x00010000 or 'true'; collections are not single fonts.
		print_error(c"ttf: not a TrueType or OpenType font\n")
		return 0
	int head = ttf_table(f, c"head")
	int maxp = ttf_table(f, c"maxp")
	int cmap = ttf_table(f, c"cmap")
	int hhea = ttf_table(f, c"hhea")
	f.loca = ttf_table(f, c"loca")
	f.glyf = ttf_table(f, c"glyf")
	f.hmtx = ttf_table(f, c"hmtx")
	int outlines = (f.cff != 0) || ((f.loca != 0) && (f.glyf != 0))
	if ((head == 0) || (maxp == 0) || (cmap == 0) || (hhea == 0) || !outlines || (f.hmtx == 0)):
		print_error(c"ttf: required table missing (need head/maxp/cmap/hhea/hmtx and loca/glyf or CFF)\n")
		return 0
	f.upem = ttf_u16(f, head + 18)
	f.loc_long = ttf_u16(f, head + 50)
	f.glyph_count = ttf_u16(f, maxp + 4)
	f.ascent = ttf_s16(f, hhea + 4)
	f.descent = 0 - ttf_s16(f, hhea + 6)
	f.num_hmetrics = ttf_u16(f, hhea + 34)
	if ((f.upem < 16) || (f.num_hmetrics == 0)):
		print_error(c"ttf: implausible head/hhea values\n")
		return 0

	# Decoration metrics: post carries the underline, OS/2 the
	# strikeout. Fall back to the conventional proportions when a table
	# is absent (both are optional for rendering).
	f.underline_thick = f.upem / 14
	f.underline_pos = 0 - f.upem / 10
	f.strike_thick = f.underline_thick
	f.strike_pos = f.upem * 3 / 10
	int post = ttf_table(f, c"post")
	if (post != 0):
		int thick = ttf_s16(f, post + 10)
		if (thick > 0):
			f.underline_thick = thick
			f.underline_pos = ttf_s16(f, post + 8)
	int os2 = ttf_table(f, c"OS/2")
	if (os2 != 0):
		int s_thick = ttf_s16(f, os2 + 26)
		if (s_thick > 0):
			f.strike_thick = s_thick
			f.strike_pos = ttf_s16(f, os2 + 28)

	# Prefer a format-12 subtable (full Unicode); keep the first format-4
	# one for the BMP.
	int subtables = ttf_u16(f, cmap + 2)
	for i in range(subtables):
		int sub = cmap + ttf_u32(f, cmap + 4 + i * 8 + 4)
		int format = ttf_u16(f, sub)
		if ((format == 4) && (f.cmap4 == 0)): f.cmap4 = sub
		if ((format == 12) && (f.cmap12 == 0)): f.cmap12 = sub
	if ((f.cmap4 == 0) && (f.cmap12 == 0)):
		print_error(c"ttf: no format-4 or format-12 cmap subtable\n")
		return 0
	ttf_index_kerning(f)
	return 1


# Find the pair-kerning data: the GPOS 'kern' feature's lookups
# (modern fonts) and a legacy format-0 kern subtable. Both are optional;
# a font with neither simply never kerns.
void ttf_index_kerning(ttf_font* f):
	f.kern = 0
	f.kern_pairs = 0
	f.gpos_feature = 0
	f.gpos_lookup_list = 0
	int kern = ttf_table(f, c"kern")
	# Version-0 (Microsoft) kern: the first horizontal format-0
	# subtable. Apple's version-1 layout is not read.
	if ((kern != 0) && (ttf_u16(f, kern) == 0)):
		int tables = ttf_u16(f, kern + 2)
		int sub = kern + 4
		int t = 0
		while (t < tables):
			int length = ttf_u16(f, sub + 2)
			int coverage = ttf_u16(f, sub + 4)
			# format 0 in the high byte; horizontal, not minimum or
			# cross-stream.
			if (((coverage >> 8) == 0) && ((coverage & 7) == 1)):
				f.kern = sub + 6
				f.kern_pairs = ttf_u16(f, sub + 6)
				t = tables
			sub = sub + length
			t = t + 1
	int gpos = ttf_table(f, c"GPOS")
	if (gpos == 0): return
	int features = gpos + ttf_u16(f, gpos + 6)
	f.gpos_lookup_list = gpos + ttf_u16(f, gpos + 8)
	# The first 'kern' feature record: scripts list their own records,
	# but fonts point them all at the same lookups.
	int count = ttf_u16(f, features)
	int i = 0
	while (i < count):
		int rec = features + 2 + i * 6
		if ((ttf_u8(f, rec) == 'k') && (ttf_u8(f, rec + 1) == 'e') && (ttf_u8(f, rec + 2) == 'r') && (ttf_u8(f, rec + 3) == 'n')):
			f.gpos_feature = features + ttf_u16(f, rec + 4)
			i = count
		i = i + 1


# Coverage index of gid in a Coverage table, or -1.
int ttf_coverage(ttf_font* f, int cov, int gid):
	int format = ttf_u16(f, cov)
	int n = ttf_u16(f, cov + 2)
	int lo = 0
	int hi = n - 1
	while (lo <= hi):
		int mid = (lo + hi) / 2
		if (format == 1):
			int g = ttf_u16(f, cov + 4 + mid * 2)
			if (g == gid):
				return mid
			if (g < gid): lo = mid + 1
			else: hi = mid - 1
		else if (format == 2):
			int rec = cov + 4 + mid * 6
			if (gid < ttf_u16(f, rec)): hi = mid - 1
			else if (gid > ttf_u16(f, rec + 2)): lo = mid + 1
			else: return ttf_u16(f, rec + 4) + gid - ttf_u16(f, rec)
		else: return 0 - 1
	return 0 - 1


# Class of gid in a ClassDef table (0 when unlisted).
int ttf_class(ttf_font* f, int def, int gid):
	int format = ttf_u16(f, def)
	if (format == 1):
		int start = ttf_u16(f, def + 2)
		int n = ttf_u16(f, def + 4)
		if ((gid < start) || (gid >= start + n)): return 0
		return ttf_u16(f, def + 6 + (gid - start) * 2)
	if (format != 2): return 0
	int count = ttf_u16(f, def + 2)
	int lo = 0
	int hi = count - 1
	while (lo <= hi):
		int mid = (lo + hi) / 2
		int rec = def + 4 + mid * 6
		if (gid < ttf_u16(f, rec)): hi = mid - 1
		else if (gid > ttf_u16(f, rec + 2)): lo = mid + 1
		else: return ttf_u16(f, rec + 4)
	return 0


# Bytes in a ValueRecord of the given ValueFormat: two per set bit.
int ttf_value_size(int format):
	int size = 0
	for bit in range(8):
		if (format & (1 << bit)): size = size + 2
	return size


# The XAdvance field of a ValueRecord at rec, or 0 when the format has
# none (placement-only adjustments do not move the pen).
int ttf_value_x_advance(ttf_font* f, int rec, int format):
	if ((format & 4) == 0): return 0
	return ttf_s16(f, rec + ttf_value_size(format & 3))


# One PairPos subtable's x-advance adjustment for (left, right). Stores
# 1 in matched[0] when the subtable applies to the pair.
int ttf_pair_pos(ttf_font* f, int sub, int left, int right, int* matched):
	matched[0] = 0
	int format = ttf_u16(f, sub)
	int index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), left)
	if (index < 0): return 0
	int vf1 = ttf_u16(f, sub + 4)
	int vf2 = ttf_u16(f, sub + 6)
	int size1 = ttf_value_size(vf1)
	int size2 = ttf_value_size(vf2)
	if (format == 1):
		if (index >= ttf_u16(f, sub + 8)): return 0
		int set = sub + ttf_u16(f, sub + 10 + index * 2)
		int n = ttf_u16(f, set)
		int stride = 2 + size1 + size2
		int lo = 0
		int hi = n - 1
		while (lo <= hi):
			int mid = (lo + hi) / 2
			int rec = set + 2 + mid * stride
			int g = ttf_u16(f, rec)
			if (g == right):
				matched[0] = 1
				return ttf_value_x_advance(f, rec + 2, vf1)
			if (g < right): lo = mid + 1
			else: hi = mid - 1
		return 0
	if (format == 2):
		int c1 = ttf_class(f, sub + ttf_u16(f, sub + 8), left)
		int c2 = ttf_class(f, sub + ttf_u16(f, sub + 10), right)
		int class1_count = ttf_u16(f, sub + 12)
		int class2_count = ttf_u16(f, sub + 14)
		if ((c1 >= class1_count) || (c2 >= class2_count)): return 0
		matched[0] = 1
		int rec2 = sub + 16 + (c1 * class2_count + c2) * (size1 + size2)
		return ttf_value_x_advance(f, rec2, vf1)
	return 0


# Pair-kerning adjustment between two glyph ids, in font units
# (negative pulls the right glyph closer). GPOS 'kern' lookups when the
# font has them, else the legacy kern table; 0 when neither lists the
# pair.
int ttf_kern_table_units(ttf_font* f, int left, int right);

int ttf_kern_units(ttf_font* f, int left, int right):
	if (f.gpos_feature != 0):
		int total = 0
		int lookups = f.gpos_lookup_list
		int lookup_count = ttf_u16(f, lookups)
		int n = ttf_u16(f, f.gpos_feature + 2)
		for i in range(n):
			int index = ttf_u16(f, f.gpos_feature + 4 + i * 2)
			if (index >= lookup_count):
				return total
			int lookup = lookups + ttf_u16(f, lookups + 2 + index * 2)
			int type = ttf_u16(f, lookup)
			int subs = ttf_u16(f, lookup + 4)
			int s = 0
			while (s < subs):
				int sub = lookup + ttf_u16(f, lookup + 6 + s * 2)
				int sub_type = type
				if (type == 9):
					# Extension: the real subtable sits behind a 32-bit
					# offset.
					sub_type = ttf_u16(f, sub + 2)
					sub = sub + ttf_u32(f, sub + 4)
				int matched = 0
				if (sub_type == 2): total = total + ttf_pair_pos(f, sub, left, right, &matched)
				# The first subtable that applies ends the lookup.
				if (matched): s = subs
				s = s + 1
		return total
	return ttf_kern_table_units(f, left, right)

# Binary-search one format-0 kern subtable (pairs starts at nPairs).
int ttf_kern_pair_value(ttf_font* f, int pairs, int left, int right, int* found):
	int key = left * 65536 + right
	int lo = 0
	int hi = ttf_u16(f, pairs) - 1
	while (lo <= hi):
		int mid = (lo + hi) / 2
		int rec = pairs + 8 + mid * 6
		if (rec + 6 > f.size): return 0
		int k = ttf_u16(f, rec) * 65536 + ttf_u16(f, rec + 2)
		if (k == key):
			found[0] = 1
			return ttf_s16(f, rec + 4)
		if (k < key): lo = mid + 1
		else: hi = mid - 1
	return 0

# The legacy 'kern' table's value for the pair, ignoring GPOS: the sum
# over its horizontal format-0 subtables (an override subtable replaces
# the sum so far), as HarfBuzz applies them.
int ttf_kern_table_units(ttf_font* f, int left, int right):
	if (f.kern == 0): return 0
	int kern = ttf_table(f, c"kern")
	int tables = ttf_u16(f, kern + 2)
	int sub = kern + 4
	int total = 0
	for t in range(tables):
		if (sub + 6 > f.size): return total
		int length = ttf_u16(f, sub + 2)
		int coverage = ttf_u16(f, sub + 4)
		if (((coverage >> 8) == 0) && ((coverage & 7) == 1)):
			int found = 0
			int value = ttf_kern_pair_value(f, sub + 6, left, right, &found)
			if (found):
				if (coverage & 8): total = value
				else: total = total + value
		sub = sub + length
	return total


# Release the bytes ttf_load read. Not for ttf_load_bytes fonts, whose
# bytes belong to the caller.
void ttf_free(ttf_font* f):
	if (f.data != 0): free(f.data)
	if (f.hint_metrics != 0): free(f.hint_metrics)
	f.data = 0
	f.size = 0
	f.hint_metrics = 0


# Glyph id via a format-12 subtable: sequential groups of
# (start, end, start glyph).
int ttf_glyph_id_12(ttf_font* f, int code):
	int sub = f.cmap12
	int groups = ttf_u32(f, sub + 12)
	for i in range(groups):
		int rec = sub + 16 + i * 12
		int start = ttf_u32(f, rec)
		int end = ttf_u32(f, rec + 4)
		if ((code >= start) && (code <= end)): return ttf_u32(f, rec + 8) + (code - start)
	return 0


# Glyph id for a codepoint (0 = .notdef): format 12 when present, else
# format 4.
int ttf_glyph_id(ttf_font* f, int code):
	if (f.cmap12 != 0): return ttf_glyph_id_12(f, code)
	int sub = f.cmap4
	if (code > 65535): return 0
	int segs = ttf_u16(f, sub + 6) / 2
	int ends = sub + 14
	int starts = sub + 16 + segs * 2
	int deltas = sub + 16 + segs * 4
	int range_offsets = sub + 16 + segs * 6
	for i in range(segs):
		if (code <= ttf_u16(f, ends + i * 2)):
			int start = ttf_u16(f, starts + i * 2)
			if (code < start): return 0
			int delta = ttf_u16(f, deltas + i * 2)
			int range_offset = ttf_u16(f, range_offsets + i * 2)
			if (range_offset == 0): return (code + delta) & 65535
			int addr = range_offsets + i * 2 + range_offset + (code - start) * 2
			int gid = ttf_u16(f, addr)
			if (gid == 0): return 0
			return (gid + delta) & 65535
	return 0


# Advance width in font units.
int ttf_advance_units(ttf_font* f, int gid):
	int index = gid
	if (index >= f.num_hmetrics): index = f.num_hmetrics - 1
	return ttf_u16(f, f.hmtx + index * 4)


# Round font units to pixels at the given ppem (half-up).
int ttf_scale_round(ttf_font* f, int ppem, int units):
	int scaled = units * ppem * 2 / f.upem
	if (scaled >= 0): return (scaled + 1) / 2
	return 0 - ((1 - scaled) / 2)


# Decoration line geometry in pixels at ppem, y-down from the baseline:
# the line's top row (underline positive, below the baseline; strikeout
# negative, above it) and its thickness (at least one pixel).
int ttf_underline_top(ttf_font* f, int ppem):
	int top = 0 - ttf_scale_round(f, ppem, f.underline_pos)
	if (top < 1): top = 1
	return top


int ttf_underline_thickness(ttf_font* f, int ppem):
	int thick = ttf_scale_round(f, ppem, f.underline_thick)
	if (thick < 1): thick = 1
	return thick


int ttf_strikeout_top(ttf_font* f, int ppem):
	return 0 - ttf_scale_round(f, ppem, f.strike_pos)


int ttf_strikeout_thickness(ttf_font* f, int ppem):
	int thick = ttf_scale_round(f, ppem, f.strike_thick)
	if (thick < 1): thick = 1
	return thick


# Mild darkening of antialiased coverage so unhinted small text reads
# crisply on light backgrounds (255 and 0 stay fixed). Applied to every
# UI strike, baked or loaded at run time, so both look alike.
int ttf_boost_coverage(int v):
	return v + ((255 - v) * v * 2) / 765


int ttf_glyf_offset(ttf_font* f, int gid):
	if (f.loc_long): return ttf_u32(f, f.loca + gid * 4)
	return ttf_u16(f, f.loca + gid * 2) * 2


# A glyph's ink box in font units (y up): box[0..3] = xMin, yMin, xMax,
# yMax. Returns 0, with a zero box, for an empty or missing glyph.
int ttf_cff_bbox(ttf_font* f, int gid, int* box);

int ttf_glyph_bbox(ttf_font* f, int gid, int* box):
	for i in range(4): box[i] = 0
	if ((gid < 0) || (gid >= f.glyph_count)): return 0
	if (f.cff != 0): return ttf_cff_bbox(f, gid, box)
	int off = ttf_glyf_offset(f, gid)
	if (ttf_glyf_offset(f, gid + 1) <= off): return 0
	int at = f.glyf + off
	for i in range(4): box[i] = ttf_s16(f, at + 2 + i * 2)
	return 1


struct ttf_bitmap:
	char* pixels        # w*h coverage bytes, row-major, y-down; 0 when empty
	int w
	int h
	int bearing_x       # pixels from the pen to the bitmap's left edge
	int bearing_top     # bitmap rows above the baseline
	int advance         # pen advance in whole pixels


int ttf_floor(float32 v):
	int t = cast(int, v)
	if (cast(float32, t) > v): t = t - 1
	return t


int ttf_ceil(float32 v):
	int t = cast(int, v)
	if (cast(float32, t) < v): t = t + 1
	return t


# Outline points in font units (y up, after composite transforms), kept
# alongside the flattened segments when a hinter asks for them (a
# ttf_outline's points field). flags: bit 0 on-curve, bit 1 starts a
# contour.
struct ttf_points:
	float32* x
	float32* y
	char* flags
	int count
	int cap


void ttf_points_push(ttf_points* p, float32 x, float32 y, int flags):
	if (p.cap == 0):
		p.cap = 64
		p.count = 0
		p.x = cast(float32*, malloc(p.cap * 4))
		p.y = cast(float32*, malloc(p.cap * 4))
		p.flags = cast(char*, malloc(p.cap))
	if (p.count >= p.cap):
		int next = p.cap * 2
		p.x =cast(float32*, realloc(cast(char*, p.x), p.cap * 4, next * 4))
		p.y = cast(float32*, realloc(cast(char*, p.y), p.cap * 4, next * 4))
		p.flags = realloc(p.flags, p.cap, next)
		p.cap = next
	p.x[p.count] = x
	p.y[p.count] = y
	p.flags[p.count] = flags
	p.count = p.count + 1


# Segment accumulator used while flattening one glyph, in y-down pixel
# space with the baseline at 0. Grows on demand up to a hard ceiling
# (overflow flags a pathological outline).
struct ttf_outline:
	float32* xs0
	float32* ys0
	float32* xs1
	float32* ys1
	int count
	int cap
	int overflow
	float32 scale       # pixels per font unit
	float32 skew        # x += skew * height above the baseline (oblique)
	ttf_points* points  # also record the outline's points (hinting), or 0


void ttf_outline_push(ttf_outline* o, float32 x0, float32 y0, float32 x1, float32 y1):
	if (o.count >= o.cap):
		if (o.cap >= 262144):
			o.overflow = 1
			return
		int next = o.cap * 2
		o.xs0 = cast(float32*, realloc(cast(char*, o.xs0), o.cap * 4, next * 4))
		o.ys0 = cast(float32*, realloc(cast(char*, o.ys0), o.cap * 4, next * 4))
		o.xs1 = cast(float32*, realloc(cast(char*, o.xs1), o.cap * 4, next * 4))
		o.ys1 = cast(float32*, realloc(cast(char*, o.ys1), o.cap * 4, next * 4))
		o.cap = next
	o.xs0[o.count] = x0
	o.ys0[o.count] = y0
	o.xs1[o.count] = x1
	o.ys1[o.count] = y1
	o.count = o.count + 1


# Flatten one quadratic (p0, control, p1) into 8 line segments.
void ttf_outline_quad(ttf_outline* o, float32 x0, float32 y0, float32 cx, float32 cy, float32 x1, float32 y1):
	float32 px = x0
	float32 py = y0
	for i in range(1, 8 + 1):
		float32 t = cast(float32, i) / 8.0
		float32 u = 1.0 - t
		float32 qx = u * u * x0 + 2.0 * u * t * cx + t * t * x1
		float32 qy = u * u * y0 + 2.0 * u * t * cy + t * t * y1
		ttf_outline_push(o, px, py, qx, qy)
		px = qx
		py = qy


void ttf_render_contour(ttf_outline* o, char* flags, float32* px, float32* py, int start, int n);
int ttf_fill(ttf_outline* o, ttf_bitmap* out);


# A component transform in font units: x' = a*x + c*y + dx,
# y' = b*x + d*y + dy.
struct ttf_xform:
	float32 a
	float32 b
	float32 c
	float32 d
	float32 dx
	float32 dy


float32 ttf_f2dot14(ttf_font* f, int off):
	return cast(float32, ttf_s16(f, off)) / 16384.0


int ttf_add_glyph(ttf_font* f, ttf_outline* o, int gid, ttf_xform* m, int depth);


# Append a simple glyph's contours, transformed by m. Returns 1, or 0
# on a malformed outline.
int ttf_add_simple(ttf_font* f, ttf_outline* o, int off, int contours, ttf_xform* m):
	# Contour end indices, then the flag/coordinate streams.
	int* contour_end = cast(int*, malloc((contours + 1) * __word_size__))
	int i = 0
	int point_count = 0
	while (i < contours):
		contour_end[i] = ttf_u16(f, off + 10 + i * 2)
		if (contour_end[i] + 1 < point_count):
			free(cast(char*, contour_end))
			print_error(c"ttf: contour end points out of order\n")
			return 0
		point_count = contour_end[i] + 1
		i = i + 1
	int instruction_length = ttf_u16(f, off + 10 + contours * 2)
	int pos = off + 12 + contours * 2 + instruction_length

	char* flags = cast(char*, malloc(point_count + 1))
	i = 0
	while (i < point_count):
		int flag = ttf_u8(f, pos)
		pos = pos + 1
		flags[i] = flag
		i = i + 1
		if (flag & 8):
			int repeat = ttf_u8(f, pos)
			pos = pos + 1
			int r = 0
			while ((r < repeat) && (i < point_count)):
				flags[i] = flag
				i = i + 1
				r = r + 1

	# Absolute coordinates in font units.
	int* ux = cast(int*, malloc((point_count + 1) * __word_size__))
	int* uy = cast(int*, malloc((point_count + 1) * __word_size__))
	int value = 0
	i = 0
	while (i < point_count):
		int flag2 = flags[i] & 255
		if (flag2 & 2):
			int dx = ttf_u8(f, pos)
			pos = pos + 1
			if (flag2 & 16): value = value + dx
			else: value = value - dx
		else if ((flag2 & 16) == 0):
			value = value + ttf_s16(f, pos)
			pos = pos + 2
		ux[i] = value
		i = i + 1
	value = 0
	i = 0
	while (i < point_count):
		int flag3 = flags[i] & 255
		if (flag3 & 4):
			int dy = ttf_u8(f, pos)
			pos = pos + 1
			if (flag3 & 32): value = value + dy
			else: value = value - dy
		else if ((flag3 & 32) == 0):
			value = value + ttf_s16(f, pos)
			pos = pos + 2
		uy[i] = value
		i = i + 1

	# Transform into pixel space: y-down, baseline at 0, oblique skew
	# applied last so composites lean as one.
	float32* px = cast(float32*, malloc((point_count + 1) * 4))
	float32* py = cast(float32*, malloc((point_count + 1) * 4))
	i = 0
	while (i < point_count):
		float32 fx = cast(float32, ux[i])
		float32 fy = cast(float32, uy[i])
		float32 tx = (m.a * fx + m.c * fy + m.dx) * o.scale
		float32 ty = (m.b * fx + m.d * fy + m.dy) * o.scale
		px[i] = tx + o.skew * ty
		py[i] = 0.0 - ty
		i = i + 1
	if (o.points != 0):
		int first = 0
		for c in range(contours):
			if (contour_end[c] - first + 1 >= 2):
				for k in range(first, contour_end[c] + 1):
					float32 kx = cast(float32, ux[k])
					float32 ky = cast(float32, uy[k])
					int kind = flags[k] & 1
					if (k == first): kind = kind | 2
					ttf_points_push(o.points, m.a * kx + m.c * ky + m.dx, m.b * kx + m.d * ky + m.dy, kind)
			first = contour_end[c] + 1

	int start = 0
	for c in range(contours):
		int end = contour_end[c]
		int n = end - start + 1
		if (n >= 2): ttf_render_contour(o, flags, px, py, start, n)
		start = end + 1

	free(cast(char*, contour_end))
	free(flags)
	free(cast(char*, ux))
	free(cast(char*, uy))
	free(cast(char*, px))
	free(cast(char*, py))
	return 1


# Append a composite glyph: each component is another glyph placed by
# an offset and an optional scale or 2x2 matrix, composed with m.
int ttf_add_composite(ttf_font* f, ttf_outline* o, int off, ttf_xform* m, int depth):
	int pos = off + 10
	int more = 1
	while (more):
		int flags = ttf_u16(f, pos)
		int component = ttf_u16(f, pos + 2)
		pos = pos + 4
		int arg1 = 0
		int arg2 = 0
		if (flags & 1):
			arg1 = ttf_s16(f, pos)
			arg2 = ttf_s16(f, pos + 2)
			pos = pos + 4
		else:
			arg1 = ttf_u8(f, pos)
			arg2 = ttf_u8(f, pos + 1)
			if (arg1 >= 128): arg1 = arg1 - 256
			if (arg2 >= 128): arg2 = arg2 - 256
			pos = pos + 2
		if ((flags & 2) == 0):
			print_error(c"ttf: point-matched composite components are not supported\n")
			return 0
		ttf_xform local
		local.a = 1.0
		local.b = 0.0
		local.c = 0.0
		local.d = 1.0
		if (flags & 8):
			local.a = ttf_f2dot14(f, pos)
			local.d = local.a
			pos = pos + 2
		else if (flags & 64):
			local.a = ttf_f2dot14(f, pos)
			local.d = ttf_f2dot14(f, pos + 2)
			pos = pos + 4
		else if (flags & 128):
			local.a = ttf_f2dot14(f, pos)
			local.b = ttf_f2dot14(f, pos + 2)
			local.c = ttf_f2dot14(f, pos + 4)
			local.d = ttf_f2dot14(f, pos + 6)
			pos = pos + 8
		local.dx = cast(float32, arg1)
		local.dy = cast(float32, arg2)
		# Compose: parent m applied after the component's own transform.
		ttf_xform both
		both.a = m.a * local.a + m.c * local.b
		both.b = m.b * local.a + m.d * local.b
		both.c = m.a * local.c + m.c * local.d
		both.d = m.b * local.c + m.d * local.d
		both.dx = m.a * local.dx + m.c * local.dy + m.dx
		both.dy = m.b * local.dx + m.d * local.dy + m.dy
		if (ttf_add_glyph(f, o, component, &both, depth + 1) == 0): return 0
		more = flags & 32
	return 1


# Append glyph gid's outline, transformed by m. Returns 1 (an empty
# glyph appends nothing), or 0 after printing why.
int ttf_cff_add(ttf_font* f, ttf_outline* o, int gid, ttf_xform* m);

int ttf_add_glyph(ttf_font* f, ttf_outline* o, int gid, ttf_xform* m, int depth):
	if ((gid < 0) || (gid >= f.glyph_count)):
		print_error(c"ttf: glyph id out of range\n")
		return 0
	if (f.cff != 0): return ttf_cff_add(f, o, gid, m)
	if (depth > 8):
		print_error(c"ttf: composite glyphs nested too deeply\n")
		return 0
	int off = ttf_glyf_offset(f, gid)
	int next = ttf_glyf_offset(f, gid + 1)
	if (off == next): return 1
	off = f.glyf + off
	int contours = ttf_s16(f, off)
	if (contours < 0): return ttf_add_composite(f, o, off, m, depth)
	return ttf_add_simple(f, o, off, contours, m)


# Rasterize one glyph at ppem into out, leaning it by skew (pixels of
# x per pixel of height above the baseline; 0 for upright). Returns 1
# on success (an inkless glyph like space yields w = h = 0 with a
# valid advance), 0 on a malformed or unsupported outline (printed to
# stderr).
int ttf_rasterize_skewed(ttf_font* f, int gid, int ppem, float32 skew, ttf_bitmap* out):
	out.pixels = 0
	out.w = 0
	out.h = 0
	out.bearing_x = 0
	out.bearing_top = 0
	out.advance = ttf_scale_round(f, ppem, ttf_advance_units(f, gid))

	ttf_outline outline
	outline.cap = 1024
	outline.count = 0
	outline.overflow = 0
	outline.xs0 = cast(float32*, malloc(outline.cap * 4))
	outline.ys0 = cast(float32*, malloc(outline.cap * 4))
	outline.xs1 = cast(float32*, malloc(outline.cap * 4))
	outline.ys1 = cast(float32*, malloc(outline.cap * 4))
	outline.scale = cast(float32, ppem) / cast(float32, f.upem)
	outline.skew = skew
	outline.points = 0
	ttf_xform identity
	identity.a = 1.0
	identity.b = 0.0
	identity.c = 0.0
	identity.d = 1.0
	identity.dx = 0.0
	identity.dy = 0.0

	int ok = ttf_add_glyph(f, &outline, gid, &identity, 0)
	if (ok): ok = ttf_fill(&outline, out)
	free(cast(char*, outline.xs0))
	free(cast(char*, outline.ys0))
	free(cast(char*, outline.xs1))
	free(cast(char*, outline.ys1))
	return ok


# Upright rasterization (the atlas baker's entry point).
int ttf_rasterize(ttf_font* f, int gid, int ppem, ttf_bitmap* out):
	return ttf_rasterize_skewed(f, gid, ppem, 0.0, out)


float32 ttf_px(float32* px, int start, int n, int index):
	return px[start + index % n]


float32 ttf_py(float32* py, int start, int n, int index):
	return py[start + index % n]


int ttf_on_curve(char* flags, int start, int n, int index):
	return flags[start + index % n] & 1


# Emit one contour's segments. Walks point runs handling the implied
# on-curve midpoint between consecutive off-curve control points.
void ttf_render_contour(ttf_outline* o, char* flags, float32* px, float32* py, int start, int n):
	# Find an on-curve starting point; a contour of only off-curve
	# points starts from the implied midpoint of the first pair.
	int first = 0 - 1
	int i = 0
	while (i < n):
		if (ttf_on_curve(flags, start, n, i)):
			first = i
			i = n
		i = i + 1
	float32 sx = 0.0
	float32 sy = 0.0
	if (first < 0):
		first = 0
		sx = (ttf_px(px, start, n, 0) + ttf_px(px, start, n, 1)) * 0.5
		sy = (ttf_py(py, start, n, 0) + ttf_py(py, start, n, 1)) * 0.5
	else:
		sx = ttf_px(px, start, n, first)
		sy = ttf_py(py, start, n, first)

	float32 cur_x = sx
	float32 cur_y = sy
	int have_ctrl = 0
	float32 ctrl_x = 0.0
	float32 ctrl_y = 0.0
	int step = 1
	while (step <= n):
		int index = first + step
		float32 x = ttf_px(px, start, n, index)
		float32 y = ttf_py(py, start, n, index)
		if (ttf_on_curve(flags, start, n, index)):
			if (have_ctrl):
				ttf_outline_quad(o, cur_x, cur_y, ctrl_x, ctrl_y, x, y)
				have_ctrl = 0
			else: ttf_outline_push(o, cur_x, cur_y, x, y)
			cur_x = x
			cur_y = y
		else:
			if (have_ctrl):
				# Two off-curve points in a row: implied on-curve
				# midpoint closes the previous quadratic.
				float32 mx = (ctrl_x + x) * 0.5
				float32 my = (ctrl_y + y) * 0.5
				ttf_outline_quad(o, cur_x, cur_y, ctrl_x, ctrl_y, mx, my)
				cur_x = mx
				cur_y = my
			ctrl_x = x
			ctrl_y = y
			have_ctrl = 1
		step = step + 1
	# Close back to the start point.
	if (have_ctrl): ttf_outline_quad(o, cur_x, cur_y, ctrl_x, ctrl_y, sx, sy)
	else if ((cur_x != sx) || (cur_y != sy)): ttf_outline_push(o, cur_x, cur_y, sx, sy)


# Scanline-fill the flattened outline: per subsample row, gather the
# non-zero-winding crossing intervals and accumulate 4x4 coverage.
int ttf_fill(ttf_outline* o, ttf_bitmap* out):
	if (o.count == 0): return 1
	if (o.overflow):
		print_error(c"ttf: outline segment cap exceeded\n")
		return 0
	float32 min_x = o.xs0[0]
	float32 max_x = o.xs0[0]
	float32 min_y = o.ys0[0]
	float32 max_y = o.ys0[0]
	int i = 0
	while (i < o.count):
		if (o.xs0[i] < min_x): min_x = o.xs0[i]
		if (o.xs0[i] > max_x): max_x = o.xs0[i]
		if (o.xs1[i] < min_x): min_x = o.xs1[i]
		if (o.xs1[i] > max_x): max_x = o.xs1[i]
		if (o.ys0[i] < min_y): min_y = o.ys0[i]
		if (o.ys0[i] > max_y): max_y = o.ys0[i]
		if (o.ys1[i] < min_y): min_y = o.ys1[i]
		if (o.ys1[i] > max_y): max_y = o.ys1[i]
		i = i + 1

	int left = ttf_floor(min_x) - 1
	int top = ttf_floor(min_y) - 1
	int right = ttf_ceil(max_x) + 1
	int bottom = ttf_ceil(max_y) + 1
	int w = right - left
	int h = bottom - top
	if ((w <= 0) || (h <= 0) || (w > 2048) || (h > 2048)):
		print_error(c"ttf: implausible glyph bitmap size\n")
		return 0

	int* acc = cast(int*, malloc(w * h * __word_size__))
	i = 0
	while (i < w * h):
		acc[i] = 0
		i = i + 1

	# Crossing buffers, far above any real per-row crossing count.
	float32* cross_x = cast(float32*, malloc(256 * 4))
	int* cross_dir = cast(int*, malloc(256 * __word_size__))

	int sub_rows = h * 4
	for row in range(sub_rows):
		float32 y = cast(float32, top) + (cast(float32, row) + 0.5) / 4.0
		int crossings = 0
		i = 0
		while (i < o.count):
			float32 y0 = o.ys0[i]
			float32 y1 = o.ys1[i]
			int dir = 0
			if ((y0 <= y) && (y1 > y)): dir = 1
			else if ((y1 <= y) && (y0 > y)): dir = 0 - 1
			if ((dir != 0) && (crossings < 256)):
				float32 t = (y - y0) / (y1 - y0)
				cross_x[crossings] = o.xs0[i] + t * (o.xs1[i] - o.xs0[i])
				cross_dir[crossings] = dir
				crossings = crossings + 1
			i = i + 1
		# Insertion sort by x.
		i = 1
		while (i < crossings):
			float32 kx = cross_x[i]
			int kd = cross_dir[i]
			int j = i - 1
			while ((j >= 0) && (cross_x[j] > kx)):
				cross_x[j + 1] = cross_x[j]
				cross_dir[j + 1] = cross_dir[j]
				j = j - 1
			cross_x[j + 1] = kx
			cross_dir[j + 1] = kd
			i = i + 1
		# Between consecutive sorted crossings the winding is constant;
		# accumulate the nonzero spans into this row's pixels.
		int winding = 0
		int row_base = (row / 4) * w
		i = 0
		while (i < crossings - 1):
			winding = winding + cross_dir[i]
			if (winding != 0):
				# Subcolumn centers (s + 0.5) / 4 within [xa, xb),
				# in bitmap-local x.
				float32 xa = cross_x[i] - cast(float32, left)
				float32 xb = cross_x[i + 1] - cast(float32, left)
				int s0 = ttf_ceil(xa * 4.0 - 0.5)
				int s1 = ttf_ceil(xb * 4.0 - 0.5) - 1
				if (s0 < 0): s0 = 0
				if (s1 > w * 4 - 1): s1 = w * 4 - 1
				for s in range(s0, s1 + 1): acc[row_base + s / 4] = acc[row_base + s / 4] + 1
			i = i + 1

	free(cast(char*, cross_x))
	free(cast(char*, cross_dir))

	out.pixels = cast(char*, malloc(w * h))
	i = 0
	while (i < w * h):
		int coverage = acc[i] * 255 / 16
		if (coverage > 255): coverage = 255
		out.pixels[i] = coverage
		i = i + 1
	free(cast(char*, acc))
	out.w = w
	out.h = h
	out.bearing_x = left
	out.bearing_top = 0 - top
	return 1


# ---- subsetting -----------------------------------------------------
#
# ttf_subset writes a minimal TrueType font holding just the glyphs a
# set of codepoints needs (plus .notdef and composite components), with
# hinting instructions stripped and kerning flattened into a format-0
# kern table. The UI atlas baker uses it to embed its default faces in
# graphics/ui/font_data.w small enough to compile into every UI program.


# Append bytes [off, off + length) of the font.
void ttf_put_range(string_builder* b, ttf_font* f, int off, int length):
	for i in range(length): string_append_char(b, ttf_u8(f, off + i))


void ttf_pad4(string_builder* b):
	while (b.length % 4 != 0): string_append_char(b, 0)


# glyf bytes of gid: offset (absolute) in off[0], length returned.
int ttf_glyph_span(ttf_font* f, int gid, int* off):
	int start = ttf_glyf_offset(f, gid)
	int end = ttf_glyf_offset(f, gid + 1)
	off[0] = f.glyf + start
	if (end < start): return 0
	return end - start


# Byte size of a composite component record with the given flags
# (flags, glyph index, the two args, and its transform).
int ttf_component_size(int flags):
	int size = 4
	if (flags & 1): size = size + 4
	else: size = size + 2
	if (flags & 8): size = size + 2
	else if (flags & 64): size = size + 4
	else if (flags & 128): size = size + 8
	return size


# Mark the components of every kept composite glyph as kept, until no
# new glyph turns up (composites nest). keep[] is 0/1 per glyph id.
void ttf_subset_closure(ttf_font* f, char* keep):
	int changed = 1
	while (changed):
		changed = 0
		int gid = 0
		while (gid < f.glyph_count):
			int off = 0
			if (keep[gid] && (ttf_glyph_span(f, gid, &off) > 0) && (ttf_s16(f, off) < 0)):
				int pos = off + 10
				int more = 1
				while (more):
					int flags = ttf_u16(f, pos)
					int component = ttf_u16(f, pos + 2)
					if ((component < f.glyph_count) && (keep[component] == 0)):
						keep[component] = 1
						changed = 1
					pos = pos + ttf_component_size(flags)
					more = flags & 32
			gid = gid + 1


# Append glyph old's outline with instructions removed and component
# ids remapped through new_id.
void ttf_subset_glyph(string_builder* b, ttf_font* f, int old, int* new_id):
	int off = 0
	int length = ttf_glyph_span(f, old, &off)
	if (length == 0): return
	int contours = ttf_s16(f, off)
	if (contours >= 0):
		int head = 10 + contours * 2
		int instructions = ttf_u16(f, off + head)
		ttf_put_range(b, f, off, head)
		string_append_be16(b, 0)
		int rest = head + 2 + instructions
		if (rest < length): ttf_put_range(b, f, off + rest, length - rest)
		ttf_pad4(b)
		return
	ttf_put_range(b, f, off, 10)
	int pos = off + 10
	int more = 1
	while (more):
		int flags = ttf_u16(f, pos)
		int size = ttf_component_size(flags)
		# Drop WE_HAVE_INSTRUCTIONS (0x100): the instructions are gone.
		string_append_be16(b, flags & (65535 - 256))
		string_append_be16(b, new_id[ttf_u16(f, pos + 2)])
		ttf_put_range(b, f, pos + 4, size - 4)
		pos = pos + size
		more = flags & 32
	ttf_pad4(b)


# Left side bearing of gid from hmtx (font units).
int ttf_lsb_units(ttf_font* f, int gid):
	if (gid < f.num_hmetrics): return ttf_s16(f, f.hmtx + gid * 4 + 2)
	return ttf_s16(f, f.hmtx + f.num_hmetrics * 4 + (gid - f.num_hmetrics) * 2)


int ttf_checksum(char* data, int length):
	int sum = 0
	for i in range(0, length, 4):
		int word = 0
		for k in range(4):
			word = word << 8
			if (i + k < length): word = word | (data[i + k] & 255)
		sum = sum + word
	return sum


# Subset f to the codepoints in ranges (range_count inclusive
# [start, end] pairs, ascending and non-overlapping). Returns the new
# font's bytes (caller frees) with the length in size[0], or 0 after
# printing why.
char* ttf_subset(ttf_font* f, int* ranges, int range_count, int* size):
	if (f.cff != 0):
		print_error(c"ttf: subsetting CFF-outline fonts is not supported\n")
		return 0
	int n = f.glyph_count
	char* keep = cast(char*, malloc(n + 1))
	mem_fill(keep, 0, n)
	keep[0] = 1
	int total = 0
	int r = 0
	while (r < range_count):
		total = total + ranges[r * 2 + 1] - ranges[r * 2] + 1
		r = r + 1
	int* cps = cast(int*, malloc((total + 1) * __word_size__))
	int* gids = cast(int*, malloc((total + 1) * __word_size__))
	int mapped = 0
	r = 0
	while (r < range_count):
		int cp = ranges[r * 2]
		while (cp <= ranges[r * 2 + 1]):
			int gid = ttf_glyph_id(f, cp)
			if ((gid > 0) && (gid < n)):
				cps[mapped] = cp
				gids[mapped] = gid
				mapped = mapped + 1
				keep[gid] = 1
			cp = cp + 1
		r = r + 1
	ttf_subset_closure(f, keep)

	# New ids follow old-id order, so .notdef stays 0.
	int* new_id = cast(int*, malloc((n + 1) * __word_size__))
	int* old_id = cast(int*, malloc((n + 1) * __word_size__))
	int count = 0
	int i = 0
	while (i < n):
		new_id[i] = 0
		if (keep[i]):
			new_id[i] = count
			old_id[count] = i
			count = count + 1
		i = i + 1

	# glyf + loca (long offsets).
	string_builder* glyf = string_new()
	string_builder* loca = string_new()
	i = 0
	while (i < count):
		string_append_be32(loca, glyf.length)
		ttf_subset_glyph(glyf, f, old_id[i], new_id)
		i = i + 1
	string_append_be32(loca, glyf.length)

	string_builder* hmtx = string_new()
	i = 0
	while (i < count):
		string_append_be16(hmtx, ttf_advance_units(f, old_id[i]))
		string_append_be16(hmtx, ttf_lsb_units(f, old_id[i]) & 65535)
		i = i + 1

	# cmap: one format-12 subtable (Windows, full Unicode), grouping
	# runs where codepoint and glyph id both step by one.
	string_builder* groups = string_new()
	int group_count = 0
	i = 0
	while (i < mapped):
		int j = i
		while ((j + 1 < mapped) && (cps[j + 1] == cps[j] + 1) && (new_id[gids[j + 1]] == new_id[gids[j]] + 1)):
			j = j + 1
		string_append_be32(groups, cps[i])
		string_append_be32(groups, cps[j])
		string_append_be32(groups, new_id[gids[i]])
		group_count = group_count + 1
		i = j + 1
	string_builder* cmap = string_new()
	string_append_be16(cmap, 0)
	string_append_be16(cmap, 1)
	string_append_be16(cmap, 3)
	string_append_be16(cmap, 10)
	string_append_be32(cmap, 12)
	string_append_be16(cmap, 12)
	string_append_be16(cmap, 0)
	string_append_be32(cmap, 16 + groups.length)
	string_append_be32(cmap, 0)
	string_append_be32(cmap, group_count)
	string_append_bytes(cmap, groups.data, groups.length)

	# kern: every kept pair the source kerns (GPOS or kern), flattened
	# into one sorted format-0 subtable. Class-based GPOS kerning can
	# expand past what a format-0 subtable holds; the excess (the
	# weakest adjustments are not singled out) is dropped with a note.
	string_builder* pairs = string_new()
	int pair_count = 0
	int max_pairs = (65535 - 14) / 6
	int dropped = 0
	int left = 1
	while (left < count):
		for right in range(1, count):
			int v = ttf_kern_units(f, old_id[left], old_id[right])
			if (v != 0):
				if (pair_count < max_pairs):
					string_append_be16(pairs, left)
					string_append_be16(pairs, right)
					string_append_be16(pairs, v & 65535)
					pair_count = pair_count + 1
				else: dropped = dropped + 1
		left = left + 1
	if (dropped > 0): print_error(c"ttf_subset: kern pairs past the format-0 limit were dropped\n")
	string_builder* kern = string_new()
	string_append_be16(kern, 0)
	string_append_be16(kern, 1)
	string_append_be16(kern, 0)
	string_append_be16(kern, 14 + pairs.length)
	string_append_be16(kern, 1)
	string_append_be16(kern, pair_count)
	int search = 1
	int selector = 0
	while (search * 2 <= pair_count):
		search = search * 2
		selector = selector + 1
	if (pair_count == 0): search = 0
	string_append_be16(kern, search * 6)
	string_append_be16(kern, selector)
	string_append_be16(kern, pair_count * 6 - search * 6)
	string_append_bytes(kern, pairs.data, pairs.length)

	# Copied tables, patched: head (long loca, no checksum adjustment),
	# hhea and maxp (new glyph count), post (version 3: no names).
	int head_at = ttf_table(f, c"head")
	string_builder* head = string_new()
	ttf_put_range(head, f, head_at, 54)
	store_be16(head.data + 8, 0)
	store_be16(head.data + 10, 0)
	store_be16(head.data + 50, 1)
	string_builder* hhea = string_new()
	ttf_put_range(hhea, f, ttf_table(f, c"hhea"), 36)
	store_be16(hhea.data + 34, count)
	string_builder* maxp = string_new()
	ttf_put_range(maxp, f, ttf_table(f, c"maxp"), ttf_table_length(f, c"maxp"))
	store_be16(maxp.data + 4, count)
	string_builder* os2 = string_new()
	ttf_put_range(os2, f, ttf_table(f, c"OS/2"), ttf_table_length(f, c"OS/2"))
	string_builder* post = string_new()
	int post_at = ttf_table(f, c"post")
	if (post_at != 0): ttf_put_range(post, f, post_at, 32)
	else:
		i = 0
		while (i < 32):
			string_append_char(post, 0)
			i = i + 1
	store_be16(post.data + 0, 3)
	store_be16(post.data + 2, 0)

	# Table directory, tags in sorted (byte) order. An absent OS/2
	# leaves a zero-length entry out.
	string_builder*[10] tables
	char*[10] tags
	int table_count = 0
	if (os2.length > 0):
		tags[table_count] = c"OS/2"
		tables[table_count] = os2
		table_count = table_count + 1
	tags[table_count] = c"cmap"
	tables[table_count] = cmap
	table_count = table_count + 1
	tags[table_count] = c"glyf"
	tables[table_count] = glyf
	table_count = table_count + 1
	tags[table_count] = c"head"
	tables[table_count] = head
	table_count = table_count + 1
	tags[table_count] = c"hhea"
	tables[table_count] = hhea
	table_count = table_count + 1
	tags[table_count] = c"hmtx"
	tables[table_count] = hmtx
	table_count = table_count + 1
	tags[table_count] = c"kern"
	tables[table_count] = kern
	table_count = table_count + 1
	tags[table_count] = c"loca"
	tables[table_count] = loca
	table_count = table_count + 1
	tags[table_count] = c"maxp"
	tables[table_count] = maxp
	table_count = table_count + 1
	tags[table_count] = c"post"
	tables[table_count] = post
	table_count = table_count + 1

	string_builder* out = string_new()
	string_append_be32(out, 65536)
	string_append_be16(out, table_count)
	int tsearch = 1
	int tselector = 0
	while (tsearch * 2 <= table_count):
		tsearch = tsearch * 2
		tselector = tselector + 1
	string_append_be16(out, tsearch * 16)
	string_append_be16(out, tselector)
	string_append_be16(out, table_count * 16 - tsearch * 16)
	int offset = 12 + table_count * 16
	int t = 0
	while (t < table_count):
		string_builder* tb = tables[t]
		string_append_bytes(out, tags[t], 4)
		string_append_be32(out, ttf_checksum(tb.data, tb.length))
		string_append_be32(out, offset)
		string_append_be32(out, tb.length)
		offset = offset + (tb.length + 3) / 4 * 4
		t = t + 1
	t = 0
	while (t < table_count):
		string_builder* tb2 = tables[t]
		string_append_bytes(out, tb2.data, tb2.length)
		ttf_pad4(out)
		string_free(tb2)
		t = t + 1
	string_free(groups)
	string_free(pairs)

	free(keep)
	free(cast(char*, cps))
	free(cast(char*, gids))
	free(cast(char*, new_id))
	free(cast(char*, old_id))
	char* data = out.data
	size[0] = out.length
	free(out)
	return data


# ---- CFF (Type 2 charstring) outlines --------------------------------
#
# 'OTTO' fonts keep outlines in a CFF table: INDEX structures of
# charstrings, global and local subroutines, and DICTs that point at
# them (Adobe TN #5176, Type 2 charstrings TN #5177). Name-keyed fonts
# have one Private DICT; CID-keyed ones pick a Font DICT per glyph
# through FDSelect. Cubic segments are flattened like the quadratic
# ones; hints are skipped (unhinted output, as for TrueType).

# A big-endian offset of size bytes (1-4).
int ttf_cff_offset(ttf_font* f, int at, int size):
	int v = 0
	for i in range(size): v = (v << 8) | ttf_u8(f, at + i)
	return v


# Absolute offset of item i of the INDEX at idx, with its byte length in
# length[0]; 0 (length 0) when i is out of range or the INDEX is bad.
int ttf_cff_index_item(ttf_font* f, int idx, int i, int* length):
	length[0] = 0
	int count = ttf_u16(f, idx)
	if ((i < 0) || (i >= count)): return 0
	int size = ttf_u8(f, idx + 2)
	if ((size < 1) || (size > 4)): return 0
	int offsets = idx + 3
	int a = ttf_cff_offset(f, offsets + i * size, size)
	int b = ttf_cff_offset(f, offsets + (i + 1) * size, size)
	int data = offsets + (count + 1) * size - 1
	if ((a < 1) || (b < a) || (data + b > f.size)): return 0
	length[0] = b - a
	return data + a


# The offset just past the INDEX at idx.
int ttf_cff_index_end(ttf_font* f, int idx):
	int count = ttf_u16(f, idx)
	if (count == 0): return idx + 2
	int size = ttf_u8(f, idx + 2)
	if ((size < 1) || (size > 4)): return f.size
	int offsets = idx + 3
	return offsets + (count + 1) * size - 1 + ttf_cff_offset(f, offsets + count * size, size)


# Find operator op (12 x is 1200 + x) in the DICT at [start, start +
# length) and copy up to max of its integer operands into values.
# Returns the operand count, or -1 when op is absent. Real operands
# read as 0 (no operator used here takes one).
int ttf_cff_dict(ttf_font* f, int start, int length, int op, int* values, int max):
	int at = start
	int end = start + length
	int n = 0
	while (at < end):
		int b0 = ttf_u8(f, at)
		if (b0 <= 21):
			int code = b0
			at = at + 1
			if (b0 == 12):
				code = 1200 + ttf_u8(f, at)
				at = at + 1
			if (code == op): return n
			n = 0
			continue
		int value = 0
		if (b0 == 28):
			value = ttf_s16(f, at + 1)
			at = at + 3
		else if (b0 == 29):
			value = ttf_u32(f, at + 1)
			at = at + 5
		else if (b0 == 30):
			# A real: nibbles up to an 0xf terminator.
			at = at + 1
			int done = 0
			while (!done && (at < end)):
				int byte = ttf_u8(f, at)
				if (((byte & 15) == 15) || ((byte >> 4) == 15)): done = 1
				at = at + 1
		else if ((b0 >= 32) && (b0 <= 246)):
			value = b0 - 139
			at = at + 1
		else if ((b0 >= 247) && (b0 <= 250)):
			value = (b0 - 247) * 256 + ttf_u8(f, at + 1) + 108
			at = at + 2
		else if ((b0 >= 251) && (b0 <= 254)):
			value = 0 - (b0 - 251) * 256 - ttf_u8(f, at + 1) - 108
			at = at + 2
		else:
			at = at + 1
		if (n < max): values[n] = value
		n = n + 1
	return -1


# The local Subrs INDEX of the Private DICT that dict's operator 18
# (size, offset) names, or 0.
int ttf_cff_private_subrs(ttf_font* f, int dict, int dict_length):
	int[2] priv
	if (ttf_cff_dict(f, dict, dict_length, 18, &priv[0], 2) != 2): return 0
	int start = f.cff + priv[1]
	int[1] subrs
	if (ttf_cff_dict(f, start, priv[0], 19, &subrs[0], 1) != 1): return 0
	return start + subrs[0]


# Index the CFF table: CharStrings, the global and local subroutines,
# and for CID-keyed fonts the FDArray and FDSelect. Returns 0 when the
# table is unusable.
int ttf_cff_init(ttf_font* f):
	int cff = f.cff
	if (ttf_u8(f, cff) != 1): return 0
	int names = cff + ttf_u8(f, cff + 2)
	int top_index = ttf_cff_index_end(f, names)
	int strings = ttf_cff_index_end(f, top_index)
	f.cff_gsubrs = ttf_cff_index_end(f, strings)
	int top_length = 0
	int top = ttf_cff_index_item(f, top_index, 0, &top_length)
	if (top == 0): return 0
	int[2] values
	if (ttf_cff_dict(f, top, top_length, 17, &values[0], 1) != 1): return 0
	f.cff_charstrings = cff + values[0]
	f.cff_subrs = ttf_cff_private_subrs(f, top, top_length)
	f.cff_fdarray = 0
	f.cff_fdselect = 0
	if (ttf_cff_dict(f, top, top_length, 1236, &values[0], 1) == 1):
		f.cff_fdarray = cff + values[0]
		if (ttf_cff_dict(f, top, top_length, 1237, &values[0], 1) != 1): return 0
		f.cff_fdselect = cff + values[0]
	return ttf_u16(f, f.cff_charstrings) > 0


# CID-keyed fonts: the Font DICT index of gid (FDSelect formats 0 and 3).
int ttf_cff_fd_index(ttf_font* f, int gid):
	int sel = f.cff_fdselect
	int format = ttf_u8(f, sel)
	if (format == 0): return ttf_u8(f, sel + 1 + gid)
	if (format != 3): return 0
	int ranges = ttf_u16(f, sel + 1)
	for i in range(ranges):
		int rec = sel + 3 + i * 3
		int next = ttf_u16(f, rec + 3)
		if ((gid >= ttf_u16(f, rec)) && (gid < next)): return ttf_u8(f, rec + 2)
	return 0


# The local Subrs INDEX that gid's charstring calls into, or 0.
int ttf_cff_local_subrs(ttf_font* f, int gid):
	if (f.cff_fdarray == 0): return f.cff_subrs
	int length = 0
	int dict = ttf_cff_index_item(f, f.cff_fdarray, ttf_cff_fd_index(f, gid), &length)
	if (dict == 0): return 0
	return ttf_cff_private_subrs(f, dict, length)


# The bias added to a subroutine number (Type 2: by subroutine count).
int ttf_cff_bias(ttf_font* f, int idx):
	if (idx == 0): return 0
	int count = ttf_u16(f, idx)
	if (count < 1240): return 107
	if (count < 33900): return 1131
	return 32768


# Flatten one cubic (p0, c1, c2, p1) into 12 line segments.
void ttf_outline_cubic(ttf_outline* o, float32 x0, float32 y0, float32 x1, float32 y1, float32 x2, float32 y2, float32 x3, float32 y3):
	float32 px = x0
	float32 py = y0
	for i in range(1, 12 + 1):
		float32 t = cast(float32, i) / 12.0
		float32 u = 1.0 - t
		float32 a = u * u * u
		float32 b = 3.0 * u * u * t
		float32 c = 3.0 * u * t * t
		float32 d = t * t * t
		float32 qx = a * x0 + b * x1 + c * x2 + d * x3
		float32 qy = a * y0 + b * y1 + c * y2 + d * y3
		ttf_outline_push(o, px, py, qx, qy)
		px = qx
		py = qy


# Charstring interpreter state. Coordinates are font units, y up. The
# path goes to an outline (o, transformed by m), a text dump (path), or
# only the control-point bounds.
struct ttf_cff_run:
	ttf_font* f
	ttf_outline* o
	ttf_xform* m
	string_builder* path
	float32* stack
	int sp
	float32 x
	float32 y
	float32 start_x
	float32 start_y
	int open
	int stems
	int width_done
	int gsubrs
	int gbias
	int subrs
	int lbias
	int ended
	int bad
	int has_bounds
	float32 min_x
	float32 min_y
	float32 max_x
	float32 max_y


void ttf_cff_bound(ttf_cff_run* r, float32 x, float32 y):
	if (!r.has_bounds):
		r.min_x = x
		r.max_x = x
		r.min_y = y
		r.max_y = y
		r.has_bounds = 1
		return
	if (x < r.min_x): r.min_x = x
	if (x > r.max_x): r.max_x = x
	if (y < r.min_y): r.min_y = y
	if (y > r.max_y): r.max_y = y


float32 ttf_cff_tx(ttf_cff_run* r, float32 x, float32 y):
	float32 ty = (r.m.b * x + r.m.d * y + r.m.dy) * r.o.scale
	return (r.m.a * x + r.m.c * y + r.m.dx) * r.o.scale + r.o.skew * ty


float32 ttf_cff_ty(ttf_cff_run* r, float32 x, float32 y):
	return 0.0 - (r.m.b * x + r.m.d * y + r.m.dy) * r.o.scale


# Record a charstring point for a hinter (font units, transformed by m).
void ttf_cff_point(ttf_cff_run* r, float32 x, float32 y, int flags):
	if ((r.o == 0) || (r.o.points == 0)): return
	ttf_points_push(r.o.points, r.m.a * x + r.m.c * y + r.m.dx, r.m.b * x + r.m.d * y + r.m.dy, flags)


void ttf_cff_dump(ttf_cff_run* r, char* op, float32 x, float32 y):
	string_append(r.path, op)
	string_append_int(r.path, ttf_floor(x + 0.5))
	string_append_char(r.path, ' ')
	string_append_int(r.path, ttf_floor(y + 0.5))


void ttf_cff_line_to(ttf_cff_run* r, float32 x, float32 y):
	if (r.o != 0): ttf_outline_push(r.o, ttf_cff_tx(r, r.x, r.y), ttf_cff_ty(r, r.x, r.y), ttf_cff_tx(r, x, y), ttf_cff_ty(r, x, y))
	if (r.path != 0): ttf_cff_dump(r, c" L ", x, y)
	ttf_cff_point(r, x, y, 1)
	r.x = x
	r.y = y
	ttf_cff_bound(r, x, y)


void ttf_cff_close(ttf_cff_run* r):
	if (!r.open): return
	if ((r.x != r.start_x) || (r.y != r.start_y)):
		if (r.o != 0): ttf_outline_push(r.o, ttf_cff_tx(r, r.x, r.y), ttf_cff_ty(r, r.x, r.y), ttf_cff_tx(r, r.start_x, r.start_y), ttf_cff_ty(r, r.start_x, r.start_y))
	if (r.path != 0): string_append(r.path, c" Z")
	# The implicit closing line leaves the current point where the last
	# segment ended: the next moveto is relative to that.
	r.open = 0


void ttf_cff_move_by(ttf_cff_run* r, float32 dx, float32 dy):
	ttf_cff_close(r)
	r.x = r.x + dx
	r.y = r.y + dy
	r.start_x = r.x
	r.start_y = r.y
	r.open = 1
	if (r.path != 0): ttf_cff_dump(r, c" M ", r.x, r.y)
	ttf_cff_point(r, r.x, r.y, 3)
	ttf_cff_bound(r, r.x, r.y)


void ttf_cff_line_by(ttf_cff_run* r, float32 dx, float32 dy):
	ttf_cff_line_to(r, r.x + dx, r.y + dy)


void ttf_cff_curve_by(ttf_cff_run* r, float32 dx1, float32 dy1, float32 dx2, float32 dy2, float32 dx3, float32 dy3):
	float32 x1 = r.x + dx1
	float32 y1 = r.y + dy1
	float32 x2 = x1 + dx2
	float32 y2 = y1 + dy2
	float32 x3 = x2 + dx3
	float32 y3 = y2 + dy3
	if (r.o != 0): ttf_outline_cubic(r.o, ttf_cff_tx(r, r.x, r.y), ttf_cff_ty(r, r.x, r.y), ttf_cff_tx(r, x1, y1), ttf_cff_ty(r, x1, y1), ttf_cff_tx(r, x2, y2), ttf_cff_ty(r, x2, y2), ttf_cff_tx(r, x3, y3), ttf_cff_ty(r, x3, y3))
	if (r.path != 0):
		ttf_cff_dump(r, c" C ", x1, y1)
		ttf_cff_dump(r, c" ", x2, y2)
		ttf_cff_dump(r, c" ", x3, y3)
	ttf_cff_point(r, x1, y1, 0)
	ttf_cff_point(r, x2, y2, 0)
	ttf_cff_point(r, x3, y3, 1)
	ttf_cff_bound(r, x1, y1)
	ttf_cff_bound(r, x2, y2)
	r.x = x3
	r.y = y3
	ttf_cff_bound(r, x3, y3)


# The first stack-clearing operator may carry the advance width as an
# extra leading operand; drop it (hmtx gives the advance).
void ttf_cff_take_width(ttf_cff_run* r, int extra):
	if (r.width_done): return
	r.width_done = 1
	if (extra && (r.sp > 0)):
		for i in range(r.sp - 1): r.stack[i] = r.stack[i + 1]
		r.sp = r.sp - 1


# hhcurveto/vvcurveto/hvcurveto/vhcurveto: horizontal = 1 when the
# first curve starts horizontally; alternate flips it per curve.
void ttf_cff_hv_curves(ttf_cff_run* r, int horizontal):
	float32* s = r.stack
	int i = 0
	while (i + 4 <= r.sp):
		int last = i + 4 >= r.sp - 1
		float32 extra = 0.0
		if (last && (r.sp - i == 5)): extra = s[i + 4]
		if (horizontal): ttf_cff_curve_by(r, s[i], 0.0, s[i + 1], s[i + 2], extra, s[i + 3])
		else: ttf_cff_curve_by(r, 0.0, s[i], s[i + 1], s[i + 2], s[i + 3], extra)
		horizontal = !horizontal
		i = i + 4
		if (last && (r.sp - i == 1)): i = i + 1


# Run one charstring (or subroutine) at [at, at + length).
void ttf_cff_exec(ttf_cff_run* r, int at, int length, int depth):
	ttf_font* f = r.f
	int end = at + length
	if (depth > 10):
		r.bad = 1
		return
	float32* s = r.stack
	while ((at < end) && !r.ended && !r.bad):
		int b0 = ttf_u8(f, at)
		if ((b0 >= 32) || (b0 == 28)):
			float32 value = 0.0
			if (b0 == 28):
				value = cast(float32, ttf_s16(f, at + 1))
				at = at + 3
			else if (b0 <= 246):
				value = cast(float32, b0 - 139)
				at = at + 1
			else if (b0 <= 250):
				value = cast(float32, (b0 - 247) * 256 + ttf_u8(f, at + 1) + 108)
				at = at + 2
			else if (b0 <= 254):
				value = cast(float32, 0 - (b0 - 251) * 256 - ttf_u8(f, at + 1) - 108)
				at = at + 2
			else:
				# 255: a 16.16 fixed-point number.
				int whole = ttf_s16(f, at + 1)
				value = cast(float32, whole) + cast(float32, ttf_u16(f, at + 3)) / 65536.0
				at = at + 5
			if (r.sp >= 48):
				r.bad = 1
				return
			s[r.sp] = value
			r.sp = r.sp + 1
			continue
		at = at + 1
		int op = b0
		if (op == 12):
			op = 1200 + ttf_u8(f, at)
			at = at + 1
		if ((op == 1) || (op == 3) || (op == 18) || (op == 23)):
			# hstem vstem hstemhm vstemhm
			ttf_cff_take_width(r, r.sp & 1)
			r.stems = r.stems + r.sp / 2
			r.sp = 0
		else if ((op == 19) || (op == 20)):
			# hintmask cntrmask: pending operands are vstems.
			ttf_cff_take_width(r, r.sp & 1)
			r.stems = r.stems + r.sp / 2
			r.sp = 0
			at = at + (r.stems + 7) / 8
		else if (op == 21):
			ttf_cff_take_width(r, r.sp > 2)
			if (r.sp >= 2): ttf_cff_move_by(r, s[0], s[1])
			r.sp = 0
		else if (op == 22):
			ttf_cff_take_width(r, r.sp > 1)
			if (r.sp >= 1): ttf_cff_move_by(r, s[0], 0.0)
			r.sp = 0
		else if (op == 4):
			ttf_cff_take_width(r, r.sp > 1)
			if (r.sp >= 1): ttf_cff_move_by(r, 0.0, s[0])
			r.sp = 0
		else if (op == 5):
			int i = 0
			while (i + 2 <= r.sp):
				ttf_cff_line_by(r, s[i], s[i + 1])
				i = i + 2
			r.sp = 0
		else if ((op == 6) || (op == 7)):
			int horizontal = op == 6
			for i in range(r.sp):
				if (horizontal): ttf_cff_line_by(r, s[i], 0.0)
				else: ttf_cff_line_by(r, 0.0, s[i])
				horizontal = !horizontal
			r.sp = 0
		else if ((op == 8) || (op == 24)):
			# rrcurveto, rcurveline (curves then one line)
			int i = 0
			while (i + 6 <= r.sp):
				ttf_cff_curve_by(r, s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5])
				i = i + 6
			if ((op == 24) && (i + 2 <= r.sp)): ttf_cff_line_by(r, s[i], s[i + 1])
			r.sp = 0
		else if (op == 25):
			# rlinecurve: lines, then one curve
			int i = 0
			while (i + 8 <= r.sp):
				ttf_cff_line_by(r, s[i], s[i + 1])
				i = i + 2
			if (i + 6 <= r.sp): ttf_cff_curve_by(r, s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5])
			r.sp = 0
		else if ((op == 26) || (op == 27)):
			# vvcurveto, hhcurveto: an odd count leads with the other delta.
			int i = 0
			float32 lead = 0.0
			if (r.sp & 1):
				lead = s[0]
				i = 1
			while (i + 4 <= r.sp):
				if (op == 26): ttf_cff_curve_by(r, lead, s[i], s[i + 1], s[i + 2], 0.0, s[i + 3])
				else: ttf_cff_curve_by(r, s[i], lead, s[i + 1], s[i + 2], s[i + 3], 0.0)
				lead = 0.0
				i = i + 4
			r.sp = 0
		else if ((op == 30) || (op == 31)):
			ttf_cff_hv_curves(r, op == 31)
			r.sp = 0
		else if ((op == 10) || (op == 29)):
			if (r.sp < 1):
				r.bad = 1
				return
			r.sp = r.sp - 1
			int index = ttf_floor(s[r.sp])
			int subrs = r.subrs
			if (op == 29):
				subrs = r.gsubrs
				index = index + r.gbias
			else: index = index + r.lbias
			int sub_length = 0
			int sub = 0
			if (subrs != 0): sub = ttf_cff_index_item(f, subrs, index, &sub_length)
			if (sub == 0):
				r.bad = 1
				return
			ttf_cff_exec(r, sub, sub_length, depth + 1)
		else if (op == 11):
			return
		else if (op == 14):
			ttf_cff_take_width(r, (r.sp == 1) || (r.sp == 5))
			ttf_cff_close(r)
			r.ended = 1
		else if ((op == 1234) || (op == 1235) || (op == 1236) || (op == 1237)):
			# hflex flex hflex1 flex1: two curves (the flex depth is ignored).
			if (op == 1234):
				ttf_cff_curve_by(r, s[0], 0.0, s[1], s[2], s[3], 0.0)
				ttf_cff_curve_by(r, s[4], 0.0, s[5], 0.0 - s[2], s[6], 0.0)
			else if (op == 1235):
				ttf_cff_curve_by(r, s[0], s[1], s[2], s[3], s[4], s[5])
				ttf_cff_curve_by(r, s[6], s[7], s[8], s[9], s[10], s[11])
			else if (op == 1236):
				ttf_cff_curve_by(r, s[0], s[1], s[2], s[3], s[4], 0.0)
				ttf_cff_curve_by(r, s[5], 0.0, s[6], s[7], s[8], 0.0 - (s[1] + s[3] + s[7]))
			else:
				float32 dx = s[0] + s[2] + s[4] + s[6] + s[8]
				float32 dy = s[1] + s[3] + s[5] + s[7] + s[9]
				float32 adx = dx
				float32 ady = dy
				if (adx < 0.0): adx = 0.0 - adx
				if (ady < 0.0): ady = 0.0 - ady
				ttf_cff_curve_by(r, s[0], s[1], s[2], s[3], s[4], s[5])
				if (adx > ady): ttf_cff_curve_by(r, s[6], s[7], s[8], s[9], s[10], 0.0 - dy)
				else: ttf_cff_curve_by(r, s[6], s[7], s[8], s[9], 0.0 - dx, s[10])
			r.sp = 0
		else:
			# Arithmetic and storage operators (unused by current fonts)
			# and reserved codes: discard the operands.
			r.sp = 0


# Interpret gid's charstring into o (transformed by m), path, or only
# the bounds. Returns 1, or 0 on a malformed charstring.
int ttf_cff_run_glyph(ttf_font* f, int gid, ttf_cff_run* r):
	r.f = f
	r.stack = cast(float32*, malloc(48 * 4))
	r.sp = 0
	r.x = 0.0
	r.y = 0.0
	r.open = 0
	r.stems = 0
	r.width_done = 0
	r.ended = 0
	r.bad = 0
	r.has_bounds = 0
	r.gsubrs = f.cff_gsubrs
	r.gbias = ttf_cff_bias(f, f.cff_gsubrs)
	r.subrs = ttf_cff_local_subrs(f, gid)
	r.lbias = ttf_cff_bias(f, r.subrs)
	int length = 0
	int at = ttf_cff_index_item(f, f.cff_charstrings, gid, &length)
	if (at != 0): ttf_cff_exec(r, at, length, 0)
	ttf_cff_close(r)
	free(cast(char*, r.stack))
	if (r.bad): print_error(c"ttf: malformed CFF charstring\n")
	return !r.bad


int ttf_cff_add(ttf_font* f, ttf_outline* o, int gid, ttf_xform* m):
	ttf_cff_run r
	r.o = o
	r.m = m
	r.path = 0
	return ttf_cff_run_glyph(f, gid, &r)


# Control-point bounds of a CFF glyph in font units (as glyf headers and
# HarfBuzz's CFF extents use), rounded outward.
int ttf_cff_bbox(ttf_font* f, int gid, int* box):
	ttf_cff_run r
	r.o = 0
	r.m = 0
	r.path = 0
	if (!ttf_cff_run_glyph(f, gid, &r) || !r.has_bounds): return 0
	box[0] = ttf_floor(r.min_x)
	box[1] = ttf_floor(r.min_y)
	box[2] = ttf_ceil(r.max_x)
	box[3] = ttf_ceil(r.max_y)
	return 1


# The glyph's CFF path as text ("M x y", "L x y", "C x1 y1 x2 y2 x y",
# "Z"; font units rounded), for tests and tools. Returns 0 when f has no
# CFF outlines or the charstring is malformed.
int ttf_cff_path(ttf_font* f, int gid, string_builder* path):
	if (f.cff == 0): return 0
	ttf_cff_run r
	r.o = 0
	r.m = 0
	r.path = path
	return ttf_cff_run_glyph(f, gid, &r)
