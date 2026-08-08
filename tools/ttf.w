/*
tools.ttf: minimal TrueType reader + rasterizer for the UI atlas baker
(tools/generate_ui_atlas.w; docs/projects/ui_framework_plan.md stage 4).

Covers exactly the envelope the committed Liberation Sans needs for
ASCII 32..126: table directory, head (unitsPerEm, indexToLocFormat),
maxp, cmap format 4, hhea/hmtx, long+short loca, and SIMPLE glyf
outlines — quadratic contours flattened to line segments and filled by
the non-zero winding rule over 4x4 subsamples per pixel (unhinted
grayscale coverage). Composite glyphs and other cmap formats fail
loudly rather than mis-render: this is a build-time tool, not a
runtime text stack (issue #379 tracks that).

Coordinates: rasterizer output is y-down bitmap space with integer
metrics — bearing_x (left edge relative to the pen), bearing_top
(rows above the baseline), advance in whole pixels.
*/
import lib.lib
import lib.stream
import structures.string


struct ttf_font:
	char* data
	int size
	int upem
	int loc_long        # 1 = 32-bit loca entries, 0 = 16-bit halved
	int glyph_count
	int cmap4           # offset of the format-4 cmap subtable
	int loca
	int glyf
	int hmtx
	int num_hmetrics
	int ascent          # font units, positive up
	int descent         # font units, positive (magnitude)


int ttf_u8(ttf_font* f, int off):
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


# Offset of a table by 4-char tag, or 0 when absent.
int ttf_table(ttf_font* f, char* tag):
	int count = ttf_u16(f, 4)
	int i = 0
	while (i < count):
		int rec = 12 + i * 16
		if ((f.data[rec] == tag[0]) && (f.data[rec + 1] == tag[1]) && (f.data[rec + 2] == tag[2]) && (f.data[rec + 3] == tag[3])):
			return ttf_u32(f, rec + 8)
		i = i + 1
	return 0


# Load and index a TrueType file. Returns 1, or 0 after printing what
# was missing (bad path, absent table, no format-4 cmap).
int ttf_load(ttf_font* f, char* path):
	wstream* in = stream_open_read(path)
	if (in == 0):
		print_error(c"ttf: cannot open ")
		print_error(path)
		print_error(c"\n")
		return 0
	string_builder* blob = string_new()
	stream_read_all(in, blob)
	stream_close(in)
	f.data = blob.data
	f.size = blob.length
	free(blob)

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

	# Pick the first format-4 cmap subtable.
	f.cmap4 = 0
	int subtables = ttf_u16(f, cmap + 2)
	int i = 0
	while (i < subtables):
		int sub = cmap + ttf_u32(f, cmap + 4 + i * 8 + 4)
		if (ttf_u16(f, sub) == 4):
			f.cmap4 = sub
		i = i + 1
	if (f.cmap4 == 0):
		print_error(c"ttf: no format-4 cmap subtable\n")
		return 0
	return 1


# Glyph id for a codepoint via the format-4 cmap (0 = .notdef).
int ttf_glyph_id(ttf_font* f, int code):
	int sub = f.cmap4
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


# Segment accumulator used while flattening one glyph. Fixed caps far
# beyond the ASCII outlines (78 points max, 8 lines per curve).
struct ttf_outline:
	float32* xs0
	float32* ys0
	float32* xs1
	float32* ys1
	int count
	int cap


void ttf_outline_push(ttf_outline* o, float32 x0, float32 y0, float32 x1, float32 y1):
	if (o.count >= o.cap):
		return
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


void ttf_render_contour(ttf_outline* o, char* flags, int* px, int* py, int start, int n, float32 scale);
int ttf_fill(ttf_outline* o, ttf_bitmap* out);


# Rasterize one glyph at ppem into out. Returns 1 on success (an
# inkless glyph like space yields w = h = 0 with a valid advance), 0 on
# a composite or malformed outline (printed to stderr).
int ttf_rasterize(ttf_font* f, int gid, int ppem, ttf_bitmap* out):
	out.pixels = 0
	out.w = 0
	out.h = 0
	out.bearing_x = 0
	out.bearing_top = 0
	out.advance = ttf_scale_round(f, ppem, ttf_advance_units(f, gid))
	if ((gid < 0) || (gid >= f.glyph_count)):
		print_error(c"ttf: glyph id out of range\n")
		return 0
	int off = ttf_glyf_offset(f, gid)
	int next = ttf_glyf_offset(f, gid + 1)
	if (off == next):
		return 1
	off = f.glyf + off
	int contours = ttf_s16(f, off)
	if (contours < 0):
		print_error(c"ttf: composite glyphs are not supported\n")
		return 0

	# Contour end indices, then the flag/coordinate streams.
	int* contour_end = cast(int*, malloc(contours * __word_size__))
	int i = 0
	int point_count = 0
	while (i < contours):
		contour_end[i] = ttf_u16(f, off + 10 + i * 2)
		point_count = contour_end[i] + 1
		i = i + 1
	int instruction_length = ttf_u16(f, off + 10 + contours * 2)
	int pos = off + 12 + contours * 2 + instruction_length

	char* flags = malloc(point_count)
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
	int* px = cast(int*, malloc(point_count * __word_size__))
	int* py = cast(int*, malloc(point_count * __word_size__))
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
		px[i] = value
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
		py[i] = value
		i = i + 1

	# Flatten every contour into pixel-space (y-down, baseline at 0)
	# line segments. Off-curve runs imply on-curve midpoints.
	ttf_outline outline
	outline.cap = 4096
	outline.count = 0
	outline.xs0 = cast(float32*, malloc(outline.cap * 4))
	outline.ys0 = cast(float32*, malloc(outline.cap * 4))
	outline.xs1 = cast(float32*, malloc(outline.cap * 4))
	outline.ys1 = cast(float32*, malloc(outline.cap * 4))
	float32 scale = cast(float32, ppem) / cast(float32, f.upem)

	int start = 0
	int c = 0
	while (c < contours):
		int end = contour_end[c]
		int n = end - start + 1
		if (n >= 2):
			ttf_render_contour(&outline, flags, px, py, start, n, scale)
		start = end + 1
		c = c + 1

	free(cast(char*, contour_end))
	free(flags)
	free(cast(char*, px))
	free(cast(char*, py))

	int ok = ttf_fill(&outline, out)
	free(cast(char*, outline.xs0))
	free(cast(char*, outline.ys0))
	free(cast(char*, outline.xs1))
	free(cast(char*, outline.ys1))
	return ok


float32 ttf_px(int* px, int start, int n, int index, float32 scale):
	return cast(float32, px[start + index % n]) * scale


float32 ttf_py(int* py, int start, int n, int index, float32 scale):
	return 0.0 - cast(float32, py[start + index % n]) * scale


int ttf_on_curve(char* flags, int start, int n, int index):
	return flags[start + index % n] & 1


# Emit one contour's segments. Walks point runs handling the implied
# on-curve midpoint between consecutive off-curve control points.
void ttf_render_contour(ttf_outline* o, char* flags, int* px, int* py, int start, int n, float32 scale):
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
		sx = (ttf_px(px, start, n, 0, scale) + ttf_px(px, start, n, 1, scale)) * 0.5
		sy = (ttf_py(py, start, n, 0, scale) + ttf_py(py, start, n, 1, scale)) * 0.5
	else:
		sx = ttf_px(px, start, n, first, scale)
		sy = ttf_py(py, start, n, first, scale)

	float32 cur_x = sx
	float32 cur_y = sy
	int have_ctrl = 0
	float32 ctrl_x = 0.0
	float32 ctrl_y = 0.0
	int step = 1
	while (step <= n):
		int index = first + step
		float32 x = ttf_px(px, start, n, index, scale)
		float32 y = ttf_py(py, start, n, index, scale)
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
	if (o.count >= o.cap):
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
	if ((w <= 0) || (h <= 0) || (w > 256) || (h > 256)):
		print_error(c"ttf: implausible glyph bitmap size\n")
		return 0

	int* acc = cast(int*, malloc(w * h * __word_size__))
	i = 0
	while (i < w * h):
		acc[i] = 0
		i = i + 1

	# Crossing buffers, far above any real per-row crossing count.
	float32* cross_x = cast(float32*, malloc(64 * 4))
	int* cross_dir = cast(int*, malloc(64 * __word_size__))

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
			if ((dir != 0) && (crossings < 64)):
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
