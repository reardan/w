# wbuild: target=ui_font_data tag=generated dep=wv2 input=tools/ui/ output=graphics/ui/font_data.w
# wbuild: step="bin/wv2 tools/generate_ui_atlas.w -o bin/generate_ui_atlas"
# wbuild: step="bin/generate_ui_atlas"
# Emits graphics/ui/font_data.w — the baked rows of the UI's one R8
# atlas plus the embedded default faces — from the committed
# Liberation Sans faces (tools/ui/*.ttf, SIL OFL 1.1) via lib/ttf.w
# (docs/projects/ui_framework_plan.md stage 4, issue #379).
#
# Baked atlas rows, packed on 256-wide shelves with a 1px gap:
#   masks 0..8  — 0 solid white (untextured fills), 1 rounded-corner
#                 quarter disc, 2 disc, 3 ring, 4 checkmark,
#                 5 chevron, 6 blurred shadow corner tile,
#                 7 right-pointing chevron, 8 cross
# Mask pixels are run-length encoded (tag 0: zero run, tag 1: 255 run,
# tag 2: literal run — lib/rle.w, decoded by graphics/ui/font.w) into c"\x.."
# byte-string chunk functions (the lib/sha256.w table idiom); mask
# records are 9-byte entries: x_lo, x_hi, y_lo, y_hi, w, h, advance,
# bearing_x+8, bearing_top+8.
#
# Faces 0..3 (Regular, Bold, Italic, Bold Italic) are ttf_subset
# outputs covering gen_face_ranges(), emitted as base64 chunks.
# graphics/ui/font.w decodes a face the first time a strike needs it
# and rasterizes glyphs into the atlas on demand, at any size — so
# text glyphs are no longer baked here.
#
# Run from the repo root: ./wbuild ui_font_data
import lib.lib
import lib.stream
import structures.string
import graphics.math
import lib.ttf
import lib.rle
import libs.standard.crypto.base64


const int gen_atlas_w = 256
const int gen_mask_count = 9


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
	a.w = gen_atlas_w
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
	if (h + 1 > a.shelf_h): a.shelf_h = h + 1
	if (a.y + a.shelf_h >= a.h_cap):
		print_error(c"generate_ui_atlas: atlas height cap exceeded\n")
		exit(1)
	for row in range(h):
		for col in range(w): a.pixels[(a.y + row) * a.w + a.x + col] = bitmap[row * w + col]
	out_x[0] = a.x
	out_y[0] = a.y
	a.x = a.x + w + 1
	if (a.y + a.shelf_h > a.used_h): a.used_h = a.y + a.shelf_h
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
	if (v < 0.0): return 0.0
	if (v > 1.0): return 1.0
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
	for i in range(size * size): p[i] = 255
	return p


# Quarter disc for rounded-rect corners: the arc's center sits at the
# tile's bottom-right corner, so the tile drawn at a rect's top-left
# corner (and UV-mirrored for the other three) rounds it off.
char* gen_mask_corner(int size):
	char* p = malloc(size * size)
	float32 s = cast(float32, size)
	int y = 0
	while (y < size):
		for x in range(size):
			float32 dx = s - (cast(float32, x) + 0.5)
			float32 dy = s - (cast(float32, y) + 0.5)
			float32 d = gfx_sqrt(dx * dx + dy * dy)
			p[y * size + x] = gen_coverage(s - d + 0.5)
		y = y + 1
	return p


char* gen_mask_disc(int size):
	char* p = malloc(size * size)
	float32 c = cast(float32, size) * 0.5
	float32 r = c - 0.5
	int y = 0
	while (y < size):
		for x in range(size):
			float32 dx = cast(float32, x) + 0.5 - c
			float32 dy = cast(float32, y) + 0.5 - c
			float32 d = gfx_sqrt(dx * dx + dy * dy)
			p[y * size + x] = gen_coverage(r - d + 0.5)
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
		for x in range(size):
			float32 dx = cast(float32, x) + 0.5 - c
			float32 dy = cast(float32, y) + 0.5 - c
			float32 d = gfx_sqrt(dx * dx + dy * dy) - r
			if (d < 0.0): d = 0.0 - d
			p[y * size + x] = gen_coverage(half_stroke - d + 0.5)
		y = y + 1
	return p


# Checkmark: two round-capped strokes in a 30px tile.
char* gen_mask_check(int size):
	char* p = malloc(size * size)
	float32 s = cast(float32, size) / 30.0
	int y = 0
	while (y < size):
		for x in range(size):
			float32 px = cast(float32, x) + 0.5
			float32 py = cast(float32, y) + 0.5
			float32 d1 = gen_capsule_dist(px, py, 7.0 * s, 16.0 * s, 13.0 * s, 22.0 * s)
			float32 d2 = gen_capsule_dist(px, py, 13.0 * s, 22.0 * s, 23.0 * s, 9.0 * s)
			float32 d = d1
			if (d2 < d): d = d2
			p[y * size + x] = gen_coverage(2.2 * s - d + 0.5)
		y = y + 1
	return p


# Chevron (dropdown marker): a 'v' of two round-capped strokes.
char* gen_mask_chevron(int size):
	char* p = malloc(size * size)
	float32 s = cast(float32, size) / 24.0
	int y = 0
	while (y < size):
		for x in range(size):
			float32 px = cast(float32, x) + 0.5
			float32 py = cast(float32, y) + 0.5
			float32 d1 = gen_capsule_dist(px, py, 5.0 * s, 9.0 * s, 12.0 * s, 16.0 * s)
			float32 d2 = gen_capsule_dist(px, py, 12.0 * s, 16.0 * s, 19.0 * s, 9.0 * s)
			float32 d = d1
			if (d2 < d): d = d2
			p[y * size + x] = gen_coverage(1.8 * s - d + 0.5)
		y = y + 1
	return p


# Chevron pointing right: the tree view's collapsed-node marker, and
# the one direction gen_mask_chevron cannot supply — ui_render_mask
# mirrors but never rotates, so a 'v' can be flipped to a '^' and no
# further. flip_x on this one gives the left-pointing form.
char* gen_mask_chevron_right(int size):
	char* p = malloc(size * size)
	float32 s = cast(float32, size) / 24.0
	int y = 0
	while (y < size):
		for x in range(size):
			float32 px = cast(float32, x) + 0.5
			float32 py = cast(float32, y) + 0.5
			float32 d1 = gen_capsule_dist(px, py, 9.0 * s, 5.0 * s, 16.0 * s, 12.0 * s)
			float32 d2 = gen_capsule_dist(px, py, 16.0 * s, 12.0 * s, 9.0 * s, 19.0 * s)
			float32 d = d1
			if (d2 < d): d = d2
			p[y * size + x] = gen_coverage(1.8 * s - d + 0.5)
		y = y + 1
	return p


# Cross: the tab strip's close affordance. Two round-capped diagonals
# across a 24px tile, the same stroke weight as the chevrons so the
# two read as one icon family.
char* gen_mask_cross(int size):
	char* p = malloc(size * size)
	float32 s = cast(float32, size) / 24.0
	int y = 0
	while (y < size):
		for x in range(size):
			float32 px = cast(float32, x) + 0.5
			float32 py = cast(float32, y) + 0.5
			float32 d1 = gen_capsule_dist(px, py, 7.0 * s, 7.0 * s, 17.0 * s, 17.0 * s)
			float32 d2 = gen_capsule_dist(px, py, 17.0 * s, 7.0 * s, 7.0 * s, 17.0 * s)
			float32 d = d1
			if (d2 < d): d = d2
			p[y * size + x] = gen_coverage(1.8 * s - d + 0.5)
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
		for x in range(size):
			float32 dx = corner - (cast(float32, x) + 0.5)
			float32 dy = corner - (cast(float32, y) + 0.5)
			if (dx < 0.0): dx = 0.0
			if (dy < 0.0): dy = 0.0
			float32 d = gfx_sqrt(dx * dx + dy * dy) - 8.0
			float32 f = gen_clamp01(1.0 - d / spread)
			p[y * size + x] = gen_coverage(f * f)
		y = y + 1
	return p


# ---- glyph/mask records -----------------------------------------------

# One baked mask record (atlas rect + metrics, all in pixels).
struct gen_glyph:
	int x
	int y
	int w
	int h
	int advance
	int bearing_x
	int bearing_top


# ---- emission ---------------------------------------------------------

# Append one byte as a \xHH escape.
void gen_append_escape(string_builder* out, int value):
	string_append_char(out, 92)
	string_append_char(out, 120)
	int hi = (value >> 4) & 15
	int lo = value & 15
	if (hi < 10): string_append_char(out, 48 + hi)
	else: string_append_char(out, 87 + hi)
	if (lo < 10): string_append_char(out, 48 + lo)
	else: string_append_char(out, 87 + lo)


void gen_emit_bytes_func(wstream* out, char* name, int suffix, char* bytes, int length):
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_cstr(out, c"char* ")
	stream_write_cstr(out, name)
	if (suffix >= 0): stream_write_int(out, suffix)
	stream_write_line(out, c"():")
	string_builder* literal = string_new()
	string_append(literal, c"\treturn c\"")
	for i in range(length): gen_append_escape(literal, bytes[i] & 255)
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


# ---- embedded faces --------------------------------------------------

# The codepoints the embedded faces keep, as inclusive ranges: ASCII,
# Latin-1 and Latin Extended-A, Greek and Coptic, basic Cyrillic, the
# common general punctuation (dashes, quotes, bullet, ellipsis, primes,
# guillemets), the euro and trade marks, and the four arrows.
const int gen_face_range_count = 10


int* gen_face_ranges():
	int* r = cast(int*, malloc(gen_face_range_count * 2 * __word_size__))
	r[0] = 32
	r[1] = 126
	r[2] = 160
	r[3] = 383
	r[4] = 880
	r[5] = 1023
	r[6] = 1024
	r[7] = 1119
	r[8] = 8208
	r[9] = 8231
	r[10] = 8240
	r[11] = 8250
	r[12] = 8364
	r[13] = 8364
	r[14] = 8482
	r[15] = 8482
	r[16] = 8592
	r[17] = 8597
	r[18] = 65533
	r[19] = 65533
	return r


# base64 characters per emitted string literal (a multiple of 4, so
# every chunk decodes on its own).
const int gen_face_chunk_chars = 4096


# Subset one committed face and emit it as base64 chunk functions
# ui_font_face_<face>_<k>(). Returns the chunk count; the decoded
# byte length lands in out_size[0].
int gen_emit_face(wstream* out, int face, char* path, int* out_size):
	ttf_font font
	if (ttf_load(&font, path) == 0): exit(1)
	int size = 0
	char* data = ttf_subset(&font, gen_face_ranges(), gen_face_range_count, &size)
	if (data == 0): exit(1)
	ttf_font check
	if (ttf_load_bytes(&check, data, size) == 0):
		print_error(c"generate_ui_atlas: subset does not load\n")
		exit(1)
	char* text = base64_encode(data, size)
	int text_length = base64_encoded_length(size)
	int chunk_chars = gen_face_chunk_chars
	int chunks = (text_length + chunk_chars - 1) / chunk_chars
	for k in range(chunks):
		int first = k * chunk_chars
		int count = text_length - first
		if (count > chunk_chars): count = chunk_chars
		stream_write_line(out, c"")
		stream_write_line(out, c"")
		stream_write_cstr(out, c"char* ui_font_face_")
		stream_write_int(out, face)
		stream_write_cstr(out, c"_")
		stream_write_int(out, k)
		stream_write_line(out, c"():")
		stream_write_cstr(out, c"\treturn c\"")
		stream_write(out, &text[first], count)
		stream_write_line(out, c"\"")
	out_size[0] = size
	free(text)
	free(data)
	ttf_free(&font)
	return chunks


# An int function of one argument answering from a table of four.
void gen_emit_face_table(wstream* out, char* name, int* values):
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_cstr(out, c"int ")
	stream_write_cstr(out, name)
	stream_write_line(out, c"(int face):")
	for f in range(3):
		stream_write_cstr(out, c"\tif (face == ")
		stream_write_int(out, f)
		stream_write_line(out, c"):")
		stream_write_cstr(out, c"\t\treturn ")
		stream_write_int(out, values[f])
		stream_write_line(out, c"")
	stream_write_cstr(out, c"\treturn ")
	stream_write_int(out, values[3])
	stream_write_line(out, c"")


int main(int argc, int argv):
	gen_atlas a
	gen_atlas_init(&a)

	# Masks first, in id order (font.w's mask ids point into this).
	gen_glyph* masks = cast(gen_glyph*, malloc(gen_mask_count * 7 * __word_size__))
	int* mask_sizes = cast(int*, malloc(gen_mask_count * __word_size__))
	mask_sizes[0] = 8
	mask_sizes[1] = 32
	mask_sizes[2] = 32
	mask_sizes[3] = 40
	mask_sizes[4] = 30
	mask_sizes[5] = 24
	mask_sizes[6] = 48
	mask_sizes[7] = 24
	mask_sizes[8] = 24
	int m = 0
	while (m < gen_mask_count):
		int size = mask_sizes[m]
		char* bitmap = 0
		if (m == 0): bitmap = gen_mask_white(size)
		else if (m == 1): bitmap = gen_mask_corner(size)
		else if (m == 2): bitmap = gen_mask_disc(size)
		else if (m == 3): bitmap = gen_mask_ring(size)
		else if (m == 4): bitmap = gen_mask_check(size)
		else if (m == 5): bitmap = gen_mask_chevron(size)
		else if (m == 6): bitmap = gen_mask_shadow(size)
		else if (m == 7): bitmap = gen_mask_chevron_right(size)
		else: bitmap = gen_mask_cross(size)
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

	# Trim to the used height, rounded up to a multiple of 4.
	int atlas_h = (a.used_h + 3) / 4 * 4
	int total = a.w * atlas_h
	int rle_length = 0
	char* rle = rle_encode(a.pixels, total, &rle_length)

	wstream* out = stream_open_write(c"graphics/ui/font_data.w")
	stream_write_line(out, c"# GENERATED by tools/generate_ui_atlas.w from the committed")
	stream_write_line(out, c"# tools/ui/LiberationSans-*.ttf faces (SIL OFL 1.1 — see")
	stream_write_line(out, c"# tools/ui/LiberationSans-LICENSE.txt) — a build output, never")
	stream_write_line(out, c"# committed: any ./wbuild run regenerates it (issue #323).")
	stream_write_line(out, c"#")
	stream_write_line(out, c"# Two things: the R8 atlas's baked rows, holding masks 0..8")
	stream_write_line(out, c"# (white, corner, disc, ring, check, chevron, shadow,")
	stream_write_line(out, c"# chevron_right, cross — graphics/ui/font.w documents the")
	stream_write_line(out, c"# drawing), run-length encoded (tag 0: zero run, tag 1: 255 run,")
	stream_write_line(out, c"# tag 2: literal run) with 9-byte records x_lo, x_hi, y_lo, y_hi,")
	stream_write_line(out, c"# w, h, advance, bearing_x+8, bearing_top+8; and the four default")
	stream_write_line(out, c"# faces (0 Regular, 1 Bold, 2 Italic, 3 Bold Italic), each a")
	stream_write_line(out, c"# lib.ttf subset (Latin, Greek, Cyrillic, common punctuation;")
	stream_write_line(out, c"# no hinting; kerning as a format-0 kern table) in base64 chunks.")
	stream_write_line(out, c"# Glyphs are rasterized from those faces at run time, at any size.")
	gen_emit_int_func(out, c"ui_font_atlas_w", a.w)
	gen_emit_int_func(out, c"ui_font_atlas_h", atlas_h)
	gen_emit_int_func(out, c"ui_font_rle_length", rle_length)

	# Mask records: one 63-byte chunk.
	char* mask_packed = malloc(gen_mask_count * 9)
	m = 0
	while (m < gen_mask_count):
		gen_pack_record(&mask_packed[m * 9], &masks[m])
		m = m + 1
	gen_emit_bytes_func(out, c"ui_font_mask_records", 0 - 1, mask_packed, gen_mask_count * 9)
	free(mask_packed)
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	# Bound and comment both come from gen_mask_count(), so adding a mask
	# cannot leave a stale clamp behind that silently maps it to 0.
	stream_write_cstr(out, c"# 9-byte record for mask id 0..")
	stream_write_int(out, gen_mask_count - 1)
	stream_write_line(out, c".")
	stream_write_line(out, c"char* ui_font_mask_record(int mask):")
	stream_write_cstr(out, c"\tif ((mask < 0) || (mask >= ")
	stream_write_int(out, gen_mask_count)
	stream_write_line(out, c")):")
	stream_write_line(out, c"\t\tmask = 0")
	stream_write_line(out, c"\tchar* data = ui_font_mask_records()")
	stream_write_line(out, c"\treturn &data[mask * 9]")

	# RLE chunks + dispatcher.
	int chunk_size = 256
	int chunk_count = (rle_length + chunk_size - 1) / chunk_size
	gen_emit_int_func(out, c"ui_font_rle_chunk_count", chunk_count)
	gen_emit_int_func(out, c"ui_font_rle_chunk_size", chunk_size)
	int c = 0
	while (c < chunk_count):
		int first = c * chunk_size
		int count = rle_length - first
		if (count > chunk_size): count = chunk_size
		gen_emit_bytes_func(out, c"ui_font_rle_chunk_", c, &rle[first], count)
		c = c + 1
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_line(out, c"char* ui_font_rle_chunk(int i):")
	c = 0
	while (c < chunk_count):
		if (c == 0): stream_write_cstr(out, c"\tif (i == ")
		else: stream_write_cstr(out, c"\telse if (i == ")
		stream_write_int(out, c)
		stream_write_line(out, c"):")
		stream_write_cstr(out, c"\t\treturn ui_font_rle_chunk_")
		stream_write_int(out, c)
		stream_write_line(out, c"()")
		c = c + 1
	stream_write_line(out, c"\treturn ui_font_rle_chunk_0()")

	# The default faces, then their size/chunk tables and the chunk
	# dispatcher.
	char*[4] paths
	paths[0] = c"tools/ui/LiberationSans-Regular.ttf"
	paths[1] = c"tools/ui/LiberationSans-Bold.ttf"
	paths[2] = c"tools/ui/LiberationSans-Italic.ttf"
	paths[3] = c"tools/ui/LiberationSans-BoldItalic.ttf"
	int* face_sizes = cast(int*, malloc(4 * __word_size__))
	int* face_chunks = cast(int*, malloc(4 * __word_size__))
	int face = 0
	int face_total = 0
	while (face < 4):
		face_chunks[face] = gen_emit_face(out, face, paths[face], &face_sizes[face])
		face_total = face_total + face_sizes[face]
		face = face + 1
	gen_emit_int_func(out, c"ui_font_face_count", 4)
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_line(out, c"# Decoded byte length of a default face.")
	gen_emit_face_table(out, c"ui_font_face_size", face_sizes)
	gen_emit_face_table(out, c"ui_font_face_chunk_count", face_chunks)
	gen_emit_int_func(out, c"ui_font_face_chunk_chars", gen_face_chunk_chars)
	stream_write_line(out, c"")
	stream_write_line(out, c"")
	stream_write_line(out, c"# Base64 chunk k of a default face.")
	stream_write_line(out, c"char* ui_font_face_chunk(int face, int k):")
	face = 0
	while (face < 4):
		int k = 0
		while (k < face_chunks[face]):
			stream_write_cstr(out, c"\tif ((face == ")
			stream_write_int(out, face)
			stream_write_cstr(out, c") && (k == ")
			stream_write_int(out, k)
			stream_write_line(out, c")):")
			stream_write_cstr(out, c"\t\treturn ui_font_face_")
			stream_write_int(out, face)
			stream_write_cstr(out, c"_")
			stream_write_int(out, k)
			stream_write_line(out, c"()")
			k = k + 1
		face = face + 1
	stream_write_line(out, c"\treturn c\"\"")
	stream_close(out)

	print(c"generated graphics/ui/font_data.w (atlas ")
	print(itoa(a.w))
	print(c"x")
	print(itoa(atlas_h))
	print(c", rle ")
	print(itoa(rle_length))
	print(c" bytes, faces ")
	print(itoa(face_total))
	println(c" bytes)")
	free(rle)
	free(a.pixels)
	return 0
