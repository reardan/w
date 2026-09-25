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
subsamples per pixel (unhinted grayscale coverage). CFF/OpenType
outlines and hinting are not supported.

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


# Out-of-range reads yield 0: a truncated file degrades to a failed
# load or an empty glyph instead of reading past the blob.
int ttf_u8(ttf_font* f, int off):
	if ((off < 0) || (off >= f.size)):
		return 0
	return f.data[off] & 255


int ttf_u16(ttf_font* f, int off):
	return (ttf_u8(f, off) << 8) | ttf_u8(f, off + 1)


int ttf_s16(ttf_font* f, int off):
	int v = ttf_u16(f, off)
	if (v >= 32768):
		v = v - 65536
	return v


int ttf_u32(ttf_font* f, int off):
	return (ttf_u16(f, off) << 16) | ttf_u16(f, off + 2)


# Offset of a table by 4-char tag, or 0 when absent or not wholly
# inside the blob.
int ttf_table(ttf_font* f, char* tag):
	int count = ttf_u16(f, 4)
	int i = 0
	while (i < count):
		int rec = 12 + i * 16
		if ((ttf_u8(f, rec) == tag[0]) && (ttf_u8(f, rec + 1) == tag[1]) && (ttf_u8(f, rec + 2) == tag[2]) && (ttf_u8(f, rec + 3) == tag[3])):
			int off = ttf_u32(f, rec + 8)
			int length = ttf_u32(f, rec + 12)
			if ((off <= 0) || (length < 0) || (off > f.size - length)):
				return 0
			return off
		i = i + 1
	return 0


# Byte length of a table by tag, or 0 when absent.
int ttf_table_length(ttf_font* f, char* tag):
	int count = ttf_u16(f, 4)
	int i = 0
	while (i < count):
		int rec = 12 + i * 16
		if ((ttf_u8(f, rec) == tag[0]) && (ttf_u8(f, rec + 1) == tag[1]) && (ttf_u8(f, rec + 2) == tag[2]) && (ttf_u8(f, rec + 3) == tag[3])):
			return ttf_u32(f, rec + 12)
		i = i + 1
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


# Load and index a TrueType file. Returns 1, or 0 after printing what
# was missing (bad path, absent table, no usable cmap). f owns the
# bytes; ttf_free releases them.
int ttf_load(ttf_font* f, char* path):
	int size = 0
	char* data = ttf_read_file(path, &size)
	if (data == 0):
		return 0
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
	f.cmap4 = 0
	f.cmap12 = 0
	if (size < 12):
		print_error(c"ttf: file too short\n")
		return 0
	int version = ttf_u32(f, 0)
	if ((version != 65536) && (version != 1953658213)):
		# 0x00010000 or 'true'; 'OTTO' (CFF outlines) and collections
		# are not TrueType-outline fonts.
		print_error(c"ttf: not a TrueType-outline font\n")
		return 0
	int head = ttf_table(f, c"head")
	int maxp = ttf_table(f, c"maxp")
	int cmap = ttf_table(f, c"cmap")
	int hhea = ttf_table(f, c"hhea")
	f.loca = ttf_table(f, c"loca")
	f.glyf = ttf_table(f, c"glyf")
	f.hmtx = ttf_table(f, c"hmtx")
	if ((head == 0) || (maxp == 0) || (cmap == 0) || (hhea == 0) || (f.loca == 0) || (f.glyf == 0) || (f.hmtx == 0)):
		print_error(c"ttf: required table missing (need head/maxp/cmap/hhea/loca/glyf/hmtx)\n")
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
	int i = 0
	while (i < subtables):
		int sub = cmap + ttf_u32(f, cmap + 4 + i * 8 + 4)
		int format = ttf_u16(f, sub)
		if ((format == 4) && (f.cmap4 == 0)):
			f.cmap4 = sub
		if ((format == 12) && (f.cmap12 == 0)):
			f.cmap12 = sub
		i = i + 1
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
	if (gpos == 0):
		return
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
			if (g < gid):
				lo = mid + 1
			else:
				hi = mid - 1
		else if (format == 2):
			int rec = cov + 4 + mid * 6
			if (gid < ttf_u16(f, rec)):
				hi = mid - 1
			else if (gid > ttf_u16(f, rec + 2)):
				lo = mid + 1
			else:
				return ttf_u16(f, rec + 4) + gid - ttf_u16(f, rec)
		else:
			return 0 - 1
	return 0 - 1


# Class of gid in a ClassDef table (0 when unlisted).
int ttf_class(ttf_font* f, int def, int gid):
	int format = ttf_u16(f, def)
	if (format == 1):
		int start = ttf_u16(f, def + 2)
		int n = ttf_u16(f, def + 4)
		if ((gid < start) || (gid >= start + n)):
			return 0
		return ttf_u16(f, def + 6 + (gid - start) * 2)
	if (format != 2):
		return 0
	int count = ttf_u16(f, def + 2)
	int lo = 0
	int hi = count - 1
	while (lo <= hi):
		int mid = (lo + hi) / 2
		int rec = def + 4 + mid * 6
		if (gid < ttf_u16(f, rec)):
			hi = mid - 1
		else if (gid > ttf_u16(f, rec + 2)):
			lo = mid + 1
		else:
			return ttf_u16(f, rec + 4)
	return 0


# Bytes in a ValueRecord of the given ValueFormat: two per set bit.
int ttf_value_size(int format):
	int size = 0
	int bit = 0
	while (bit < 8):
		if (format & (1 << bit)):
			size = size + 2
		bit = bit + 1
	return size


# The XAdvance field of a ValueRecord at rec, or 0 when the format has
# none (placement-only adjustments do not move the pen).
int ttf_value_x_advance(ttf_font* f, int rec, int format):
	if ((format & 4) == 0):
		return 0
	return ttf_s16(f, rec + ttf_value_size(format & 3))


# One PairPos subtable's x-advance adjustment for (left, right). Stores
# 1 in matched[0] when the subtable applies to the pair.
int ttf_pair_pos(ttf_font* f, int sub, int left, int right, int* matched):
	matched[0] = 0
	int format = ttf_u16(f, sub)
	int index = ttf_coverage(f, sub + ttf_u16(f, sub + 2), left)
	if (index < 0):
		return 0
	int vf1 = ttf_u16(f, sub + 4)
	int vf2 = ttf_u16(f, sub + 6)
	int size1 = ttf_value_size(vf1)
	int size2 = ttf_value_size(vf2)
	if (format == 1):
		if (index >= ttf_u16(f, sub + 8)):
			return 0
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
			if (g < right):
				lo = mid + 1
			else:
				hi = mid - 1
		return 0
	if (format == 2):
		int c1 = ttf_class(f, sub + ttf_u16(f, sub + 8), left)
		int c2 = ttf_class(f, sub + ttf_u16(f, sub + 10), right)
		int class1_count = ttf_u16(f, sub + 12)
		int class2_count = ttf_u16(f, sub + 14)
		if ((c1 >= class1_count) || (c2 >= class2_count)):
			return 0
		matched[0] = 1
		int rec2 = sub + 16 + (c1 * class2_count + c2) * (size1 + size2)
		return ttf_value_x_advance(f, rec2, vf1)
	return 0


# Pair-kerning adjustment between two glyph ids, in font units
# (negative pulls the right glyph closer). GPOS 'kern' lookups when the
# font has them, else the legacy kern table; 0 when neither lists the
# pair.
int ttf_kern_units(ttf_font* f, int left, int right):
	if (f.gpos_feature != 0):
		int total = 0
		int lookups = f.gpos_lookup_list
		int lookup_count = ttf_u16(f, lookups)
		int n = ttf_u16(f, f.gpos_feature + 2)
		int i = 0
		while (i < n):
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
				if (sub_type == 2):
					total = total + ttf_pair_pos(f, sub, left, right, &matched)
				# The first subtable that applies ends the lookup.
				if (matched):
					s = subs
				s = s + 1
			i = i + 1
		return total
	if (f.kern == 0):
		return 0
	int key = left * 65536 + right
	int lo = 0
	int hi = f.kern_pairs - 1
	while (lo <= hi):
		int mid = (lo + hi) / 2
		int rec = f.kern + 8 + mid * 6
		int k = ttf_u16(f, rec) * 65536 + ttf_u16(f, rec + 2)
		if (k == key):
			return ttf_s16(f, rec + 4)
		if (k < key):
			lo = mid + 1
		else:
			hi = mid - 1
	return 0


# Release the bytes ttf_load read. Not for ttf_load_bytes fonts, whose
# bytes belong to the caller.
void ttf_free(ttf_font* f):
	if (f.data != 0):
		free(f.data)
	f.data = 0
	f.size = 0


# Glyph id via a format-12 subtable: sequential groups of
# (start, end, start glyph).
int ttf_glyph_id_12(ttf_font* f, int code):
	int sub = f.cmap12
	int groups = ttf_u32(f, sub + 12)
	int i = 0
	while (i < groups):
		int rec = sub + 16 + i * 12
		int start = ttf_u32(f, rec)
		int end = ttf_u32(f, rec + 4)
		if ((code >= start) && (code <= end)):
			return ttf_u32(f, rec + 8) + (code - start)
		i = i + 1
	return 0


# Glyph id for a codepoint (0 = .notdef): format 12 when present, else
# format 4.
int ttf_glyph_id(ttf_font* f, int code):
	if (f.cmap12 != 0):
		return ttf_glyph_id_12(f, code)
	int sub = f.cmap4
	if (code > 65535):
		return 0
	int segs = ttf_u16(f, sub + 6) / 2
	int ends = sub + 14
	int starts = sub + 16 + segs * 2
	int deltas = sub + 16 + segs * 4
	int range_offsets = sub + 16 + segs * 6
	int i = 0
	while (i < segs):
		if (code <= ttf_u16(f, ends + i * 2)):
			int start = ttf_u16(f, starts + i * 2)
			if (code < start):
				return 0
			int delta = ttf_u16(f, deltas + i * 2)
			int range_offset = ttf_u16(f, range_offsets + i * 2)
			if (range_offset == 0):
				return (code + delta) & 65535
			int addr = range_offsets + i * 2 + range_offset + (code - start) * 2
			int gid = ttf_u16(f, addr)
			if (gid == 0):
				return 0
			return (gid + delta) & 65535
		i = i + 1
	return 0


# Advance width in font units.
int ttf_advance_units(ttf_font* f, int gid):
	int index = gid
	if (index >= f.num_hmetrics):
		index = f.num_hmetrics - 1
	return ttf_u16(f, f.hmtx + index * 4)


# Round font units to pixels at the given ppem (half-up).
int ttf_scale_round(ttf_font* f, int ppem, int units):
	int scaled = units * ppem * 2 / f.upem
	if (scaled >= 0):
		return (scaled + 1) / 2
	return 0 - ((1 - scaled) / 2)


# Decoration line geometry in pixels at ppem, y-down from the baseline:
# the line's top row (underline positive, below the baseline; strikeout
# negative, above it) and its thickness (at least one pixel).
int ttf_underline_top(ttf_font* f, int ppem):
	int top = 0 - ttf_scale_round(f, ppem, f.underline_pos)
	if (top < 1):
		top = 1
	return top


int ttf_underline_thickness(ttf_font* f, int ppem):
	int thick = ttf_scale_round(f, ppem, f.underline_thick)
	if (thick < 1):
		thick = 1
	return thick


int ttf_strikeout_top(ttf_font* f, int ppem):
	return 0 - ttf_scale_round(f, ppem, f.strike_pos)


int ttf_strikeout_thickness(ttf_font* f, int ppem):
	int thick = ttf_scale_round(f, ppem, f.strike_thick)
	if (thick < 1):
		thick = 1
	return thick


# Mild darkening of antialiased coverage so unhinted small text reads
# crisply on light backgrounds (255 and 0 stay fixed). Applied to every
# UI strike, baked or loaded at run time, so both look alike.
int ttf_boost_coverage(int v):
	return v + ((255 - v) * v * 2) / 765


int ttf_glyf_offset(ttf_font* f, int gid):
	if (f.loc_long):
		return ttf_u32(f, f.loca + gid * 4)
	return ttf_u16(f, f.loca + gid * 2) * 2


struct ttf_bitmap:
	char* pixels        # w*h coverage bytes, row-major, y-down; 0 when empty
	int w
	int h
	int bearing_x       # pixels from the pen to the bitmap's left edge
	int bearing_top     # bitmap rows above the baseline
	int advance         # pen advance in whole pixels


int ttf_floor(float32 v):
	int t = cast(int, v)
	if (cast(float32, t) > v):
		t = t - 1
	return t


int ttf_ceil(float32 v):
	int t = cast(int, v)
	if (cast(float32, t) < v):
		t = t + 1
	return t


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
	int i = 1
	while (i <= 8):
		float32 t = cast(float32, i) / 8.0
		float32 u = 1.0 - t
		float32 qx = u * u * x0 + 2.0 * u * t * cx + t * t * x1
		float32 qy = u * u * y0 + 2.0 * u * t * cy + t * t * y1
		ttf_outline_push(o, px, py, qx, qy)
		px = qx
		py = qy
		i = i + 1


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

	char* flags = malloc(point_count + 1)
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
			if (flag2 & 16):
				value = value + dx
			else:
				value = value - dx
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
			if (flag3 & 32):
				value = value + dy
			else:
				value = value - dy
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

	int start = 0
	int c = 0
	while (c < contours):
		int end = contour_end[c]
		int n = end - start + 1
		if (n >= 2):
			ttf_render_contour(o, flags, px, py, start, n)
		start = end + 1
		c = c + 1

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
			if (arg1 >= 128):
				arg1 = arg1 - 256
			if (arg2 >= 128):
				arg2 = arg2 - 256
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
		if (ttf_add_glyph(f, o, component, &both, depth + 1) == 0):
			return 0
		more = flags & 32
	return 1


# Append glyph gid's outline, transformed by m. Returns 1 (an empty
# glyph appends nothing), or 0 after printing why.
int ttf_add_glyph(ttf_font* f, ttf_outline* o, int gid, ttf_xform* m, int depth):
	if ((gid < 0) || (gid >= f.glyph_count)):
		print_error(c"ttf: glyph id out of range\n")
		return 0
	if (depth > 8):
		print_error(c"ttf: composite glyphs nested too deeply\n")
		return 0
	int off = ttf_glyf_offset(f, gid)
	int next = ttf_glyf_offset(f, gid + 1)
	if (off == next):
		return 1
	off = f.glyf + off
	int contours = ttf_s16(f, off)
	if (contours < 0):
		return ttf_add_composite(f, o, off, m, depth)
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
	ttf_xform identity
	identity.a = 1.0
	identity.b = 0.0
	identity.c = 0.0
	identity.d = 1.0
	identity.dx = 0.0
	identity.dy = 0.0

	int ok = ttf_add_glyph(f, &outline, gid, &identity, 0)
	if (ok):
		ok = ttf_fill(&outline, out)
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
			else:
				ttf_outline_push(o, cur_x, cur_y, x, y)
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
	if (have_ctrl):
		ttf_outline_quad(o, cur_x, cur_y, ctrl_x, ctrl_y, sx, sy)
	else if ((cur_x != sx) || (cur_y != sy)):
		ttf_outline_push(o, cur_x, cur_y, sx, sy)


# Scanline-fill the flattened outline: per subsample row, gather the
# non-zero-winding crossing intervals and accumulate 4x4 coverage.
int ttf_fill(ttf_outline* o, ttf_bitmap* out):
	if (o.count == 0):
		return 1
	if (o.overflow):
		print_error(c"ttf: outline segment cap exceeded\n")
		return 0
	float32 min_x = o.xs0[0]
	float32 max_x = o.xs0[0]
	float32 min_y = o.ys0[0]
	float32 max_y = o.ys0[0]
	int i = 0
	while (i < o.count):
		if (o.xs0[i] < min_x):
			min_x = o.xs0[i]
		if (o.xs0[i] > max_x):
			max_x = o.xs0[i]
		if (o.xs1[i] < min_x):
			min_x = o.xs1[i]
		if (o.xs1[i] > max_x):
			max_x = o.xs1[i]
		if (o.ys0[i] < min_y):
			min_y = o.ys0[i]
		if (o.ys0[i] > max_y):
			max_y = o.ys0[i]
		if (o.ys1[i] < min_y):
			min_y = o.ys1[i]
		if (o.ys1[i] > max_y):
			max_y = o.ys1[i]
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
	int row = 0
	while (row < sub_rows):
		float32 y = cast(float32, top) + (cast(float32, row) + 0.5) / 4.0
		int crossings = 0
		i = 0
		while (i < o.count):
			float32 y0 = o.ys0[i]
			float32 y1 = o.ys1[i]
			int dir = 0
			if ((y0 <= y) && (y1 > y)):
				dir = 1
			else if ((y1 <= y) && (y0 > y)):
				dir = 0 - 1
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
				if (s0 < 0):
					s0 = 0
				if (s1 > w * 4 - 1):
					s1 = w * 4 - 1
				int s = s0
				while (s <= s1):
					acc[row_base + s / 4] = acc[row_base + s / 4] + 1
					s = s + 1
			i = i + 1
		row = row + 1

	free(cast(char*, cross_x))
	free(cast(char*, cross_dir))

	out.pixels = malloc(w * h)
	i = 0
	while (i < w * h):
		int coverage = acc[i] * 255 / 16
		if (coverage > 255):
			coverage = 255
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
	int i = 0
	while (i < length):
		string_append_char(b, ttf_u8(f, off + i))
		i = i + 1


void ttf_pad4(string_builder* b):
	while (b.length % 4 != 0):
		string_append_char(b, 0)


# glyf bytes of gid: offset (absolute) in off[0], length returned.
int ttf_glyph_span(ttf_font* f, int gid, int* off):
	int start = ttf_glyf_offset(f, gid)
	int end = ttf_glyf_offset(f, gid + 1)
	off[0] = f.glyf + start
	if (end < start):
		return 0
	return end - start


# Byte size of a composite component record with the given flags
# (flags, glyph index, the two args, and its transform).
int ttf_component_size(int flags):
	int size = 4
	if (flags & 1):
		size = size + 4
	else:
		size = size + 2
	if (flags & 8):
		size = size + 2
	else if (flags & 64):
		size = size + 4
	else if (flags & 128):
		size = size + 8
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
	if (length == 0):
		return
	int contours = ttf_s16(f, off)
	if (contours >= 0):
		int head = 10 + contours * 2
		int instructions = ttf_u16(f, off + head)
		ttf_put_range(b, f, off, head)
		string_append_be16(b, 0)
		int rest = head + 2 + instructions
		if (rest < length):
			ttf_put_range(b, f, off + rest, length - rest)
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
	if (gid < f.num_hmetrics):
		return ttf_s16(f, f.hmtx + gid * 4 + 2)
	return ttf_s16(f, f.hmtx + f.num_hmetrics * 4 + (gid - f.num_hmetrics) * 2)


int ttf_checksum(char* data, int length):
	int sum = 0
	int i = 0
	while (i < length):
		int word = 0
		int k = 0
		while (k < 4):
			word = word << 8
			if (i + k < length):
				word = word | (data[i + k] & 255)
			k = k + 1
		sum = sum + word
		i = i + 4
	return sum


# Subset f to the codepoints in ranges (range_count inclusive
# [start, end] pairs, ascending and non-overlapping). Returns the new
# font's bytes (caller frees) with the length in size[0], or 0 after
# printing why.
char* ttf_subset(ttf_font* f, int* ranges, int range_count, int* size):
	int n = f.glyph_count
	char* keep = malloc(n + 1)
	int i = 0
	while (i < n):
		keep[i] = 0
		i = i + 1
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
	i = 0
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
		int right = 1
		while (right < count):
			int v = ttf_kern_units(f, old_id[left], old_id[right])
			if (v != 0):
				if (pair_count < max_pairs):
					string_append_be16(pairs, left)
					string_append_be16(pairs, right)
					string_append_be16(pairs, v & 65535)
					pair_count = pair_count + 1
				else:
					dropped = dropped + 1
			right = right + 1
		left = left + 1
	if (dropped > 0):
		print_error(c"ttf_subset: kern pairs past the format-0 limit were dropped\n")
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
	if (pair_count == 0):
		search = 0
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
	if (post_at != 0):
		ttf_put_range(post, f, post_at, 32)
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
