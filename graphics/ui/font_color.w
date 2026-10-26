/*
graphics.ui.font_color: color glyphs for lib.ttf fonts (issue #827).

Four color formats are read, in the order HarfBuzz prefers them:

- COLR version 1: the paint graph. PaintColrLayers, PaintSolid,
  linear, radial (two-point conical) and sweep gradients with pad,
  repeat and reflect color lines, PaintGlyph, PaintColrGlyph, every
  transform (affine, translate, scale, rotate and skew, with and
  without a center), PaintComposite with all 28 composite modes, and
  the ClipList. The variable formats read their default values: there
  is no variation support, so deltas are ignored.
- COLR version 0 with CPAL: layered glyphs, each a glyph id plus a
  palette index.
- CBDT/CBLC (Google, as in Noto Color Emoji): PNG bitmaps in image
  formats 17, 18 and 19 through index subtable formats 1 to 5.
- sbix (Apple): PNG and JPEG bitmaps, including 'dupe' records.

Bitmaps come from the strike nearest the requested size (the smallest
at least as large, else the largest) and are resampled to it:
area-averaged when shrinking, bilinear when growing, both in
premultiplied space so transparent edges do not darken.

ttf_color_render returns a glyph as a list of parts in paint order.
An RGBA part (straight alpha) is drawn untinted; a foreground part is
a coverage mask drawn in the text color: palette index 0xFFFF on a
COLR version 0 layer, or on a top-level PaintGlyph of a solid fill in
version 1. A foreground reference anywhere else in a version 1 graph
(a gradient stop, a nested layer) cannot be split out and paints
opaque black. Palette 0 is used throughout.

Coordinates follow lib.ttf: y-down pixels with the baseline at 0 and
the pen at x = 0; bearing_x is the left edge from the pen and
bearing_top the rows above the baseline.
*/
import lib.lib
import lib.mem
import lib.fmath
import lib.result
import lib.ttf
import graphics.image.image
import graphics.image.png
import graphics.image.jpeg


enum ttf_color_kind:
	TTF_COLOR_NONE = 0
	TTF_COLOR_COLRV0 = 1
	TTF_COLOR_COLRV1 = 2
	TTF_COLOR_CBDT = 3
	TTF_COLOR_SBIX = 4


# The color tables of one font, found once by ttf_color_init.
struct ttf_color_font:
	ttf_font* font
	int colr
	int colr_version
	int base_count        # version 0 BaseGlyphRecords
	int base_records
	int layer_records
	int layer_count
	int base_list         # version 1 BaseGlyphList, or 0
	int layer_list        # version 1 LayerList, or 0
	int clip_list         # version 1 ClipList, or 0
	int cpal
	int palette_entries
	int palette           # the first color record of palette 0, or 0
	int cbdt
	int cblc
	int sbix


# One layer of a rendered color glyph.
struct ttf_color_part:
	int foreground        # 1: w*h coverage drawn in the text color; 0: w*h*4 RGBA
	char* pixels
	int w
	int h
	int bearing_x
	int bearing_top


struct ttf_color_glyph:
	int kind
	int advance
	int count
	int cap
	ttf_color_part* parts


# ---- tables -------------------------------------------------------------

int ttf_color_u24(ttf_font* f, int off):
	return (ttf_u8(f, off) << 16) | ttf_u16(f, off + 1)


# Index f's color tables. Returns 1 when it has any usable one.
int ttf_color_init(ttf_color_font* cf, ttf_font* f):
	mem_fill[char](cast(char*, cf), 0, sizeof(ttf_color_font))
	cf.font = f
	if (f == 0): return 0
	cf.colr = ttf_table(f, c"COLR")
	cf.cpal = ttf_table(f, c"CPAL")
	if ((cf.colr != 0) && (cf.cpal != 0)):
		int colr = cf.colr
		cf.colr_version = ttf_u16(f, colr)
		cf.base_count = ttf_u16(f, colr + 2)
		if (ttf_u32(f, colr + 4) != 0): cf.base_records = colr + ttf_u32(f, colr + 4)
		if (ttf_u32(f, colr + 8) != 0): cf.layer_records = colr + ttf_u32(f, colr + 8)
		cf.layer_count = ttf_u16(f, colr + 12)
		if (cf.base_records == 0): cf.base_count = 0
		if (cf.layer_records == 0): cf.layer_count = 0
		if (cf.colr_version >= 1):
			if (ttf_u32(f, colr + 14) != 0): cf.base_list = colr + ttf_u32(f, colr + 14)
			if (ttf_u32(f, colr + 18) != 0): cf.layer_list = colr + ttf_u32(f, colr + 18)
			if (ttf_u32(f, colr + 22) != 0): cf.clip_list = colr + ttf_u32(f, colr + 22)
		int cpal = cf.cpal
		cf.palette_entries = ttf_u16(f, cpal + 2)
		if ((ttf_u16(f, cpal + 4) > 0) && (cf.palette_entries > 0)):
			cf.palette = cpal + ttf_u32(f, cpal + 8) + ttf_u16(f, cpal + 12) * 4
	else:
		cf.colr = 0
	cf.cbdt = ttf_table(f, c"CBDT")
	cf.cblc = ttf_table(f, c"CBLC")
	if ((cf.cbdt == 0) || (cf.cblc == 0)):
		cf.cbdt = 0
		cf.cblc = 0
	cf.sbix = ttf_table(f, c"sbix")
	return (cf.colr != 0) || (cf.cbdt != 0) || (cf.sbix != 0)


# Whether f has any color table (a face to prefer for emoji).
int ttf_color_present(ttf_color_font* cf):
	return (cf.colr != 0) || (cf.cbdt != 0) || (cf.sbix != 0)


# Straight RGBA (0..1) of palette entry index times alpha. 0xFFFF and
# entries outside the palette read as the foreground: opaque black.
void ttf_color_palette(ttf_color_font* cf, int index, float32 alpha, float32* rgba):
	rgba[0] = 0.0
	rgba[1] = 0.0
	rgba[2] = 0.0
	rgba[3] = alpha
	if ((index == 65535) || (index >= cf.palette_entries) || (cf.palette == 0)): return
	ttf_font* f = cf.font
	int rec = cf.palette + index * 4
	rgba[2] = cast(float32, ttf_u8(f, rec)) / 255.0
	rgba[1] = cast(float32, ttf_u8(f, rec + 1)) / 255.0
	rgba[0] = cast(float32, ttf_u8(f, rec + 2)) / 255.0
	rgba[3] = alpha * cast(float32, ttf_u8(f, rec + 3)) / 255.0


# The version 0 BaseGlyphRecord of gid (binary search), or 0.
int ttf_color_v0_record(ttf_color_font* cf, int gid):
	if (cf.colr == 0): return 0
	int lo = 0
	int hi = cf.base_count - 1
	while (lo <= hi):
		int mid = (lo + hi) / 2
		int rec = cf.base_records + mid * 6
		int g = ttf_u16(cf.font, rec)
		if (g == gid):
			if (ttf_u16(cf.font, rec + 4) == 0): return 0
			return rec
		if (g < gid): lo = mid + 1
		else: hi = mid - 1
	return 0


# The version 1 root paint of gid (binary search), or 0.
int ttf_color_v1_paint(ttf_color_font* cf, int gid):
	if ((cf.colr == 0) || (cf.base_list == 0)): return 0
	ttf_font* f = cf.font
	int lo = 0
	int hi = ttf_u32(f, cf.base_list) - 1
	if (hi > (f.size - cf.base_list) / 6): hi = (f.size - cf.base_list) / 6
	while (lo <= hi):
		int mid = (lo + hi) / 2
		int rec = cf.base_list + 4 + mid * 6
		int g = ttf_u16(f, rec)
		if (g == gid):
			int off = ttf_u32(f, rec + 2)
			if (off == 0): return 0
			return cf.base_list + off
		if (g < gid): lo = mid + 1
		else: hi = mid - 1
	return 0


# The ClipBox of gid in font units (box = xMin, yMin, xMax, yMax).
# Returns 0 when it has none.
int ttf_color_clip_box(ttf_color_font* cf, int gid, int* box):
	if (cf.clip_list == 0): return 0
	ttf_font* f = cf.font
	int count = ttf_u32(f, cf.clip_list + 1)
	if (count > (f.size - cf.clip_list) / 7): count = (f.size - cf.clip_list) / 7
	for i in range(count):
		int rec = cf.clip_list + 5 + i * 7
		if ((gid >= ttf_u16(f, rec)) && (gid <= ttf_u16(f, rec + 2))):
			int clip = cf.clip_list + ttf_color_u24(f, rec + 4)
			for k in range(4): box[k] = ttf_s16(f, clip + 1 + k * 2)
			return 1
	return 0


struct ttf_color_bitmap_ref:
	int kind
	int strike_ppem
	int image           # absolute offset of the PNG/JPEG data
	int length
	int jpeg
	int w               # bitmap metrics at strike_ppem; w = 0 until read from the image
	int h
	int bearing_x
	int bearing_top     # top edge above the baseline
	int have_metrics


# Big glyph metrics (height, width, horiBearingX, horiBearingY, ...) at off.
void ttf_color_big_metrics(ttf_font* f, int off, ttf_color_bitmap_ref* ref):
	ref.h = ttf_u8(f, off)
	ref.w = ttf_u8(f, off + 1)
	int bx = ttf_u8(f, off + 2)
	int by = ttf_u8(f, off + 3)
	if (bx >= 128): bx = bx - 256
	if (by >= 128): by = by - 256
	ref.bearing_x = bx
	ref.bearing_top = by
	ref.have_metrics = 1


# Find gid's image in one CBLC strike. Returns 1 and fills ref.
int ttf_color_cblc_lookup(ttf_color_font* cf, int strike, int gid, ttf_color_bitmap_ref* ref):
	ttf_font* f = cf.font
	int array = cf.cblc + ttf_u32(f, strike)
	int tables = ttf_u32(f, strike + 8)
	if (tables > 4096): tables = 4096
	for k in range(tables):
		int first = ttf_u16(f, array + k * 8)
		int last = ttf_u16(f, array + k * 8 + 2)
		if ((gid < first) || (gid > last)): continue
		int sub = array + ttf_u32(f, array + k * 8 + 4)
		int index_format = ttf_u16(f, sub)
		int image_format = ttf_u16(f, sub + 2)
		int data = cf.cbdt + ttf_u32(f, sub + 4)
		int start = 0
		int end = 0
		int metrics = 0
		if (index_format == 1):
			start = ttf_u32(f, sub + 8 + (gid - first) * 4)
			end = ttf_u32(f, sub + 8 + (gid - first + 1) * 4)
		else if (index_format == 2):
			int size = ttf_u32(f, sub + 8)
			metrics = sub + 12
			start = size * (gid - first)
			end = start + size
		else if (index_format == 3):
			start = ttf_u16(f, sub + 8 + (gid - first) * 2)
			end = ttf_u16(f, sub + 8 + (gid - first + 1) * 2)
		else if (index_format == 4):
			int glyphs = ttf_u32(f, sub + 8)
			if (glyphs > 65536): glyphs = 65536
			for j in range(glyphs):
				if (ttf_u16(f, sub + 12 + j * 4) == gid):
					start = ttf_u16(f, sub + 12 + j * 4 + 2)
					end = ttf_u16(f, sub + 12 + j * 4 + 6)
		else if (index_format == 5):
			int size = ttf_u32(f, sub + 8)
			metrics = sub + 12
			int glyphs = ttf_u32(f, sub + 20)
			if (glyphs > 65536): glyphs = 65536
			for j in range(glyphs):
				if (ttf_u16(f, sub + 24 + j * 2) == gid):
					start = size * j
					end = start + size
		if ((end <= start) || (start < 0)): return 0
		int at = data + start
		int length = end - start
		if ((at <= 0) || (at > f.size - length)): return 0
		ref.kind = TTF_COLOR_CBDT
		ref.jpeg = 0
		if (image_format == 17):
			if (length < 9): return 0
			ref.h = ttf_u8(f, at)
			ref.w = ttf_u8(f, at + 1)
			int bx = ttf_u8(f, at + 2)
			int by = ttf_u8(f, at + 3)
			if (bx >= 128): bx = bx - 256
			if (by >= 128): by = by - 256
			ref.bearing_x = bx
			ref.bearing_top = by
			ref.have_metrics = 1
			ref.image = at + 9
			ref.length = ttf_u32(f, at + 5)
		else if (image_format == 18):
			if (length < 12): return 0
			ttf_color_big_metrics(f, at, ref)
			ref.image = at + 12
			ref.length = ttf_u32(f, at + 8)
		else if (image_format == 19):
			if ((metrics == 0) || (length < 4)): return 0
			ttf_color_big_metrics(f, metrics, ref)
			ref.image = at + 4
			ref.length = ttf_u32(f, at)
		else:
			return 0
		if ((ref.length <= 0) || (ref.image + ref.length > at + length)): return 0
		return 1
	return 0


# Which strike of size ppem (have) is better for want: the smallest at
# least as large, else the largest.
int ttf_color_better_strike(int have, int candidate, int want):
	if (have <= 0): return 1
	if (have >= want):
		return (candidate >= want) && (candidate < have)
	return candidate > have


int ttf_color_cbdt_find(ttf_color_font* cf, int gid, int ppem, ttf_color_bitmap_ref* ref):
	if (cf.cblc == 0): return 0
	ttf_font* f = cf.font
	int sizes = ttf_u32(f, cf.cblc + 4)
	if (sizes > 256): sizes = 256
	int best = 0
	for i in range(sizes):
		int strike = cf.cblc + 8 + i * 48
		if ((gid < ttf_u16(f, strike + 40)) || (gid > ttf_u16(f, strike + 42))): continue
		int size = ttf_u8(f, strike + 45)
		ttf_color_bitmap_ref probe
		mem_fill[char](cast(char*, &probe), 0, sizeof(ttf_color_bitmap_ref))
		if (!ttf_color_cblc_lookup(cf, strike, gid, &probe)): continue
		if (ttf_color_better_strike(best, size, ppem)):
			best = size
			ref[0] = probe
			ref.strike_ppem = size
	return best > 0


# The glyph data record of gid in an sbix strike, following one 'dupe'.
# Returns its offset and stores its length, or 0.
int ttf_color_sbix_record(ttf_color_font* cf, int strike, int gid, int* length):
	ttf_font* f = cf.font
	for hop in range(2):
		if ((gid < 0) || (gid >= f.glyph_count)): return 0
		int start = ttf_u32(f, strike + 4 + gid * 4)
		int end = ttf_u32(f, strike + 8 + gid * 4)
		if (end - start < 9): return 0
		int at = strike + start
		if ((at <= 0) || (at > f.size - (end - start))): return 0
		if ((ttf_u8(f, at + 4) == 'd') && (ttf_u8(f, at + 5) == 'u') && (ttf_u8(f, at + 6) == 'p') && (ttf_u8(f, at + 7) == 'e')):
			gid = ttf_u16(f, at + 8)
			continue
		length[0] = end - start
		return at
	return 0


int ttf_color_sbix_find(ttf_color_font* cf, int gid, int ppem, ttf_color_bitmap_ref* ref):
	if (cf.sbix == 0): return 0
	ttf_font* f = cf.font
	int strikes = ttf_u32(f, cf.sbix + 4)
	if (strikes > 256): strikes = 256
	int best = 0
	for i in range(strikes):
		int strike = cf.sbix + ttf_u32(f, cf.sbix + 8 + i * 4)
		int size = ttf_u16(f, strike)
		int length = 0
		int at = ttf_color_sbix_record(cf, strike, gid, &length)
		if (at == 0): continue
		int png = (ttf_u8(f, at + 4) == 'p') && (ttf_u8(f, at + 5) == 'n') && (ttf_u8(f, at + 6) == 'g') && (ttf_u8(f, at + 7) == ' ')
		int jpg = (ttf_u8(f, at + 4) == 'j') && (ttf_u8(f, at + 5) == 'p') && (ttf_u8(f, at + 6) == 'g') && (ttf_u8(f, at + 7) == ' ')
		if ((!png && !jpg) || (size <= 0)): continue
		if (ttf_color_better_strike(best, size, ppem)):
			best = size
			mem_fill[char](cast(char*, ref), 0, sizeof(ttf_color_bitmap_ref))
			ref.kind = TTF_COLOR_SBIX
			ref.strike_ppem = size
			ref.image = at + 8
			ref.length = length - 8
			ref.jpeg = jpg
			# The bitmap's bottom-left corner sits at the origin offset.
			ref.bearing_x = ttf_s16(f, at)
			ref.bearing_top = ttf_s16(f, at + 2)
			ref.have_metrics = 0
	return best > 0


# Which color format draws gid (TTF_COLOR_NONE: its outline).
int ttf_color_glyph_kind(ttf_color_font* cf, int gid):
	if ((gid < 0) || (gid >= cf.font.glyph_count)): return TTF_COLOR_NONE
	if (ttf_color_v1_paint(cf, gid) != 0): return TTF_COLOR_COLRV1
	if (ttf_color_v0_record(cf, gid) != 0): return TTF_COLOR_COLRV0
	ttf_color_bitmap_ref ref
	if (ttf_color_cbdt_find(cf, gid, 64, &ref)): return TTF_COLOR_CBDT
	if (ttf_color_sbix_find(cf, gid, 64, &ref)): return TTF_COLOR_SBIX
	return TTF_COLOR_NONE


# ---- parts --------------------------------------------------------------

void ttf_color_glyph_init(ttf_color_glyph* g):
	g.kind = TTF_COLOR_NONE
	g.advance = 0
	g.count = 0
	g.cap = 0
	g.parts = 0


void ttf_color_glyph_free(ttf_color_glyph* g):
	for i in range(g.count):
		if (g.parts[i].pixels != 0): free(g.parts[i].pixels)
	if (g.parts != 0): free(cast(char*, g.parts))
	ttf_color_glyph_init(g)


ttf_color_part* ttf_color_add_part(ttf_color_glyph* g):
	if (g.count >= g.cap):
		int next = g.cap * 2
		if (next < 4): next = 4
		ttf_color_part* grown = cast(ttf_color_part*, malloc(next * sizeof(ttf_color_part)))
		for i in range(g.count): grown[i] = g.parts[i]
		if (g.parts != 0): free(cast(char*, g.parts))
		g.parts = grown
		g.cap = next
	ttf_color_part* p = &g.parts[g.count]
	g.count = g.count + 1
	p.foreground = 0
	p.pixels = 0
	p.w = 0
	p.h = 0
	p.bearing_x = 0
	p.bearing_top = 0
	return p


# ---- affine transforms (font units, y up) --------------------------------

void ttf_color_identity(ttf_xform* m):
	m.a = 1.0
	m.b = 0.0
	m.c = 0.0
	m.d = 1.0
	m.dx = 0.0
	m.dy = 0.0


void ttf_color_set(ttf_xform* m, float32 a, float32 b, float32 c, float32 d, float32 dx, float32 dy):
	m.a = a
	m.b = b
	m.c = c
	m.d = d
	m.dx = dx
	m.dy = dy


# out = p after q: q applies first. out may alias neither.
void ttf_color_compose(ttf_xform* out, ttf_xform* p, ttf_xform* q):
	out.a = p.a * q.a + p.c * q.b
	out.b = p.b * q.a + p.d * q.b
	out.c = p.a * q.c + p.c * q.d
	out.d = p.b * q.c + p.d * q.d
	out.dx = p.a * q.dx + p.c * q.dy + p.dx
	out.dy = p.b * q.dx + p.d * q.dy + p.dy


# out = the inverse of m. Returns 0 for a singular m.
int ttf_color_invert(ttf_xform* out, ttf_xform* m):
	float32 det = m.a * m.d - m.b * m.c
	if ((det > 0.0 - 0.0000001) && (det < 0.0000001)): return 0
	float32 inv = 1.0 / det
	out.a = m.d * inv
	out.b = 0.0 - m.b * inv
	out.c = 0.0 - m.c * inv
	out.d = m.a * inv
	out.dx = 0.0 - (out.a * m.dx + out.c * m.dy)
	out.dy = 0.0 - (out.b * m.dx + out.d * m.dy)
	return 1


float32 ttf_color_tx(ttf_xform* m, float32 x, float32 y):
	return m.a * x + m.c * y + m.dx


float32 ttf_color_ty(ttf_xform* m, float32 x, float32 y):
	return m.b * x + m.d * y + m.dy


float32 ttf_color_pi():
	return 3.14159265


# The transform of paint node at (formats 12..31) into t, returning
# its child paint's offset, or 0 when at is not a transform.
int ttf_color_transform(ttf_font* f, int at, ttf_xform* t):
	int format = ttf_u8(f, at)
	if ((format < 12) || (format > 31)): return 0
	int child = at + ttf_color_u24(f, at + 1)
	ttf_color_identity(t)
	float32 cx = 0.0
	float32 cy = 0.0
	int centered = 0
	if ((format == 12) || (format == 13)):
		int affine = at + ttf_color_u24(f, at + 4)
		float32[6] v
		for k in range(6):
			v[k] = cast(float32, ttf_s16(f, affine + k * 4)) + cast(float32, ttf_u16(f, affine + k * 4 + 2)) / 65536.0
		ttf_color_set(t, v[0], v[1], v[2], v[3], v[4], v[5])
	else if ((format == 14) || (format == 15)):
		t.dx = cast(float32, ttf_s16(f, at + 4))
		t.dy = cast(float32, ttf_s16(f, at + 6))
	else if (format <= 19):
		t.a = ttf_f2dot14(f, at + 4)
		t.d = ttf_f2dot14(f, at + 6)
		if (format >= 18):
			centered = 1
			cx = cast(float32, ttf_s16(f, at + 8))
			cy = cast(float32, ttf_s16(f, at + 10))
	else if (format <= 23):
		t.a = ttf_f2dot14(f, at + 4)
		t.d = t.a
		if (format >= 22):
			centered = 1
			cx = cast(float32, ttf_s16(f, at + 6))
			cy = cast(float32, ttf_s16(f, at + 8))
	else if (format <= 27):
		float32 angle = ttf_f2dot14(f, at + 4) * ttf_color_pi()
		float32 cs = fcos(angle)
		float32 sn = fsin(angle)
		ttf_color_set(t, cs, sn, 0.0 - sn, cs, 0.0, 0.0)
		if (format >= 26):
			centered = 1
			cx = cast(float32, ttf_s16(f, at + 6))
			cy = cast(float32, ttf_s16(f, at + 8))
	else:
		float32 x_angle = ttf_f2dot14(f, at + 4) * ttf_color_pi()
		float32 y_angle = ttf_f2dot14(f, at + 6) * ttf_color_pi()
		ttf_color_set(t, 1.0, ftan(y_angle), ftan(0.0 - x_angle), 1.0, 0.0, 0.0)
		if (format >= 30):
			centered = 1
			cx = cast(float32, ttf_s16(f, at + 8))
			cy = cast(float32, ttf_s16(f, at + 10))
	if (centered):
		# translate(c) after the operation after translate(-c).
		t.dx = cx - (t.a * cx + t.c * cy)
		t.dy = cy - (t.b * cx + t.d * cy)
	return child


# ---- fills: solid colors and gradients -----------------------------------

struct ttf_color_fill:
	int kind              # 0 none, 1 solid, 2 linear, 3 radial, 4 sweep
	float32 solid_r       # premultiplied solid color
	float32 solid_g
	float32 solid_b
	float32 solid_a
	ttf_xform to_paint    # pixel center -> the gradient's font units
	int extend            # 0 pad, 1 repeat, 2 reflect
	int stops
	float32* offsets
	float32* colors       # premultiplied, 4 per stop
	float32 x0
	float32 y0
	float32 x1
	float32 y1
	float32 r0
	float32 r1


void ttf_color_fill_free(ttf_color_fill* fill):
	if (fill.offsets != 0): free(cast(char*, fill.offsets))
	if (fill.colors != 0): free(cast(char*, fill.colors))
	fill.offsets = 0
	fill.colors = 0


void ttf_color_premultiply(float32* rgba):
	rgba[0] = rgba[0] * rgba[3]
	rgba[1] = rgba[1] * rgba[3]
	rgba[2] = rgba[2] * rgba[3]


# Read a ColorLine (var says VarColorStops, 10 bytes each), sorted by offset.
void ttf_color_line(ttf_color_font* cf, int at, int var, ttf_color_fill* fill):
	ttf_font* f = cf.font
	fill.extend = ttf_u8(f, at)
	if (fill.extend > 2): fill.extend = 0
	int n = ttf_u16(f, at + 1)
	int stride = 6
	if (var): stride = 10
	if (n > (f.size - at) / stride): n = (f.size - at) / stride
	fill.stops = n
	if (n == 0): return
	fill.offsets = cast(float32*, malloc(n * 4))
	fill.colors = cast(float32*, malloc(n * 16))
	for i in range(n):
		int rec = at + 3 + i * stride
		fill.offsets[i] = ttf_f2dot14(f, rec)
		ttf_color_palette(cf, ttf_u16(f, rec + 2), ttf_f2dot14(f, rec + 4), &fill.colors[i * 4])
		ttf_color_premultiply(&fill.colors[i * 4])
	# Insertion sort, stable for equal offsets (a hard color step).
	for i in range(1, n):
		int j = i
		while ((j > 0) && (fill.offsets[j - 1] > fill.offsets[j])):
			float32 t = fill.offsets[j]
			fill.offsets[j] = fill.offsets[j - 1]
			fill.offsets[j - 1] = t
			for k in range(4):
				float32 v = fill.colors[j * 4 + k]
				fill.colors[j * 4 + k] = fill.colors[(j - 1) * 4 + k]
				fill.colors[(j - 1) * 4 + k] = v
			j = j - 1


# The premultiplied color at position t of the fill's color line.
void ttf_color_line_at(ttf_color_fill* fill, float32 t, float32* out):
	int n = fill.stops
	if (n == 0):
		for k in range(4): out[k] = 0.0
		return
	float32 first = fill.offsets[0]
	float32 last = fill.offsets[n - 1]
	float32 span = last - first
	if ((fill.extend != 0) && (span > 0.00001)):
		float32 u = (t - first) / span
		if (fill.extend == 1):
			u = u - ffloor(u)
		else:
			u = u - 2.0 * ffloor(u * 0.5)
			if (u > 1.0): u = 2.0 - u
		t = first + u * span
	if (t <= first):
		for k in range(4): out[k] = fill.colors[k]
		return
	if (t >= last):
		for k in range(4): out[k] = fill.colors[(n - 1) * 4 + k]
		return
	int i = 0
	while ((i < n - 2) && (t >= fill.offsets[i + 1])): i = i + 1
	float32 a = fill.offsets[i]
	float32 b = fill.offsets[i + 1]
	float32 w = 0.0
	if (b > a): w = (t - a) / (b - a)
	if (w < 0.0): w = 0.0
	if (w > 1.0): w = 1.0
	for k in range(4): out[k] = fill.colors[i * 4 + k] * (1.0 - w) + fill.colors[(i + 1) * 4 + k] * w


# Parse a fill paint (formats 2..9) under ctm. Returns 0 when at is not
# a fill or its geometry is degenerate (kind stays 0: it paints nothing).
int ttf_color_fill_init(ttf_color_font* cf, int at, ttf_xform* ctm, float32 scale, ttf_color_fill* fill):
	ttf_font* f = cf.font
	mem_fill[char](cast(char*, fill), 0, sizeof(ttf_color_fill))
	int format = ttf_u8(f, at)
	if ((format < 2) || (format > 9)): return 0
	if (format <= 3):
		float32[4] solid
		ttf_color_palette(cf, ttf_u16(f, at + 1), ttf_f2dot14(f, at + 3), &solid[0])
		ttf_color_premultiply(&solid[0])
		fill.solid_r = solid[0]
		fill.solid_g = solid[1]
		fill.solid_b = solid[2]
		fill.solid_a = solid[3]
		fill.kind = 1
		return 1
	ttf_xform inverse
	if (!ttf_color_invert(&inverse, ctm)): return 1
	# Pixel centers (x right, y down) to font units, then into the
	# gradient's own space.
	ttf_xform pixel
	ttf_color_set(&pixel, 1.0 / scale, 0.0, 0.0, 0.0 - 1.0 / scale, 0.0, 0.0)
	ttf_color_compose(&fill.to_paint, &inverse, &pixel)
	int var = (format & 1)
	ttf_color_line(cf, at + ttf_color_u24(f, at + 1), var, fill)
	if (fill.stops == 0): return 1
	if (format <= 5):
		float32 x0 = cast(float32, ttf_s16(f, at + 4))
		float32 y0 = cast(float32, ttf_s16(f, at + 6))
		float32 x1 = cast(float32, ttf_s16(f, at + 8))
		float32 y1 = cast(float32, ttf_s16(f, at + 10))
		float32 x2 = cast(float32, ttf_s16(f, at + 12))
		float32 y2 = cast(float32, ttf_s16(f, at + 14))
		# p1 projected onto the normal of p0->p2 (OpenType's p1').
		float32 nx = y2 - y0
		float32 ny = x0 - x2
		float32 nn = nx * nx + ny * ny
		if (nn > 0.0):
			float32 k = ((x1 - x0) * nx + (y1 - y0) * ny) / nn
			x1 = x0 + nx * k
			y1 = y0 + ny * k
		float32 dx = x1 - x0
		float32 dy = y1 - y0
		if (dx * dx + dy * dy <= 0.0): return 1
		fill.x0 = x0
		fill.y0 = y0
		fill.x1 = dx
		fill.y1 = dy
		fill.r0 = 1.0 / (dx * dx + dy * dy)
		fill.kind = 2
	else if (format <= 7):
		fill.x0 = cast(float32, ttf_s16(f, at + 4))
		fill.y0 = cast(float32, ttf_s16(f, at + 6))
		fill.r0 = cast(float32, ttf_u16(f, at + 8))
		fill.x1 = cast(float32, ttf_s16(f, at + 10))
		fill.y1 = cast(float32, ttf_s16(f, at + 12))
		fill.r1 = cast(float32, ttf_u16(f, at + 14))
		fill.kind = 3
	else:
		fill.x0 = cast(float32, ttf_s16(f, at + 4))
		fill.y0 = cast(float32, ttf_s16(f, at + 6))
		# Angles in degrees, counter-clockwise from +x in font space.
		fill.r0 = ttf_f2dot14(f, at + 8) * 180.0
		fill.r1 = ttf_f2dot14(f, at + 10) * 180.0
		fill.kind = 4
	return 1


# The premultiplied color of fill at pixel center (px, py).
void ttf_color_fill_at(ttf_color_fill* fill, float32 px, float32 py, float32* out):
	if (fill.kind == 1):
		out[0] = fill.solid_r
		out[1] = fill.solid_g
		out[2] = fill.solid_b
		out[3] = fill.solid_a
		return
	for k in range(4): out[k] = 0.0
	if (fill.kind == 0): return
	ttf_xform* m = &fill.to_paint
	float32 x = ttf_color_tx(m, px, py)
	float32 y = ttf_color_ty(m, px, py)
	float32 t = 0.0
	if (fill.kind == 2):
		t = ((x - fill.x0) * fill.x1 + (y - fill.y0) * fill.y1) * fill.r0
	else if (fill.kind == 3):
		# Two-point conical: the largest t with |p - c(t)| = r(t) >= 0.
		float32 cdx = fill.x1 - fill.x0
		float32 cdy = fill.y1 - fill.y0
		float32 dr = fill.r1 - fill.r0
		float32 pdx = x - fill.x0
		float32 pdy = y - fill.y0
		float32 a = cdx * cdx + cdy * cdy - dr * dr
		float32 b = pdx * cdx + pdy * cdy + fill.r0 * dr
		float32 c = pdx * pdx + pdy * pdy - fill.r0 * fill.r0
		if ((a > 0.0 - 0.0001) && (a < 0.0001)):
			if ((b > 0.0 - 0.0001) && (b < 0.0001)): return
			t = c / (2.0 * b)
			if (fill.r0 + t * dr < 0.0): return
		else:
			float32 disc = b * b - a * c
			if (disc < 0.0): return
			float32 root = fsqrt(disc)
			float32 t1 = (b + root) / a
			float32 t2 = (b - root) / a
			if (t2 > t1):
				float32 swap = t1
				t1 = t2
				t2 = swap
			if (fill.r0 + t1 * dr >= 0.0): t = t1
			else if (fill.r0 + t2 * dr >= 0.0): t = t2
			else: return
	else:
		float32 angle = fatan2(y - fill.y0, x - fill.x0) * 180.0 / ttf_color_pi()
		if (angle < 0.0): angle = angle + 360.0
		float32 span = fill.r1 - fill.r0
		if ((span > 0.0 - 0.0001) && (span < 0.0001)):
			t = 0.0
			if (angle >= fill.r0): t = 1.0
			if (fill.stops > 0):
				if (t > 0.5): t = fill.offsets[fill.stops - 1] + 1.0
				else: t = fill.offsets[0] - 1.0
			if (fill.extend != 0):
				# A zero-width sweep has no repeat: pad it.
				int saved = fill.extend
				fill.extend = 0
				ttf_color_line_at(fill, t, out)
				fill.extend = saved
				return
		else:
			t = (angle - fill.r0) / span
	ttf_color_line_at(fill, t, out)


# ---- the painter ----------------------------------------------------------

# A premultiplied RGBA float canvas over pixel rect (left, top, w, h).
struct ttf_color_painter:
	ttf_color_font* cf
	float32 scale         # pixels per font unit
	int left
	int top
	int w
	int h
	int budget            # paint nodes left: a cycle or bomb stops here
	int failed


float32* ttf_color_canvas(ttf_color_painter* p):
	float32* px = cast(float32*, malloc(p.w * p.h * 16 + 16))
	for i in range(p.w * p.h * 4): px[i] = 0.0
	return px


# src over dst at pixel i.
void ttf_color_over(float32* dst, int i, float32* src):
	float32 keep = 1.0 - src[3]
	dst[i * 4] = src[0] + dst[i * 4] * keep
	dst[i * 4 + 1] = src[1] + dst[i * 4 + 1] * keep
	dst[i * 4 + 2] = src[2] + dst[i * 4 + 2] * keep
	dst[i * 4 + 3] = src[3] + dst[i * 4 + 3] * keep


# Glyph gid's coverage under m (font units) at the painter's scale.
int ttf_color_outline(ttf_color_painter* p, int gid, ttf_xform* m, ttf_bitmap* out):
	ttf_font* f = p.cf.font
	out.pixels = 0
	out.w = 0
	out.h = 0
	out.bearing_x = 0
	out.bearing_top = 0
	out.advance = 0
	if ((gid < 0) || (gid >= f.glyph_count)): return 0
	ttf_outline o
	o.cap = 256
	o.count = 0
	o.overflow = 0
	o.xs0 = cast(float32*, malloc(o.cap * 4))
	o.ys0 = cast(float32*, malloc(o.cap * 4))
	o.xs1 = cast(float32*, malloc(o.cap * 4))
	o.ys1 = cast(float32*, malloc(o.cap * 4))
	o.scale = p.scale
	o.skew = 0.0
	o.points = 0
	int ok = ttf_add_glyph(f, &o, gid, m, 0)
	if (ok): ok = ttf_fill(&o, out)
	free(cast(char*, o.xs0))
	free(cast(char*, o.ys0))
	free(cast(char*, o.xs1))
	free(cast(char*, o.ys1))
	return ok


# Coverage (0..1) of bitmap bm at canvas pixel (i, j).
float32 ttf_color_coverage(ttf_color_painter* p, ttf_bitmap* bm, int i, int j):
	int x = p.left + i - bm.bearing_x
	int y = p.top + j + bm.bearing_top
	if ((x < 0) || (y < 0) || (x >= bm.w) || (y >= bm.h)): return 0.0
	return cast(float32, bm.pixels[y * bm.w + x] & 255) / 255.0


void ttf_color_paint(ttf_color_painter* p, int at, ttf_xform* ctm, float32* dst, int depth);


# Fill the whole canvas with a fill paint, under mask (0: everywhere).
void ttf_color_paint_fill(ttf_color_painter* p, int at, ttf_xform* ctm, float32* dst, ttf_bitmap* mask):
	ttf_color_fill fill
	ttf_color_fill_init(p.cf, at, ctm, p.scale, &fill)
	if (fill.kind != 0):
		float32[4] color
		for j in range(p.h):
			for i in range(p.w):
				float32 cov = 1.0
				if (mask != 0):
					cov = ttf_color_coverage(p, mask, i, j)
					if (cov <= 0.0): continue
				ttf_color_fill_at(&fill, cast(float32, p.left + i) + 0.5, cast(float32, p.top + j) + 0.5, &color[0])
				if (cov < 1.0):
					for k in range(4): color[k] = color[k] * cov
				ttf_color_over(dst, j * p.w + i, &color[0])
	ttf_color_fill_free(&fill)


# The fill a chain of transforms at `at` ends in, composing ctm into
# out; 0 when the chain ends in anything else.
int ttf_color_fill_chain(ttf_color_painter* p, int at, ttf_xform* ctm, ttf_xform* out):
	ttf_font* f = p.cf.font
	out[0] = ctm[0]
	for hop in range(32):
		int format = ttf_u8(f, at)
		if ((format >= 2) && (format <= 9)): return at
		ttf_xform t
		int child = ttf_color_transform(f, at, &t)
		if (child == 0): return 0
		ttf_xform both
		ttf_color_compose(&both, out, &t)
		out[0] = both
		at = child
	return 0


# Separable blend function B(cb, cs) of a PaintComposite mode (13..23).
float32 ttf_color_blend(int mode, float32 cb, float32 cs):
	if (mode == 13): return cb + cs - cb * cs
	if (mode == 14): return ttf_color_blend(19, cs, cb)
	if (mode == 15):
		if (cb < cs): return cb
		return cs
	if (mode == 16):
		if (cb > cs): return cb
		return cs
	if (mode == 17):
		if (cb <= 0.0): return 0.0
		if (cs >= 1.0): return 1.0
		float32 v = cb / (1.0 - cs)
		if (v > 1.0): return 1.0
		return v
	if (mode == 18):
		if (cb >= 1.0): return 1.0
		if (cs <= 0.0): return 0.0
		float32 v = (1.0 - cb) / cs
		if (v > 1.0): return 0.0
		return 1.0 - v
	if (mode == 19):
		if (cs <= 0.5): return cb * 2.0 * cs
		return ttf_color_blend(13, cb, 2.0 * cs - 1.0)
	if (mode == 20):
		if (cs <= 0.5): return cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb)
		float32 d = fsqrt(cb)
		if (cb <= 0.25): d = ((16.0 * cb - 12.0) * cb + 4.0) * cb
		return cb + (2.0 * cs - 1.0) * (d - cb)
	if (mode == 21):
		if (cb > cs): return cb - cs
		return cs - cb
	if (mode == 22): return cb + cs - 2.0 * cb * cs
	return cb * cs


float32 ttf_color_lum(float32* c):
	return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]


void ttf_color_set_lum(float32* c, float32 l):
	float32 d = l - ttf_color_lum(c)
	for k in range(3): c[k] = c[k] + d
	l = ttf_color_lum(c)
	float32 n = c[0]
	float32 x = c[0]
	for k in range(1, 3):
		if (c[k] < n): n = c[k]
		if (c[k] > x): x = c[k]
	for k in range(3):
		if ((n < 0.0) && (l - n > 0.000001)): c[k] = l + (c[k] - l) * l / (l - n)
		if ((x > 1.0) && (x - l > 0.000001)): c[k] = l + (c[k] - l) * (1.0 - l) / (x - l)


float32 ttf_color_sat(float32* c):
	float32 n = c[0]
	float32 x = c[0]
	for k in range(1, 3):
		if (c[k] < n): n = c[k]
		if (c[k] > x): x = c[k]
	return x - n


void ttf_color_set_sat(float32* c, float32 s):
	int hi = 0
	int lo = 0
	for k in range(1, 3):
		if (c[k] > c[hi]): hi = k
		if (c[k] < c[lo]): lo = k
	if (hi == lo):
		for k in range(3): c[k] = 0.0
		return
	int mid = 3 - hi - lo
	float32 range_ = c[hi] - c[lo]
	c[mid] = (c[mid] - c[lo]) * s / range_
	c[hi] = s
	c[lo] = 0.0


# Composite src onto dst (both premultiplied) with mode, into dst.
void ttf_color_composite(float32* dst, float32* src, int count, int mode):
	float32[3] cb
	float32[3] cs
	float32[3] mixed
	for i in range(count):
		float32* d = &dst[i * 4]
		float32* s = &src[i * 4]
		float32 da = d[3]
		float32 sa = s[3]
		if (mode <= 12):
			# Porter-Duff: result = s * fs + d * fd.
			float32 fs = 0.0
			float32 fd = 0.0
			if (mode == 1): fs = 1.0
			else if (mode == 2): fd = 1.0
			else if (mode == 3):
				fs = 1.0
				fd = 1.0 - sa
			else if (mode == 4):
				fs = 1.0 - da
				fd = 1.0
			else if (mode == 5): fs = da
			else if (mode == 6): fd = sa
			else if (mode == 7): fs = 1.0 - da
			else if (mode == 8): fd = 1.0 - sa
			else if (mode == 9):
				fs = da
				fd = 1.0 - sa
			else if (mode == 10):
				fs = 1.0 - da
				fd = sa
			else if (mode == 11):
				fs = 1.0 - da
				fd = 1.0 - sa
			else if (mode == 12):
				fs = 1.0
				fd = 1.0
			for k in range(4):
				float32 v = s[k] * fs + d[k] * fd
				if (v > 1.0): v = 1.0
				d[k] = v
			continue
		for k in range(3):
			cb[k] = 0.0
			cs[k] = 0.0
			if (da > 0.0): cb[k] = d[k] / da
			if (sa > 0.0): cs[k] = s[k] / sa
		if (mode <= 23):
			for k in range(3): mixed[k] = ttf_color_blend(mode, cb[k], cs[k])
		else:
			for k in range(3): mixed[k] = cs[k]
			if (mode == 24):
				ttf_color_set_sat(&mixed[0], ttf_color_sat(&cb[0]))
				ttf_color_set_lum(&mixed[0], ttf_color_lum(&cb[0]))
			else if (mode == 25):
				for k in range(3): mixed[k] = cb[k]
				ttf_color_set_sat(&mixed[0], ttf_color_sat(&cs[0]))
				ttf_color_set_lum(&mixed[0], ttf_color_lum(&cb[0]))
			else if (mode == 26):
				ttf_color_set_lum(&mixed[0], ttf_color_lum(&cb[0]))
			else:
				for k in range(3): mixed[k] = cb[k]
				ttf_color_set_lum(&mixed[0], ttf_color_lum(&cs[0]))
		float32 both = sa * da
		for k in range(3):
			d[k] = s[k] * (1.0 - da) + d[k] * (1.0 - sa) + both * mixed[k]
		d[3] = sa + da - both


# Paint the node at `at` under ctm src-over onto dst.
void ttf_color_paint(ttf_color_painter* p, int at, ttf_xform* ctm, float32* dst, int depth):
	ttf_color_font* cf = p.cf
	ttf_font* f = cf.font
	if ((depth > 64) || (p.budget <= 0) || (at <= 0) || (at >= f.size)):
		p.failed = 1
		return
	p.budget = p.budget - 1
	int format = ttf_u8(f, at)
	if (format == 1):
		if (cf.layer_list == 0): return
		int count = ttf_u8(f, at + 1)
		int first = ttf_u32(f, at + 2)
		int total = ttf_u32(f, cf.layer_list)
		for i in range(count):
			if ((first + i < 0) || (first + i >= total)): return
			ttf_color_paint(p, cf.layer_list + ttf_u32(f, cf.layer_list + 4 + (first + i) * 4), ctm, dst, depth + 1)
	else if ((format >= 2) && (format <= 9)):
		ttf_color_paint_fill(p, at, ctm, dst, 0)
	else if (format == 10):
		int child = at + ttf_color_u24(f, at + 1)
		ttf_bitmap bm
		if (!ttf_color_outline(p, ttf_u16(f, at + 4), ctm, &bm)):
			p.failed = 1
			return
		if (bm.pixels == 0): return
		ttf_xform chain
		int fill = ttf_color_fill_chain(p, child, ctm, &chain)
		if (fill != 0):
			ttf_color_paint_fill(p, fill, &chain, dst, &bm)
		else:
			float32* layer = ttf_color_canvas(p)
			ttf_color_paint(p, child, ctm, layer, depth + 1)
			for j in range(p.h):
				for i in range(p.w):
					float32 cov = ttf_color_coverage(p, &bm, i, j)
					if (cov <= 0.0): continue
					int n = j * p.w + i
					for k in range(4): layer[n * 4 + k] = layer[n * 4 + k] * cov
					ttf_color_over(dst, n, &layer[n * 4])
			free(cast(char*, layer))
		free(bm.pixels)
	else if (format == 11):
		int root = ttf_color_v1_paint(cf, ttf_u16(f, at + 1))
		if (root != 0): ttf_color_paint(p, root, ctm, dst, depth + 1)
	else if ((format >= 12) && (format <= 31)):
		ttf_xform t
		int child = ttf_color_transform(f, at, &t)
		ttf_xform both
		ttf_color_compose(&both, ctm, &t)
		ttf_color_paint(p, child, &both, dst, depth + 1)
	else if (format == 32):
		float32* source = ttf_color_canvas(p)
		float32* backdrop = ttf_color_canvas(p)
		ttf_color_paint(p, at + ttf_color_u24(f, at + 5), ctm, backdrop, depth + 1)
		ttf_color_paint(p, at + ttf_color_u24(f, at + 1), ctm, source, depth + 1)
		ttf_color_composite(backdrop, source, p.w * p.h, ttf_u8(f, at + 4))
		for n in range(p.w * p.h): ttf_color_over(dst, n, &backdrop[n * 4])
		free(cast(char*, source))
		free(cast(char*, backdrop))


# Grow box (pixel space: min x, min y, max x, max y) by font-unit point
# (x, y) under m.
void ttf_color_bound_point(ttf_color_painter* p, ttf_xform* m, float32 x, float32 y, float32* box, int* have):
	float32 px = ttf_color_tx(m, x, y) * p.scale
	float32 py = 0.0 - ttf_color_ty(m, x, y) * p.scale
	if (!have[0]):
		box[0] = px
		box[1] = py
		box[2] = px
		box[3] = py
		have[0] = 1
		return
	if (px < box[0]): box[0] = px
	if (py < box[1]): box[1] = py
	if (px > box[2]): box[2] = px
	if (py > box[3]): box[3] = py


# The pixel bounds of everything the node at `at` can paint: its glyph
# outlines' boxes under their transforms.
void ttf_color_bounds(ttf_color_painter* p, int at, ttf_xform* ctm, float32* box, int* have, int depth):
	ttf_color_font* cf = p.cf
	ttf_font* f = cf.font
	if ((depth > 64) || (p.budget <= 0) || (at <= 0) || (at >= f.size)): return
	p.budget = p.budget - 1
	int format = ttf_u8(f, at)
	if (format == 1):
		if (cf.layer_list == 0): return
		int count = ttf_u8(f, at + 1)
		int first = ttf_u32(f, at + 2)
		int total = ttf_u32(f, cf.layer_list)
		for i in range(count):
			if ((first + i < 0) || (first + i >= total)): return
			ttf_color_bounds(p, cf.layer_list + ttf_u32(f, cf.layer_list + 4 + (first + i) * 4), ctm, box, have, depth + 1)
	else if (format == 10):
		int[4] gb
		if (!ttf_glyph_bbox(f, ttf_u16(f, at + 4), &gb[0])): return
		ttf_color_bound_point(p, ctm, cast(float32, gb[0]), cast(float32, gb[1]), box, have)
		ttf_color_bound_point(p, ctm, cast(float32, gb[2]), cast(float32, gb[1]), box, have)
		ttf_color_bound_point(p, ctm, cast(float32, gb[0]), cast(float32, gb[3]), box, have)
		ttf_color_bound_point(p, ctm, cast(float32, gb[2]), cast(float32, gb[3]), box, have)
	else if (format == 11):
		int root = ttf_color_v1_paint(cf, ttf_u16(f, at + 1))
		if (root != 0): ttf_color_bounds(p, root, ctm, box, have, depth + 1)
	else if ((format >= 12) && (format <= 31)):
		ttf_xform t
		int child = ttf_color_transform(f, at, &t)
		ttf_xform both
		ttf_color_compose(&both, ctm, &t)
		ttf_color_bounds(p, child, &both, box, have, depth + 1)
	else if (format == 32):
		ttf_color_bounds(p, at + ttf_color_u24(f, at + 1), ctm, box, have, depth + 1)
		ttf_color_bounds(p, at + ttf_color_u24(f, at + 5), ctm, box, have, depth + 1)


# Size the painter's canvas to box (pixel space), rounded outward.
# Returns 0 for an empty or implausibly large box.
int ttf_color_painter_box(ttf_color_painter* p, float32* box):
	p.left = ttf_floor(box[0])
	p.top = ttf_floor(box[1])
	p.w = ttf_ceil(box[2]) - p.left
	p.h = ttf_ceil(box[3]) - p.top
	return (p.w > 0) && (p.h > 0) && (p.w <= 2048) && (p.h <= 2048)


# Move the canvas's painted pixels into a new RGBA part (cropped to its
# ink) and clear it.
void ttf_color_flush(ttf_color_painter* p, float32* canvas, ttf_color_glyph* out):
	int x0 = p.w
	int y0 = p.h
	int x1 = 0 - 1
	int y1 = 0 - 1
	for j in range(p.h):
		for i in range(p.w):
			if (canvas[(j * p.w + i) * 4 + 3] * 255.0 < 0.5): continue
			if (i < x0): x0 = i
			if (i > x1): x1 = i
			if (j < y0): y0 = j
			if (j > y1): y1 = j
	if (x1 >= x0):
		ttf_color_part* part = ttf_color_add_part(out)
		part.w = x1 - x0 + 1
		part.h = y1 - y0 + 1
		part.bearing_x = p.left + x0
		part.bearing_top = 0 - (p.top + y0)
		part.pixels = cast(char*, malloc(part.w * part.h * 4))
		for j in range(part.h):
			for i in range(part.w):
				float32* c = &canvas[((y0 + j) * p.w + x0 + i) * 4]
				char* o = &part.pixels[(j * part.w + i) * 4]
				float32 a = c[3]
				if (a > 1.0): a = 1.0
				for k in range(3):
					float32 v = 0.0
					if (a > 0.0): v = c[k] / a
					if (v > 1.0): v = 1.0
					if (v < 0.0): v = 0.0
					o[k] = cast(int, v * 255.0 + 0.5)
				o[3] = cast(int, a * 255.0 + 0.5)
	for n in range(p.w * p.h * 4): canvas[n] = 0.0


# Add glyph gid's coverage under ctm as a foreground part, scaled by alpha.
int ttf_color_foreground_part(ttf_color_painter* p, int gid, ttf_xform* ctm, float32 alpha, ttf_color_glyph* out):
	ttf_bitmap bm
	if (!ttf_color_outline(p, gid, ctm, &bm)): return 0
	if (bm.pixels == 0): return 1
	if (alpha < 1.0):
		for n in range(bm.w * bm.h): bm.pixels[n] = cast(int, cast(float32, bm.pixels[n] & 255) * alpha + 0.5)
	ttf_color_part* part = ttf_color_add_part(out)
	part.foreground = 1
	part.pixels = bm.pixels
	part.w = bm.w
	part.h = bm.h
	part.bearing_x = bm.bearing_x
	part.bearing_top = bm.bearing_top
	return 1


# A top-level version 1 layer that is just a glyph filled with the
# foreground: its glyph id (alpha in alpha[0]), else -1.
int ttf_color_foreground_layer(ttf_font* f, int at, float32* alpha):
	if (ttf_u8(f, at) != 10): return 0 - 1
	int child = at + ttf_color_u24(f, at + 1)
	int format = ttf_u8(f, child)
	if (((format != 2) && (format != 3)) || (ttf_u16(f, child + 1) != 65535)): return 0 - 1
	alpha[0] = ttf_f2dot14(f, child + 3)
	return ttf_u16(f, at + 4)


int ttf_color_render_colr(ttf_color_font* cf, int gid, int ppem, ttf_color_glyph* out):
	ttf_font* f = cf.font
	ttf_color_painter p
	p.cf = cf
	p.scale = cast(float32, ppem) / cast(float32, f.upem)
	p.budget = 100000
	p.failed = 0
	ttf_xform identity
	ttf_color_identity(&identity)
	int root = ttf_color_v1_paint(cf, gid)
	int record = 0
	if (root == 0): record = ttf_color_v0_record(cf, gid)
	if ((root == 0) && (record == 0)): return 0
	float32[4] box
	int have = 0
	int[4] clip
	int clipped = 0
	int first = 0
	int layers = 0
	if (root != 0):
		clipped = ttf_color_clip_box(cf, gid, &clip[0])
		if (clipped):
			ttf_color_bound_point(&p, &identity, cast(float32, clip[0]), cast(float32, clip[1]), &box[0], &have)
			ttf_color_bound_point(&p, &identity, cast(float32, clip[2]), cast(float32, clip[3]), &box[0], &have)
		else:
			ttf_color_bounds(&p, root, &identity, &box[0], &have, 0)
			p.budget = 100000
	else:
		first = ttf_u16(f, record + 2)
		layers = ttf_u16(f, record + 4)
		for i in range(layers):
			if (first + i >= cf.layer_count): break
			int[4] gb
			if (!ttf_glyph_bbox(f, ttf_u16(f, cf.layer_records + (first + i) * 4), &gb[0])): continue
			ttf_color_bound_point(&p, &identity, cast(float32, gb[0]), cast(float32, gb[1]), &box[0], &have)
			ttf_color_bound_point(&p, &identity, cast(float32, gb[2]), cast(float32, gb[3]), &box[0], &have)
	out.kind = TTF_COLOR_COLRV0
	if (root != 0): out.kind = TTF_COLOR_COLRV1
	out.advance = ttf_scale_round(f, ppem, ttf_advance_units(f, gid))
	if (!have): return 1
	# One pixel of margin for antialiased edges, as lib.ttf rasterizes.
	box[0] = box[0] - 1.0
	box[1] = box[1] - 1.0
	box[2] = box[2] + 1.0
	box[3] = box[3] + 1.0
	if (clipped):
		box[0] = box[0] + 1.0
		box[1] = box[1] + 1.0
		box[2] = box[2] - 1.0
		box[3] = box[3] - 1.0
	if (!ttf_color_painter_box(&p, &box[0])): return 0
	float32* canvas = ttf_color_canvas(&p)
	if (root != 0):
		int count = 1
		int top_layers = (ttf_u8(f, root) == 1) && (cf.layer_list != 0)
		if (top_layers):
			count = ttf_u8(f, root + 1)
			first = ttf_u32(f, root + 2)
		for i in range(count):
			int at = root
			if (top_layers):
				if ((first + i < 0) || (first + i >= ttf_u32(f, cf.layer_list))): break
				at = cf.layer_list + ttf_u32(f, cf.layer_list + 4 + (first + i) * 4)
			float32 alpha = 1.0
			int fg = ttf_color_foreground_layer(f, at, &alpha)
			if (fg >= 0):
				ttf_color_flush(&p, canvas, out)
				if (!ttf_color_foreground_part(&p, fg, &identity, alpha, out)): p.failed = 1
			else:
				ttf_color_paint(&p, at, &identity, canvas, 1)
	else:
		for i in range(layers):
			if (first + i >= cf.layer_count): break
			int rec = cf.layer_records + (first + i) * 4
			int layer_gid = ttf_u16(f, rec)
			int index = ttf_u16(f, rec + 2)
			if (index == 65535):
				ttf_color_flush(&p, canvas, out)
				if (!ttf_color_foreground_part(&p, layer_gid, &identity, 1.0, out)): p.failed = 1
				continue
			ttf_bitmap bm
			if (!ttf_color_outline(&p, layer_gid, &identity, &bm)):
				p.failed = 1
				continue
			if (bm.pixels == 0): continue
			float32[4] color
			ttf_color_palette(cf, index, 1.0, &color[0])
			ttf_color_premultiply(&color[0])
			float32[4] px
			for j in range(p.h):
				for k in range(p.w):
					float32 cov = ttf_color_coverage(&p, &bm, k, j)
					if (cov <= 0.0): continue
					for c4 in range(4): px[c4] = color[c4] * cov
					ttf_color_over(canvas, j * p.w + k, &px[0])
			free(bm.pixels)
	ttf_color_flush(&p, canvas, out)
	free(cast(char*, canvas))
	if (p.failed):
		ttf_color_glyph_free(out)
		return 0
	return 1


# ---- bitmaps --------------------------------------------------------------

# Resample a straight-alpha RGBA image to dw x dh, in premultiplied
# space: area-averaged where it shrinks, bilinear where it grows.
char* ttf_color_resample(char* src, int sw, int sh, int dw, int dh):
	char* out = cast(char*, malloc(dw * dh * 4 + 4))
	float32 fx = cast(float32, sw) / cast(float32, dw)
	float32 fy = cast(float32, sh) / cast(float32, dh)
	float32[4] acc
	for j in range(dh):
		for i in range(dw):
			for k in range(4): acc[k] = 0.0
			float32 total = 0.0
			if ((dw <= sw) && (dh <= sh)):
				float32 x0 = cast(float32, i) * fx
				float32 x1 = x0 + fx
				float32 y0 = cast(float32, j) * fy
				float32 y1 = y0 + fy
				int sy = ttf_floor(y0)
				while ((sy < sh) && (cast(float32, sy) < y1)):
					float32 wy = 1.0
					if (cast(float32, sy) < y0): wy = wy - (y0 - cast(float32, sy))
					if (cast(float32, sy + 1) > y1): wy = wy - (cast(float32, sy + 1) - y1)
					int sx = ttf_floor(x0)
					while ((sx < sw) && (cast(float32, sx) < x1)):
						float32 wx = 1.0
						if (cast(float32, sx) < x0): wx = wx - (x0 - cast(float32, sx))
						if (cast(float32, sx + 1) > x1): wx = wx - (cast(float32, sx + 1) - x1)
						float32 w = wx * wy
						char* s = &src[(sy * sw + sx) * 4]
						float32 a = cast(float32, s[3] & 255) / 255.0
						acc[0] = acc[0] + cast(float32, s[0] & 255) * a * w
						acc[1] = acc[1] + cast(float32, s[1] & 255) * a * w
						acc[2] = acc[2] + cast(float32, s[2] & 255) * a * w
						acc[3] = acc[3] + a * w
						total = total + w
						sx = sx + 1
					sy = sy + 1
			else:
				float32 cx = (cast(float32, i) + 0.5) * fx - 0.5
				float32 cy = (cast(float32, j) + 0.5) * fy - 0.5
				if (cx < 0.0): cx = 0.0
				if (cy < 0.0): cy = 0.0
				int ix = ttf_floor(cx)
				int iy = ttf_floor(cy)
				float32 tx = cx - cast(float32, ix)
				float32 ty = cy - cast(float32, iy)
				for q in range(4):
					int sx = ix + (q & 1)
					int sy = iy + (q >> 1)
					if (sx >= sw): sx = sw - 1
					if (sy >= sh): sy = sh - 1
					float32 w = 1.0 - tx
					if (q & 1): w = tx
					if (q >> 1): w = w * ty
					else: w = w * (1.0 - ty)
					char* s = &src[(sy * sw + sx) * 4]
					float32 a = cast(float32, s[3] & 255) / 255.0
					acc[0] = acc[0] + cast(float32, s[0] & 255) * a * w
					acc[1] = acc[1] + cast(float32, s[1] & 255) * a * w
					acc[2] = acc[2] + cast(float32, s[2] & 255) * a * w
					acc[3] = acc[3] + a * w
					total = total + w
			char* o = &out[(j * dw + i) * 4]
			float32 alpha = 0.0
			if (total > 0.0): alpha = acc[3] / total
			for k in range(3):
				float32 v = 0.0
				if (acc[3] > 0.0): v = acc[k] / acc[3]
				if (v > 255.0): v = 255.0
				o[k] = cast(int, v + 0.5)
			o[3] = cast(int, alpha * 255.0 + 0.5)
	return out


int ttf_color_round(float32 v):
	return ttf_floor(v + 0.5)


int ttf_color_render_bitmap(ttf_color_font* cf, int gid, int ppem, ttf_color_glyph* out):
	ttf_font* f = cf.font
	ttf_color_bitmap_ref ref
	mem_fill[char](cast(char*, &ref), 0, sizeof(ttf_color_bitmap_ref))
	if (!ttf_color_cbdt_find(cf, gid, ppem, &ref) && !ttf_color_sbix_find(cf, gid, ppem, &ref)): return 0
	image_limits limits
	limits.input_bytes = ref.length
	limits.width = 2048
	limits.height = 2048
	limits.rgba_bytes = 16777216
	wresult[rgba_image*]* decoded = 0
	if (ref.jpeg): decoded = jpeg_decode_n(f.data + ref.image, ref.length, &limits)
	else: decoded = png_decode_n(f.data + ref.image, ref.length, &limits)
	if (!decoded.ok):
		free(cast(char*, decoded))
		return 0
	rgba_image* image = decoded.value
	free(cast(char*, decoded))
	if (!ref.have_metrics):
		# sbix: the origin offset places the bottom-left corner.
		ref.bearing_top = ref.bearing_top + image.height
	float32 s = cast(float32, ppem) / cast(float32, ref.strike_ppem)
	int dw = ttf_color_round(cast(float32, image.width) * s)
	int dh = ttf_color_round(cast(float32, image.height) * s)
	if (dw < 1): dw = 1
	if (dh < 1): dh = 1
	out.kind = ref.kind
	out.advance = ttf_scale_round(f, ppem, ttf_advance_units(f, gid))
	ttf_color_part* part = ttf_color_add_part(out)
	part.w = dw
	part.h = dh
	part.bearing_x = ttf_color_round(cast(float32, ref.bearing_x) * s)
	part.bearing_top = ttf_color_round(cast(float32, ref.bearing_top) * s)
	if ((dw == image.width) && (dh == image.height)):
		part.pixels = image.pixels
		image.pixels = 0
	else:
		part.pixels = ttf_color_resample(image.pixels, image.width, image.height, dw, dh)
	rgba_image_free(image)
	return 1


# Render color glyph gid at ppem into out (initialized here; release it
# with ttf_color_glyph_free). Returns 1, or 0 when gid has no color data
# or it does not decode (out is then empty: draw the outline instead).
int ttf_color_render(ttf_color_font* cf, int gid, int ppem, ttf_color_glyph* out):
	ttf_color_glyph_init(out)
	if ((cf.font == 0) || (gid < 0) || (gid >= cf.font.glyph_count) || (ppem < 1)): return 0
	if (ttf_color_render_colr(cf, gid, ppem, out)): return 1
	ttf_color_glyph_free(out)
	if (ttf_color_render_bitmap(cf, gid, ppem, out)): return 1
	ttf_color_glyph_free(out)
	return 0
