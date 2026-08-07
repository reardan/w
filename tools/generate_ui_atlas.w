# Emits graphics/ui/font_data.w — the UI's one R8 atlas — from the
# committed Liberation Sans faces (tools/ui/*.ttf, SIL OFL 1.1) via
# tools/ttf.w, plus the procedural AA masks the Material-style widgets
# draw with (docs/projects/ui_framework_plan.md stage 4).
#
# Atlas contents, packed on 256-wide shelves with a 1px gap:
#   masks 0..6  — 0 solid white (untextured fills), 1 rounded-corner
#                 quarter disc, 2 disc, 3 ring, 4 checkmark,
#                 5 chevron, 6 blurred shadow corner tile
#   strike 0    — Liberation Sans Regular at 16 ppem (body text)
#   strike 1    — Liberation Sans Bold at 20 ppem (titles)
#
# The data lands as c"\x.." byte-string chunk functions (the
# lib/sha256.w table idiom). Atlas pixels are run-length encoded
# (tag 0: zero run, tag 1: 255 run, tag 2: literal run — decoded by
# graphics/ui/font.w); glyph records are 9-byte entries:
# x_lo, x_hi, y_lo, y_hi, w, h, advance, bearing_x+8, bearing_top+8.
#
# Run from the repo root: ./wbuild ui_font_data
import lib.lib
import lib.stream
import structures.string
import graphics.math
import tools.ttf


int gen_atlas_w():
	return 256


int gen_char_count():
	return 95


int gen_mask_count():
	return 7


# ---- atlas packing ----------------------------------------------------

struct gen_atlas:
	char* pixels
	int w
	int h_cap
	int x           # next free x on the current shelf
	int y           # current shelf top
	int shelf_h     # current shelf height (max entry + 1)
	int used_h


void gen_atlas_init(gen_atlas* a):
	a.w = gen_atlas_w()
	a.h_cap = 512
	a.pixels = malloc(a.w * a.h_cap)
	int i = 0
	while (i < a.w * a.h_cap):
		a.pixels[i] = 0
		i = i + 1
	a.x = 1
	a.y = 1
	a.shelf_h = 0
	a.used_h = 1


# Place a w*h bitmap, returning its atlas position via out_x/out_y.
# Opens a new shelf when the current one is full. Exits on overflow —
# a baker bug, not a runtime condition.
void gen_atlas_place(gen_atlas* a, char* bitmap, int w, int h, int* out_x, int* out_y):
	if (w == 0):
		out_x[0] = 0
		out_y[0] = 0
		return
	if (a.x + w + 1 > a.w):
		a.y = a.y + a.shelf_h
		a.x = 1
		a.shelf_h = 0
	if (h + 1 > a.shelf_h):
		a.shelf_h = h + 1
	if (a.y + a.shelf_h >= a.h_cap):
		print_error(c"generate_ui_atlas: atlas height cap exceeded\n")
		exit(1)
	int row = 0
	while (row < h):
		int col = 0
		while (col < w):
			a.pixels[(a.y + row) * a.w + a.x + col] = bitmap[row * w + col]
			col = col + 1
		row = row + 1
	out_x[0] = a.x
	out_y[0] = a.y
	a.x = a.x + w + 1
	if (a.y + a.shelf_h > a.used_h):
		a.used_h = a.y + a.shelf_h
	return


# Close the current shelf so the next placement starts a fresh row
# (used between the mask block and each strike).
void gen_atlas_break(gen_atlas* a):
	if (a.shelf_h > 0):
		a.y = a.y + a.shelf_h
		a.x = 1
		a.shelf_h = 0


# ---- procedural masks -------------------------------------------------

float32 gen_clamp01(float32 v):
	if (v < 0.0):
		return 0.0
	if (v > 1.0):
		return 1.0
	return v


int gen_coverage(float32 v):
	return cast(int, gen_clamp01(v) * 255.0 + 0.5)


float32 gen_capsule_dist(float32 px, float32 py, float32 ax, float32 ay, float32 bx, float32 by):
	float32 abx = bx - ax
	float32 aby = by - ay
	float32 apx = px - ax
	float32 apy = py - ay
	float32 t = gen_clamp01((apx * abx + apy * aby) / (abx * abx + aby * aby))
	float32 dx = apx - t * abx
	float32 dy = apy - t * aby
	return gfx_sqrt(dx * dx + dy * dy)


# Solid white cell: untextured fills sample its center.
char* gen_mask_white(int size):
	char* p = malloc(size * size)
	int i = 0
	while (i < size * size):
		p[i] = 255
		i = i + 1
	return p


# Quarter disc for rounded-rect corners: the arc's center sits at the
# tile's bottom-right corner, so the tile drawn at a rect's top-left
# corner (and UV-mirrored for the other three) rounds it off.
char* gen_mask_corner(int size):
	char* p = malloc(size * size)
	float32 s = cast(float32, size)
	int y = 0
	while (y < size):
		int x = 0
		while (x < size):
			float32 dx = s - (cast(float32, x) + 0.5)
			float32 dy = s - (cast(float32, y) + 0.5)
			float32 d = gfx_sqrt(dx * dx + dy * dy)
			p[y * size + x] = gen_coverage(s - d + 0.5)
			x = x + 1
		y = y + 1
	return p


char* gen_mask_disc(int size):
	char* p = malloc(size * size)
	float32 c = cast(float32, size) * 0.5
	float32 r = c - 0.5
	int y = 0
	while (y < size):
		int x = 0
		while (x < size):
			float32 dx = cast(float32, x) + 0.5 - c
			float32 dy = cast(float32, y) + 0.5 - c
			float32 d = gfx_sqrt(dx * dx + dy * dy)
			p[y * size + x] = gen_coverage(r - d + 0.5)
			x = x + 1
		y = y + 1
	return p


# Ring for the radio outline: baked 2x (40px, radius 17, stroke 4) and
# drawn at 20px, where it lands as a radius-8.5 ring with a 2px stroke.
char* gen_mask_ring(int size):
	char* p = malloc(size * size)
	float32 c = cast(float32, size) * 0.5
	float32 r = c - 3.0
	float32 half_stroke = 2.0
	int y = 0
	while (y < size):
		int x = 0
		while (x < size):
			float32 dx = cast(float32, x) + 0.5 - c
			float32 dy = cast(float32, y) + 0.5 - c
			float32 d = gfx_sqrt(dx * dx + dy * dy) - r
			if (d < 0.0):
				d = 0.0 - d
			p[y * size + x] = gen_coverage(half_stroke - d + 0.5)
			x = x + 1
		y = y + 1
	return p


# Checkmark: two round-capped strokes in a 30px tile.
char* gen_mask_check(int size):
	char* p = malloc(size * size)
	float32 s = cast(float32, size) / 30.0
	int y = 0
	while (y < size):
		int x = 0
		while (x < size):
			float32 px = cast(float32, x) + 0.5
			float32 py = cast(float32, y) + 0.5
			float32 d1 = gen_capsule_dist(px, py, 7.0 * s, 16.0 * s, 13.0 * s, 22.0 * s)
			float32 d2 = gen_capsule_dist(px, py, 13.0 * s, 22.0 * s, 23.0 * s, 9.0 * s)
			float32 d = d1
			if (d2 < d):
				d = d2
			p[y * size + x] = gen_coverage(2.2 * s - d + 0.5)
			x = x + 1
		y = y + 1
	return p


# Chevron (dropdown marker): a 'v' of two round-capped strokes.
char* gen_mask_chevron(int size):
	char* p = malloc(size * size)
	float32 s = cast(float32, size) / 24.0
	int y = 0
	while (y < size):
		int x = 0
		while (x < size):
			float32 px = cast(float32, x) + 0.5
			float32 py = cast(float32, y) + 0.5
			float32 d1 = gen_capsule_dist(px, py, 5.0 * s, 9.0 * s, 12.0 * s, 16.0 * s)
			float32 d2 = gen_capsule_dist(px, py, 12.0 * s, 16.0 * s, 19.0 * s, 9.0 * s)
			float32 d = d1
			if (d2 < d):
				d = d2
			p[y * size + x] = gen_coverage(1.8 * s - d + 0.5)
			x = x + 1
		y = y + 1
	return p


# Shadow corner tile: quadratic falloff of the signed distance to a
# radius-8 rounded corner whose center sits 8px inside the tile's
# bottom-right corner. Drawn as a 9-patch by ui_draw_shadow: corners
# sample the whole tile, edges sample the last row/column's straight
# profile, the center samples the fully-dark bottom-right texel.
char* gen_mask_shadow(int size):
	char* p = malloc(size * size)
	float32 corner = cast(float32, size) - 8.0
	float32 spread = 20.0
	int y = 0
	while (y < size):
		int x = 0
		while (x < size):
			float32 dx = corner - (cast(float32, x) + 0.5)
			float32 dy = corner - (cast(float32, y) + 0.5)
			if (dx < 0.0):
				dx = 0.0
			if (dy < 0.0):
				dy = 0.0
			float32 d = gfx_sqrt(dx * dx + dy * dy) - 8.0
			float32 f = gen_clamp01(1.0 - d / spread)
			p[y * size + x] = gen_coverage(f * f)
			x = x + 1
		y = y + 1
	return p


# ---- strikes ----------------------------------------------------------

# One baked glyph record (atlas rect + metrics, all in pixels).
struct gen_glyph:
	int x
	int y
	int w
	int h
	int advance
	int bearing_x
	int bearing_top


# Mild darkening of antialiased coverage so unhinted small text reads
# crisply on light backgrounds (255 and 0 stay fixed).
int gen_boost(int v):
	return v + ((255 - v) * v * 2) / 765


# Rasterize and place one strike; fills records[0..94] and the strike's
# ascent/descent (pixels) via out params.
void gen_bake_strike(gen_atlas* a, char* path, int ppem, gen_glyph* records, int* out_ascent, int* out_descent):
	ttf_font font
	if (ttf_load(&font, path) == 0):
		exit(1)
	out_ascent[0] = ttf_scale_round(&font, ppem, font.ascent)
	out_descent[0] = ttf_scale_round(&font, ppem, font.descent)

	gen_atlas_break(a)
	int ch = 32
	while (ch <= 126):
		int index = ch - 32
		ttf_bitmap bm
		if (ttf_rasterize(&font, ttf_glyph_id(&font, ch), ppem, &bm) == 0):
			print_error(c"generate_ui_atlas: glyph rasterization failed\n")
			exit(1)
		int i = 0
		while (i < bm.w * bm.h):
			bm.pixels[i] = gen_boost(bm.pixels[i] & 255)
			i = i + 1
		int x = 0
		int y = 0
		gen_atlas_place(a, bm.pixels, bm.w, bm.h, &x, &y)
		records[index].x = x
		records[index].y = y
		records[index].w = bm.w
		records[index].h = bm.h
		records[index].advance = bm.advance
		records[index].bearing_x = bm.bearing_x
		records[index].bearing_top = bm.bearing_top
		if (bm.pixels != 0):
			free(bm.pixels)
		ch = ch + 1
	free(font.data)


# ---- RLE --------------------------------------------------------------

# Zero/full runs of 3+ become 2-byte tokens; everything else joins a
# literal run (tag 2, count, raw bytes).
char* gen_rle_encode(char* pixels, int total, int* out_length):
	char* stream = malloc(total * 2 + 16)
	int pos = 0
	int i = 0
	while (i < total):
		int v = pixels[i] & 255
		int run = 1
		while ((i + run < total) && ((pixels[i + run] & 255) == v) && (run < 255)):
			run = run + 1
		if (((v == 0) || (v == 255)) && (run >= 3)):
			if (v == 0):
				stream[pos] = 0
			else:
				stream[pos] = 1
			stream[pos + 1] = run
			pos = pos + 2
			i = i + run
		else:
			# Literal run: until a 3+ run of 0/255 starts or 255 bytes.
			int start = i
			int n = 0
			int stop = 0
			while ((i < total) && (n < 255) && (stop == 0)):
				int b = pixels[i] & 255
				if ((b == 0) || (b == 255)):
					int ahead = 1
					while ((i + ahead < total) && ((pixels[i + ahead] & 255) == b) && (ahead < 3)):
						ahead = ahead + 1
					if (ahead >= 3):
						stop = 1
				if (stop == 0):
					i = i + 1
					n = n + 1
			stream[pos] = 2
			stream[pos + 1] = n
			pos = pos + 2
			int k = 0
			while (k < n):
				stream[pos + k] = pixels[start + k]
				k = k + 1
			pos = pos + n
	out_length[0] = pos
	return stream


# ---- emission ---------------------------------------------------------

# Append one byte as a \xHH escape.
void gen_append_escape(string_builder* out, int value):
	string_append_char(out, 92)
	string_append_char(out, 120)
	int hi = (value >> 4) & 15
	int lo = value & 15
	if (hi < 10):
		string_append_char(out, 48 + hi)
	else:
		string_append_char(out, 87 + hi)
	if (lo < 10):
		string_append_char(out, 48 + lo)
	else:
		string_append_char(out, 87 + lo)


void gen_emit_bytes_func(wstream* out, char* name, int suffix, char* bytes, int length):
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_cstr(out, c"char* ")
	stream_write_cstr(out, name)
	if (suffix >= 0):
		stream_write_int(out, suffix)
	stream_write_line(out, c"():")
	string_builder* literal = string_new()
	string_append(literal, c"\treturn c\"")
	int i = 0
	while (i < length):
		gen_append_escape(literal, bytes[i] & 255)
		i = i + 1
	string_append(literal, c"\"")
	stream_write_line(out, literal.data)
	string_free(literal)


void gen_emit_int_func(wstream* out, char* name, int value):
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_cstr(out, c"int ")
	stream_write_cstr(out, name)
	stream_write_line(out, c"():")
	stream_write_cstr(out, c"\treturn ")
	stream_write_int(out, value)
	stream_write_line(out, c"")


int gen_record_byte(int value):
	if ((value < 0) || (value > 255)):
		print_error(c"generate_ui_atlas: record field out of byte range: ")
		print_error(itoa(value))
		print_error(c"\n")
		exit(1)
	return value


# Pack one glyph/mask record into 9 bytes at p.
void gen_pack_record(char* p, gen_glyph* g):
	p[0] = gen_record_byte(g.x & 255)
	p[1] = gen_record_byte(g.x >> 8)
	p[2] = gen_record_byte(g.y & 255)
	p[3] = gen_record_byte(g.y >> 8)
	p[4] = gen_record_byte(g.w)
	p[5] = gen_record_byte(g.h)
	p[6] = gen_record_byte(g.advance)
	p[7] = gen_record_byte(g.bearing_x + 8)
	p[8] = gen_record_byte(g.bearing_top + 8)


int gen_glyphs_per_chunk():
	return 24


void gen_emit_strike_records(wstream* out, char* name_prefix, gen_glyph* records):
	char* packed = malloc(gen_char_count() * 9)
	int i = 0
	while (i < gen_char_count()):
		gen_pack_record(&packed[i * 9], &records[i])
		i = i + 1
	int chunk = 0
	while (chunk * gen_glyphs_per_chunk() < gen_char_count()):
		int first = chunk * gen_glyphs_per_chunk()
		int count = gen_char_count() - first
		if (count > gen_glyphs_per_chunk()):
			count = gen_glyphs_per_chunk()
		gen_emit_bytes_func(out, name_prefix, chunk, &packed[first * 9], count * 9)
		chunk = chunk + 1
	free(packed)


int main(int argc, int argv):
	gen_atlas a
	gen_atlas_init(&a)

	# Masks first, in id order (font.w's mask ids point into this).
	gen_glyph* masks = cast(gen_glyph*, malloc(gen_mask_count() * 7 * __word_size__))
	int* mask_sizes = cast(int*, malloc(gen_mask_count() * __word_size__))
	mask_sizes[0] = 8
	mask_sizes[1] = 32
	mask_sizes[2] = 32
	mask_sizes[3] = 40
	mask_sizes[4] = 30
	mask_sizes[5] = 24
	mask_sizes[6] = 48
	int m = 0
	while (m < gen_mask_count()):
		int size = mask_sizes[m]
		char* bitmap = 0
		if (m == 0):
			bitmap = gen_mask_white(size)
		else if (m == 1):
			bitmap = gen_mask_corner(size)
		else if (m == 2):
			bitmap = gen_mask_disc(size)
		else if (m == 3):
			bitmap = gen_mask_ring(size)
		else if (m == 4):
			bitmap = gen_mask_check(size)
		else if (m == 5):
			bitmap = gen_mask_chevron(size)
		else:
			bitmap = gen_mask_shadow(size)
		int x = 0
		int y = 0
		gen_atlas_place(&a, bitmap, size, size, &x, &y)
		free(bitmap)
		masks[m].x = x
		masks[m].y = y
		masks[m].w = size
		masks[m].h = size
		masks[m].advance = 0
		masks[m].bearing_x = 0
		masks[m].bearing_top = 0
		m = m + 1

	gen_glyph* body = cast(gen_glyph*, malloc(gen_char_count() * 7 * __word_size__))
	gen_glyph* title = cast(gen_glyph*, malloc(gen_char_count() * 7 * __word_size__))
	int body_ascent = 0
	int body_descent = 0
	int title_ascent = 0
	int title_descent = 0
	gen_bake_strike(&a, c"tools/ui/LiberationSans-Regular.ttf", 16, body, &body_ascent, &body_descent)
	gen_bake_strike(&a, c"tools/ui/LiberationSans-Bold.ttf", 20, title, &title_ascent, &title_descent)

	# Trim to the used height, rounded up to a multiple of 4.
	int atlas_h = (a.used_h + 3) / 4 * 4
	int total = a.w * atlas_h
	int rle_length = 0
	char* rle = gen_rle_encode(a.pixels, total, &rle_length)

	wstream* out = stream_open_write(c"graphics/ui/font_data.w")
	stream_write_line(out, c"# GENERATED by tools/generate_ui_atlas.w from the committed")
	stream_write_line(out, c"# tools/ui/LiberationSans-*.ttf faces (SIL OFL 1.1 — see")
	stream_write_line(out, c"# tools/ui/LiberationSans-LICENSE.txt) — do not edit by hand; run")
	stream_write_line(out, c"# ./wbuild ui_font_data to regenerate.")
	stream_write_line(out, c"#")
	stream_write_line(out, c"# One R8 atlas: masks 0..6 (white, corner, disc, ring, check,")
	stream_write_line(out, c"# chevron, shadow — graphics/ui/font.w documents the drawing), then")
	stream_write_line(out, c"# strike 0 = Liberation Sans Regular 16 ppem, strike 1 = Bold 20")
	stream_write_line(out, c"# ppem, ASCII 32..126. Pixels are run-length encoded (tag 0: zero")
	stream_write_line(out, c"# run, tag 1: 255 run, tag 2: literal run); records are 9-byte")
	stream_write_line(out, c"# entries x_lo, x_hi, y_lo, y_hi, w, h, advance, bearing_x+8,")
	stream_write_line(out, c"# bearing_top+8, decoded by graphics/ui/font.w.")
	gen_emit_int_func(out, c"ui_font_atlas_w", a.w)
	gen_emit_int_func(out, c"ui_font_atlas_h", atlas_h)
	gen_emit_int_func(out, c"ui_font_first_char", 32)
	gen_emit_int_func(out, c"ui_font_char_count", gen_char_count())
	gen_emit_int_func(out, c"ui_font_strike_count", 2)
	gen_emit_int_func(out, c"ui_font_rle_length", rle_length)

	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_line(out, c"# Ascent/descent in pixels per strike (0 = body, 1 = title).")
	stream_write_line(out, c"int ui_font_ascent(int strike):")
	stream_write_line(out, c"\tif (strike <= 0):")
	stream_write_cstr(out, c"\t\treturn ")
	stream_write_int(out, body_ascent)
	stream_write_line(out, c"")
	stream_write_cstr(out, c"\treturn ")
	stream_write_int(out, title_ascent)
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_line(out, c"int ui_font_descent(int strike):")
	stream_write_line(out, c"\tif (strike <= 0):")
	stream_write_cstr(out, c"\t\treturn ")
	stream_write_int(out, body_descent)
	stream_write_line(out, c"")
	stream_write_cstr(out, c"\treturn ")
	stream_write_int(out, title_descent)
	stream_write_line(out, c"")

	# Mask records: one 63-byte chunk.
	char* mask_packed = malloc(gen_mask_count() * 9)
	m = 0
	while (m < gen_mask_count()):
		gen_pack_record(&mask_packed[m * 9], &masks[m])
		m = m + 1
	gen_emit_bytes_func(out, c"ui_font_mask_records", 0 - 1, mask_packed, gen_mask_count() * 9)
	free(mask_packed)
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_line(out, c"# 9-byte record for mask id 0..6.")
	stream_write_line(out, c"char* ui_font_mask_record(int mask):")
	stream_write_line(out, c"\tif ((mask < 0) || (mask >= 7)):")
	stream_write_line(out, c"\t\tmask = 0")
	stream_write_line(out, c"\tchar* data = ui_font_mask_records()")
	stream_write_line(out, c"\treturn &data[mask * 9]")

	gen_emit_strike_records(out, c"ui_font_records_0_", body)
	gen_emit_strike_records(out, c"ui_font_records_1_", title)
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_line(out, c"# 9-byte record for a strike's character (32..126; others map to")
	stream_write_line(out, c"# space).")
	stream_write_line(out, c"char* ui_font_glyph_record(int strike, int ch):")
	stream_write_line(out, c"\tint index = ch - 32")
	stream_write_line(out, c"\tif ((index < 0) || (index >= 95)):")
	stream_write_line(out, c"\t\tindex = 0")
	stream_write_line(out, c"\tint chunk = index / 24")
	stream_write_line(out, c"\tint rest = index % 24")
	stream_write_line(out, c"\tchar* data = 0")
	stream_write_line(out, c"\tif (strike <= 0):")
	stream_write_line(out, c"\t\tif (chunk == 0):")
	stream_write_line(out, c"\t\t\tdata = ui_font_records_0_0()")
	stream_write_line(out, c"\t\telse if (chunk == 1):")
	stream_write_line(out, c"\t\t\tdata = ui_font_records_0_1()")
	stream_write_line(out, c"\t\telse if (chunk == 2):")
	stream_write_line(out, c"\t\t\tdata = ui_font_records_0_2()")
	stream_write_line(out, c"\t\telse:")
	stream_write_line(out, c"\t\t\tdata = ui_font_records_0_3()")
	stream_write_line(out, c"\telse:")
	stream_write_line(out, c"\t\tif (chunk == 0):")
	stream_write_line(out, c"\t\t\tdata = ui_font_records_1_0()")
	stream_write_line(out, c"\t\telse if (chunk == 1):")
	stream_write_line(out, c"\t\t\tdata = ui_font_records_1_1()")
	stream_write_line(out, c"\t\telse if (chunk == 2):")
	stream_write_line(out, c"\t\t\tdata = ui_font_records_1_2()")
	stream_write_line(out, c"\t\telse:")
	stream_write_line(out, c"\t\t\tdata = ui_font_records_1_3()")
	stream_write_line(out, c"\treturn &data[rest * 9]")

	# RLE chunks + dispatcher.
	int chunk_size = 256
	int chunk_count = (rle_length + chunk_size - 1) / chunk_size
	gen_emit_int_func(out, c"ui_font_rle_chunk_count", chunk_count)
	gen_emit_int_func(out, c"ui_font_rle_chunk_size", chunk_size)
	int c = 0
	while (c < chunk_count):
		int first = c * chunk_size
		int count = rle_length - first
		if (count > chunk_size):
			count = chunk_size
		gen_emit_bytes_func(out, c"ui_font_rle_chunk_", c, &rle[first], count)
		c = c + 1
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_line(out, c"char* ui_font_rle_chunk(int i):")
	c = 0
	while (c < chunk_count):
		if (c == 0):
			stream_write_cstr(out, c"\tif (i == ")
		else:
			stream_write_cstr(out, c"\telse if (i == ")
		stream_write_int(out, c)
		stream_write_line(out, c"):")
		stream_write_cstr(out, c"\t\treturn ui_font_rle_chunk_")
		stream_write_int(out, c)
		stream_write_line(out, c"()")
		c = c + 1
	stream_write_line(out, c"\treturn ui_font_rle_chunk_0()")
	stream_close(out)

	print(c"generated graphics/ui/font_data.w (atlas ")
	print(itoa(a.w))
	print(c"x")
	print(itoa(atlas_h))
	print(c", rle ")
	print(itoa(rle_length))
	println(c" bytes)")
	free(rle)
	free(a.pixels)
	free(cast(char*, body))
	free(cast(char*, title))
	return 0
