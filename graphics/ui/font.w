/*
graphics.ui.font: faces, strikes and the glyph atlas (issue #379).

A face is a TrueType font. Faces 0..3 are the embedded defaults
(Liberation Sans Regular, Bold, Italic, Bold Italic — subsets baked
into graphics/ui/font_data.w by ./wbuild ui_font_data, decoded the
first time they are used); ui_font_face_load_ttf adds more at run
time. A strike is a face at one pixel size (ppem): ui_font_strike
finds or creates one for any size from 4 to 200, which is how text
scales cleanly — every size is rasterized from the outlines, never
stretched. Strike 0 (Regular 16) and strike 1 (Bold 20) are the body
and title text the theme's text_scale token selects
(ui_font_strike_from_scale).

Glyphs are rasterized on demand, per strike and codepoint, into rows
of the one R8 atlas below its baked mask rows, and cached for the
process lifetime. A codepoint the strike's face lacks comes from the
first fallback face that has it (ui_font_add_fallback, then the
default Regular), else the face's .notdef box. Each new glyph bumps
ui_font_atlas_generation(); the renderer uploads the grown atlas
before it draws, so glyphs can appear mid-frame.

Text is UTF-8 (invalid bytes read as U+FFFD), measured with pair
kerning from the face's GPOS or kern table. Pure CPU code — the GL
upload lives in graphics.ui.render.
*/
import lib.lib
import lib.ttf
import lib.rle
import lib.mem
import libs.standard.crypto.base64
import graphics.ui.font_data
import lib.bytes


# Mask ids in atlas bake order.
int ui_mask_white():
	return 0


int ui_mask_corner():
	return 1


int ui_mask_disc():
	return 2


int ui_mask_ring():
	return 3


int ui_mask_check():
	return 4


int ui_mask_chevron():
	return 5


int ui_mask_shadow():
	return 6


# ui_render_mask mirrors but never rotates, so the 'v' chevron above
# cannot supply the right-pointing form a collapsed tree node needs.
# flip_x on this one gives the left-pointing form.
int ui_mask_chevron_right():
	return 7


int ui_mask_cross():
	return 8


# One glyph's (or mask's) atlas rect and pixel metrics. bearing_x is
# the pen-to-bitmap x offset; bearing_top is rows above the baseline
# (negative for below-baseline ink like '_'). face and gid name the
# outline it came from (a fallback face's, for a borrowed glyph), for
# kerning; masks carry face -1.
struct ui_glyph:
	int32 x
	int32 y
	int32 w
	int32 h
	int32 advance
	int32 bearing_x
	int32 bearing_top
	int32 face
	int32 gid


ui_glyph ui_font_decode(char* record):
	ui_glyph g
	g.x = load_le16(record)
	g.y = load_le16(record + 2)
	g.w = record[4] & 255
	g.h = record[5] & 255
	g.advance = record[6] & 255
	g.bearing_x = (record[7] & 255) - 8
	g.bearing_top = (record[8] & 255) - 8
	g.face = 0 - 1
	g.gid = 0
	return g


# ---- faces -----------------------------------------------------------

# The embedded defaults, in font_data order.
enum ui_font_default_face:
	UI_FACE_REGULAR = 0
	UI_FACE_BOLD = 1
	UI_FACE_ITALIC = 2
	UI_FACE_BOLD_ITALIC = 3


int ui_font_max_faces():
	return 32


int ui_font_max_fallbacks():
	return 8


# Strike ids share a 32-bit cache key with the codepoint (21 bits).
int ui_font_max_strikes():
	return 1000


int ui_font_min_ppem():
	return 4


int ui_font_max_ppem():
	return 200


# A face at one pixel size, with its line metrics in pixels (y-down
# from the baseline for the decoration lines, lib.ttf's conventions).
struct ui_strike:
	int32 face
	int32 ppem
	int32 italic        # the true-italic companion strike; -1 unresolved, -2 none
	int32 ascent
	int32 descent
	int32 underline_top
	int32 underline_thickness
	int32 strikeout_top
	int32 strikeout_thickness


struct ui_font_state:
	int ready
	# Faces: fonts[i] is 0 until a default face is first decoded.
	ttf_font*[32] fonts
	int32[32] italic_of   # a face's italic companion (itself when italic), -1 none
	int face_count
	int32[8] fallbacks
	int fallback_count
	# Strikes.
	ui_strike* strikes
	int strike_count
	int strike_cap
	# Glyph cache: open addressing from strike * 2^21 + codepoint to an
	# index into glyphs.
	ui_glyph* glyphs
	int glyph_count
	int glyph_cap
	int* keys           # -1 = empty slot
	int* slots
	int table_cap
	# Runtime atlas rows, ui_font_atlas_w() wide, directly below the
	# baked mask rows. They grow by doubling; the packer never reuses
	# space, so a glyph's rect stays valid for the process lifetime.
	char* pixels
	int rows            # rows in use
	int cap_rows        # rows allocated (the texture carries them all)
	int shelf_x         # packer: next free x on the current shelf
	int shelf_y         # packer: current shelf top, in runtime rows
	int shelf_h         # packer: current shelf height (tallest + 1)
	int generation
	int uv_rows         # the height UVs are normalized by (ui_font_uv_rows)
	char* baked         # decoded baked rows, cached


ui_font_state ui_font_st


int ui_font_init();


# The ttf_font of a face, decoding an embedded default on first use.
# Returns 0 for an unknown face.
ttf_font* ui_font_face_font(int face):
	ui_font_init()
	if ((face < 0) || (face >= ui_font_st.face_count)):
		return 0
	if (ui_font_st.fonts[face] != 0):
		return ui_font_st.fonts[face]
	if (face >= ui_font_face_count()):
		return 0
	int size = ui_font_face_size(face)
	char* data = malloc(size + 4)
	int chars = ui_font_face_chunk_chars()
	int n = 0
	int k = 0
	while (k < ui_font_face_chunk_count(face)):
		char* chunk = ui_font_face_chunk(face, k)
		int m = 0
		char* part = base64_decode(chunk, strlen(chunk), &m)
		if (n + m <= size):
			mem_copy(data + n, part, m)
		n = n + m
		free(part)
		k = k + 1
	ttf_font* font = cast(ttf_font*, malloc(sizeof(ttf_font)))
	if ((n != size) || (ttf_load_bytes(font, data, size) == 0)):
		print_error(c"graphics.ui.font: embedded face does not decode\n")
		exit(1)
	ui_font_st.fonts[face] = font
	return font


# Register an indexed font as a new face. Returns its id, or -1 when
# the face table is full.
int ui_font_face_add(ttf_font* font):
	ui_font_init()
	if (ui_font_st.face_count >= ui_font_max_faces()):
		print_error(c"graphics.ui.font: face limit reached\n")
		return 0 - 1
	int face = ui_font_st.face_count
	ui_font_st.fonts[face] = font
	ui_font_st.italic_of[face] = 0 - 1
	ui_font_st.face_count = face + 1
	return face


# Load a TrueType file as a new face (the bytes stay resident: glyphs
# rasterize on demand). Returns the face id, or -1 after printing why.
int ui_font_face_load_ttf(char* path):
	ttf_font* font = cast(ttf_font*, malloc(sizeof(ttf_font)))
	if (ttf_load(font, path) == 0):
		free(cast(char*, font))
		return 0 - 1
	int face = ui_font_face_add(font)
	if (face < 0):
		ttf_free(font)
		free(cast(char*, font))
	return face


# The same from font bytes in memory (hosts without a filesystem). The
# bytes are copied, so data is only read during the call.
int ui_font_face_load_bytes(char* data, int size):
	char* copy = malloc(size + 1)
	int i = 0
	while (i < size):
		copy[i] = data[i]
		i = i + 1
	ttf_font* font = cast(ttf_font*, malloc(sizeof(ttf_font)))
	if (ttf_load_bytes(font, copy, size) == 0):
		free(copy)
		free(cast(char*, font))
		return 0 - 1
	int face = ui_font_face_add(font)
	if (face < 0):
		ttf_free(font)
		free(cast(char*, font))
	return face


# Pair a face with its italic companion: UI_TEXT_ITALIC on a strike of
# face then draws italic_face at the same size instead of shearing.
# Pass the face itself to mark an italic face (no further lean).
void ui_font_face_set_italic(int face, int italic_face):
	ui_font_init()
	if ((face < 0) || (face >= ui_font_st.face_count)):
		return
	ui_font_st.italic_of[face] = italic_face
	# Existing strikes of face re-resolve their companion.
	int i = 0
	while (i < ui_font_st.strike_count):
		if (ui_font_st.strikes[i].face == face):
			ui_font_st.strikes[i].italic = 0 - 1
		i = i + 1


# Add a face to the fallback chain searched, in order, for codepoints a
# strike's own face lacks (say, a CJK face behind a Latin one). The
# default Regular is always tried last.
void ui_font_add_fallback(int face):
	ui_font_init()
	if ((face < 0) || (face >= ui_font_st.face_count) || (ui_font_st.fallback_count >= ui_font_max_fallbacks())):
		return
	ui_font_st.fallbacks[ui_font_st.fallback_count] = face
	ui_font_st.fallback_count = ui_font_st.fallback_count + 1


# ---- atlas rows ------------------------------------------------------

# Changes whenever a glyph is added; the renderer compares it with the
# generation it uploaded.
int ui_font_atlas_generation():
	return ui_font_st.generation


# Texture height: baked rows plus every allocated runtime row. It only
# changes when the runtime rows double.
int ui_font_atlas_rows():
	return ui_font_atlas_h() + ui_font_st.cap_rows


# The height texture v coordinates are normalized by. It lags
# ui_font_atlas_rows() until ui_font_uv_sync, so every vertex of one
# frame shares a denominator even when the atlas grows mid-frame (the
# renderer rescales the batch when it syncs).
int ui_font_uv_rows():
	if (ui_font_st.uv_rows == 0):
		ui_font_st.uv_rows = ui_font_atlas_rows()
	return ui_font_st.uv_rows


# Adopt the current atlas height for UVs. Returns the previous height.
int ui_font_uv_sync():
	int old = ui_font_uv_rows()
	ui_font_st.uv_rows = ui_font_atlas_rows()
	return old


# Make room for rows runtime rows (zero-filled). Returns 1, or 0 when
# the allocation fails.
int ui_font_rows_reserve(int rows):
	if (rows <= ui_font_st.cap_rows):
		return 1
	int next = ui_font_st.cap_rows * 2
	if (next < 256):
		next = 256
	while (next < rows):
		next = next * 2
	int w = ui_font_atlas_w()
	char* grown = malloc(next * w)
	if (grown == 0):
		return 0
	int i = 0
	while (i < ui_font_st.cap_rows * w):
		grown[i] = ui_font_st.pixels[i]
		i = i + 1
	while (i < next * w):
		grown[i] = 0
		i = i + 1
	if (ui_font_st.pixels != 0):
		free(ui_font_st.pixels)
	ui_font_st.pixels = grown
	ui_font_st.cap_rows = next
	return 1


# Shelf-pack a w x h coverage bitmap (1px gap, like the baker) into the
# runtime rows. Stores the atlas-space rect origin in x[0], y[0].
# Returns 1, or 0 when it cannot fit (wider than the atlas, or out of
# memory).
int ui_font_rows_place(char* bitmap, int w, int h, int* x, int* y):
	int atlas_w = ui_font_atlas_w()
	if (w + 2 > atlas_w):
		return 0
	if (ui_font_st.shelf_x + w + 1 > atlas_w):
		ui_font_st.shelf_y = ui_font_st.shelf_y + ui_font_st.shelf_h
		ui_font_st.shelf_x = 1
		ui_font_st.shelf_h = 0
	if (h + 1 > ui_font_st.shelf_h):
		ui_font_st.shelf_h = h + 1
	if (ui_font_rows_reserve(ui_font_st.shelf_y + ui_font_st.shelf_h + 1) == 0):
		return 0
	int top = ui_font_st.shelf_y + 1
	int row = 0
	while (row < h):
		int col = 0
		char* dst = &ui_font_st.pixels[(top + row) * atlas_w + ui_font_st.shelf_x]
		while (col < w):
			dst[col] = bitmap[row * w + col]
			col = col + 1
		row = row + 1
	x[0] = ui_font_st.shelf_x
	y[0] = ui_font_atlas_h() + top
	ui_font_st.shelf_x = ui_font_st.shelf_x + w + 1
	if (top + h + 1 > ui_font_st.rows):
		ui_font_st.rows = top + h + 1
	return 1


# ---- strikes ---------------------------------------------------------

# Find or create the strike of face at ppem. Returns its id, or -1 for
# an unknown face or a size outside 4..200 (after printing why).
int ui_font_strike(int face, int ppem):
	ui_font_init()
	if ((ppem < ui_font_min_ppem()) || (ppem > ui_font_max_ppem())):
		print_error(c"graphics.ui.font: ppem out of range (4..200)\n")
		return 0 - 1
	ttf_font* font = ui_font_face_font(face)
	if (font == 0):
		print_error(c"graphics.ui.font: unknown face\n")
		return 0 - 1
	int i = 0
	while (i < ui_font_st.strike_count):
		if ((ui_font_st.strikes[i].face == face) && (ui_font_st.strikes[i].ppem == ppem)):
			return i
		i = i + 1
	if (ui_font_st.strike_count >= ui_font_max_strikes()):
		print_error(c"graphics.ui.font: strike limit reached\n")
		return 0 - 1
	if (ui_font_st.strike_count >= ui_font_st.strike_cap):
		int next = ui_font_st.strike_cap * 2
		ui_font_st.strikes = cast(ui_strike*, realloc(cast(char*, ui_font_st.strikes), ui_font_st.strike_cap * sizeof(ui_strike), next * sizeof(ui_strike)))
		ui_font_st.strike_cap = next
	int id = ui_font_st.strike_count
	ui_strike* s = &ui_font_st.strikes[id]
	s.face = face
	s.ppem = ppem
	s.italic = 0 - 1
	s.ascent = ttf_scale_round(font, ppem, font.ascent)
	s.descent = ttf_scale_round(font, ppem, font.descent)
	s.underline_top = ttf_underline_top(font, ppem)
	s.underline_thickness = ttf_underline_thickness(font, ppem)
	s.strikeout_top = ttf_strikeout_top(font, ppem)
	s.strikeout_thickness = ttf_strikeout_thickness(font, ppem)
	ui_font_st.strike_count = id + 1
	return id


# Set up the default faces and the body/title strikes (0 and 1). Runs
# once, on first use of anything here.
int ui_font_init():
	if (ui_font_st.ready):
		return 1
	ui_font_st.ready = 1
	ui_font_st.face_count = ui_font_face_count()
	int i = 0
	while (i < ui_font_max_faces()):
		ui_font_st.fonts[i] = 0
		ui_font_st.italic_of[i] = 0 - 1
		i = i + 1
	ui_font_st.italic_of[UI_FACE_REGULAR] = UI_FACE_ITALIC
	ui_font_st.italic_of[UI_FACE_BOLD] = UI_FACE_BOLD_ITALIC
	ui_font_st.italic_of[UI_FACE_ITALIC] = UI_FACE_ITALIC
	ui_font_st.italic_of[UI_FACE_BOLD_ITALIC] = UI_FACE_BOLD_ITALIC
	ui_font_st.fallback_count = 0
	ui_font_st.strike_cap = 16
	ui_font_st.strikes = cast(ui_strike*, malloc(ui_font_st.strike_cap * sizeof(ui_strike)))
	ui_font_st.strike_count = 0
	ui_font_st.glyph_cap = 256
	ui_font_st.glyphs = cast(ui_glyph*, malloc(ui_font_st.glyph_cap * sizeof(ui_glyph)))
	ui_font_st.glyph_count = 0
	ui_font_st.table_cap = 512
	ui_font_st.keys = cast(int*, malloc(ui_font_st.table_cap * __word_size__))
	ui_font_st.slots = cast(int*, malloc(ui_font_st.table_cap * __word_size__))
	i = 0
	while (i < ui_font_st.table_cap):
		ui_font_st.keys[i] = 0 - 1
		i = i + 1
	ui_font_st.shelf_x = 1
	ui_font_st.shelf_y = 0
	ui_font_st.shelf_h = 0
	ui_font_strike(UI_FACE_REGULAR, 16)
	ui_font_strike(UI_FACE_BOLD, 20)
	return 1


# The default strikes: body text and titles.
int ui_font_strike_count():
	return 2


int ui_font_strike_total():
	ui_font_init()
	return ui_font_st.strike_count


# A valid strike id (unknown ids read as the body strike).
int ui_font_strike_valid(int strike):
	ui_font_init()
	if ((strike < 0) || (strike >= ui_font_st.strike_count)):
		return 0
	return strike


int ui_font_strike_face(int strike):
	int i = ui_font_strike_valid(strike)
	return ui_font_st.strikes[i].face


int ui_font_strike_ppem(int strike):
	int i = ui_font_strike_valid(strike)
	return ui_font_st.strikes[i].ppem


# The same face as strike at another size: text scaled cleanly to any
# size. Returns -1 when ppem is out of range.
int ui_font_strike_resized(int strike, int ppem):
	return ui_font_strike(ui_font_strike_face(strike), ppem)


# The true-italic companion of strike (the same size in its face's
# italic companion; strike itself for an italic face), or -1 when the
# face has none and italics must be sheared.
int ui_font_strike_italic(int strike):
	strike = ui_font_strike_valid(strike)
	ui_strike* s = &ui_font_st.strikes[strike]
	if (s.italic == 0 - 1):
		int face = ui_font_st.italic_of[s.face]
		int found = 0 - 2
		if (face == s.face):
			found = strike
		else if (face >= 0):
			found = ui_font_strike(face, s.ppem)
			if (found < 0):
				found = 0 - 2
		# ui_font_strike may have moved the array.
		ui_font_st.strikes[strike].italic = found
	int italic = ui_font_st.strikes[strike].italic
	if (italic < 0):
		return 0 - 1
	return italic


# The strike a theme's text_scale token selects: 1 and 2 the body
# strike, 3 and up the title strike, and ui_font_scale_of's encoding
# any strike at all.
int ui_font_strike_from_scale(int scale):
	if (scale >= 1000):
		return ui_font_strike_valid(scale - 1000)
	if (scale <= 2):
		return 0
	return 1


# The text_scale value that selects strike (see
# graphics.ui.text's ui_theme_use_strike).
int ui_font_scale_of(int strike):
	return 1000 + strike


int ui_font_strike_ascent(int strike):
	int i = ui_font_strike_valid(strike)
	return ui_font_st.strikes[i].ascent


int ui_font_strike_descent(int strike):
	int i = ui_font_strike_valid(strike)
	return ui_font_st.strikes[i].descent


int ui_font_ascent(int strike):
	return ui_font_strike_ascent(strike)


int ui_font_descent(int strike):
	return ui_font_strike_descent(strike)


# Decoration lines, y-down pixels from the baseline (lib.ttf's
# conventions): the top row of the line and its thickness.
int ui_font_underline_top(int strike):
	int i = ui_font_strike_valid(strike)
	return ui_font_st.strikes[i].underline_top


int ui_font_underline_thickness(int strike):
	int i = ui_font_strike_valid(strike)
	return ui_font_st.strikes[i].underline_thickness


int ui_font_strikeout_top(int strike):
	int i = ui_font_strike_valid(strike)
	return ui_font_st.strikes[i].strikeout_top


int ui_font_strikeout_thickness(int strike):
	int i = ui_font_strike_valid(strike)
	return ui_font_st.strikes[i].strikeout_thickness


# Load a TrueType file and return a strike of it at ppem (the face
# stays loaded: ui_font_strike_resized gives it at other sizes).
# Returns the strike id, or -1 after printing why.
int ui_font_load_ttf(char* path, int ppem):
	if ((ppem < ui_font_min_ppem()) || (ppem > ui_font_max_ppem())):
		print_error(c"graphics.ui.font: ppem out of range (4..200)\n")
		return 0 - 1
	int face = ui_font_face_load_ttf(path)
	if (face < 0):
		return 0 - 1
	return ui_font_strike(face, ppem)


# The same from font bytes in memory (data is only read during the
# call).
int ui_font_load_ttf_bytes(char* data, int size, int ppem):
	if ((ppem < ui_font_min_ppem()) || (ppem > ui_font_max_ppem())):
		print_error(c"graphics.ui.font: ppem out of range (4..200)\n")
		return 0 - 1
	int face = ui_font_face_load_bytes(data, size)
	if (face < 0):
		return 0 - 1
	return ui_font_strike(face, ppem)


# ---- glyph cache -----------------------------------------------------

int ui_font_hash(int key, int mask):
	return ((key * 31) ^ (key >> 9) ^ (key >> 17)) & mask


void ui_font_table_insert(int key, int slot):
	int mask = ui_font_st.table_cap - 1
	int h = ui_font_hash(key, mask)
	while (ui_font_st.keys[h] != 0 - 1):
		h = (h + 1) & mask
	ui_font_st.keys[h] = key
	ui_font_st.slots[h] = slot


# Double the hash table once it is half full (rehashing every entry).
void ui_font_table_grow():
	int old_cap = ui_font_st.table_cap
	int* old_keys = ui_font_st.keys
	int* old_slots = ui_font_st.slots
	ui_font_st.table_cap = old_cap * 2
	ui_font_st.keys = cast(int*, malloc(ui_font_st.table_cap * __word_size__))
	ui_font_st.slots = cast(int*, malloc(ui_font_st.table_cap * __word_size__))
	int i = 0
	while (i < ui_font_st.table_cap):
		ui_font_st.keys[i] = 0 - 1
		i = i + 1
	i = 0
	while (i < old_cap):
		if (old_keys[i] != 0 - 1):
			ui_font_table_insert(old_keys[i], old_slots[i])
		i = i + 1
	free(cast(char*, old_keys))
	free(cast(char*, old_slots))


# Codepoints drawn as nothing at all: C0/C1 controls and DEL.
int ui_font_is_control(int cp):
	return (cp < 32) || ((cp >= 127) && (cp < 160))


# The face that supplies cp for a strike of face: face itself, else
# the first fallback that maps it, else the default Regular, else face
# (whose .notdef box then marks the gap). gid[0] gets the glyph id.
int ui_font_resolve(int face, int cp, int* gid):
	gid[0] = ttf_glyph_id(ui_font_face_font(face), cp)
	if (gid[0] != 0):
		return face
	int i = 0
	while (i < ui_font_st.fallback_count):
		int f = ui_font_st.fallbacks[i]
		int g = ttf_glyph_id(ui_font_face_font(f), cp)
		if (g != 0):
			gid[0] = g
			return f
		i = i + 1
	if (face != UI_FACE_REGULAR):
		int r = ttf_glyph_id(ui_font_face_font(UI_FACE_REGULAR), cp)
		if (r != 0):
			gid[0] = r
			return UI_FACE_REGULAR
	return face


# Rasterize cp for strike and pack it into the atlas.
ui_glyph ui_font_make_glyph(int strike, int cp):
	ui_strike* s = &ui_font_st.strikes[strike]
	int ppem = s.ppem
	ui_glyph g
	g.x = 0
	g.y = 0
	g.w = 0
	g.h = 0
	g.advance = 0
	g.bearing_x = 0
	g.bearing_top = 0
	g.face = s.face
	g.gid = 0
	if (ui_font_is_control(cp)):
		return g
	int gid = 0
	int face = ui_font_resolve(s.face, cp, &gid)
	ttf_font* font = ui_font_face_font(face)
	g.face = face
	g.gid = gid
	ttf_bitmap bm
	if (ttf_rasterize(font, gid, ppem, &bm) == 0):
		# A malformed outline still advances, so text stays laid out.
		g.advance = ttf_scale_round(font, ppem, ttf_advance_units(font, gid))
		return g
	g.advance = bm.advance
	g.bearing_x = bm.bearing_x
	g.bearing_top = bm.bearing_top
	if (bm.pixels != 0):
		int k = 0
		while (k < bm.w * bm.h):
			bm.pixels[k] = ttf_boost_coverage(bm.pixels[k] & 255)
			k = k + 1
		int gx = 0
		int gy = 0
		if (ui_font_rows_place(bm.pixels, bm.w, bm.h, &gx, &gy)):
			g.x = gx
			g.y = gy
			g.w = bm.w
			g.h = bm.h
			ui_font_st.generation = ui_font_st.generation + 1
		free(bm.pixels)
	return g


# The glyph for codepoint cp in strike, rasterized on first use.
ui_glyph ui_font_glyph(int strike, int cp):
	strike = ui_font_strike_valid(strike)
	if ((cp < 0) || (cp > 1114111)):
		cp = 65533
	int key = strike * 2097152 + cp
	int mask = ui_font_st.table_cap - 1
	int h = ui_font_hash(key, mask)
	while (ui_font_st.keys[h] != 0 - 1):
		if (ui_font_st.keys[h] == key):
			return ui_font_st.glyphs[ui_font_st.slots[h]]
		h = (h + 1) & mask
	ui_glyph g = ui_font_make_glyph(strike, cp)
	if (ui_font_st.glyph_count >= ui_font_st.glyph_cap):
		int next = ui_font_st.glyph_cap * 2
		ui_font_st.glyphs = cast(ui_glyph*, realloc(cast(char*, ui_font_st.glyphs), ui_font_st.glyph_cap * sizeof(ui_glyph), next * sizeof(ui_glyph)))
		ui_font_st.glyph_cap = next
	int slot = ui_font_st.glyph_count
	ui_font_st.glyphs[slot] = g
	ui_font_st.glyph_count = slot + 1
	if (ui_font_st.glyph_count * 2 > ui_font_st.table_cap):
		ui_font_table_grow()
	ui_font_table_insert(key, slot)
	return g


# Pixels to add to the pen between two glyphs of strike (negative
# pulls them together): the face's pair kerning, rounded at the
# strike's size. Glyphs from different faces never kern.
int ui_font_kern(int strike, ui_glyph* left, ui_glyph* right):
	if ((left.face < 0) || (left.face != right.face) || (left.gid == 0) || (right.gid == 0)):
		return 0
	ttf_font* font = ui_font_face_font(left.face)
	int units = ttf_kern_units(font, left.gid, right.gid)
	if (units == 0):
		return 0
	return ttf_scale_round(font, ui_font_strike_ppem(strike), units)


ui_glyph ui_font_mask(int mask):
	return ui_font_decode(ui_font_mask_record(mask))


# The baked mask rows, expanded once from the RLE chunk stream
# (lib/rle.w).
char* ui_font_baked_pixels():
	if (ui_font_st.baked != 0):
		return ui_font_st.baked
	int rle_length = ui_font_rle_length()
	char* stream = malloc(rle_length)
	int chunk_size = ui_font_rle_chunk_size()
	int i = 0
	while (i < ui_font_rle_chunk_count()):
		char* chunk = ui_font_rle_chunk(i)
		int base = i * chunk_size
		int count = rle_length - base
		if (count > chunk_size):
			count = chunk_size
		int j = 0
		while (j < count):
			stream[base + j] = chunk[j]
			j = j + 1
		i = i + 1
	int total = ui_font_atlas_w() * ui_font_atlas_h()
	char* pixels = rle_decode(stream, rle_length, malloc(total), total)
	free(stream)
	ui_font_st.baked = pixels
	return pixels


# Build the atlas pixel buffer (ui_font_atlas_w x ui_font_atlas_rows
# coverage bytes): the baked mask rows, then every runtime row.
# Caller frees.
char* ui_font_build_atlas():
	ui_font_init()
	char* baked = ui_font_baked_pixels()
	int total = ui_font_atlas_w() * ui_font_atlas_h()
	int extra = ui_font_atlas_w() * ui_font_st.cap_rows
	char* pixels = malloc(total + extra + 1)
	int i = 0
	while (i < total):
		pixels[i] = baked[i]
		i = i + 1
	int e = 0
	while (e < extra):
		pixels[total + e] = ui_font_st.pixels[e]
		e = e + 1
	return pixels


# ---- UTF-8 measurement -----------------------------------------------

# Decode the codepoint starting at byte i of s into cp[0] and return
# the index just past it. Malformed or truncated sequences, overlongs
# and surrogates read as U+FFFD and consume one byte, so every byte
# offset still reaches the terminator.
int ui_utf8_next(char* s, int i, int* cp):
	int c = s[i] & 255
	if (c < 128):
		cp[0] = c
		return i + 1
	int need = 0
	int value = 0
	int min = 0
	if ((c >= 194) && (c <= 223)):
		need = 1
		value = c & 31
		min = 128
	else if ((c >= 224) && (c <= 239)):
		need = 2
		value = c & 15
		min = 2048
	else if ((c >= 240) && (c <= 244)):
		need = 3
		value = c & 7
		min = 65536
	else:
		cp[0] = 65533
		return i + 1
	int j = 1
	while (j <= need):
		int d = s[i + j] & 255
		if ((d < 128) || (d > 191)):
			cp[0] = 65533
			return i + 1
		value = (value << 6) | (d & 63)
		j = j + 1
	if ((value < min) || (value > 1114111) || ((value >= 55296) && (value <= 57343))):
		cp[0] = 65533
		return i + 1
	cp[0] = value
	return i + need + 1


# Encode cp as UTF-8 into out (room for 4 bytes). Returns the byte
# count; cp outside Unicode or a surrogate encodes U+FFFD.
int ui_utf8_encode(char* out, int cp):
	if ((cp < 0) || (cp > 1114111) || ((cp >= 55296) && (cp <= 57343))):
		cp = 65533
	if (cp < 128):
		out[0] = cp
		return 1
	if (cp < 2048):
		out[0] = 192 | (cp >> 6)
		out[1] = 128 | (cp & 63)
		return 2
	if (cp < 65536):
		out[0] = 224 | (cp >> 12)
		out[1] = 128 | ((cp >> 6) & 63)
		out[2] = 128 | (cp & 63)
		return 3
	out[0] = 240 | (cp >> 18)
	out[1] = 128 | ((cp >> 12) & 63)
	out[2] = 128 | ((cp >> 6) & 63)
	out[3] = 128 | (cp & 63)
	return 4


# A typed codepoint a text field should insert: printable ASCII or any
# non-control, non-surrogate codepoint past Latin-1's C1 block.
int ui_utf8_is_text(int cp):
	if ((cp >= 32) && (cp <= 126)):
		return 1
	return (cp >= 160) && (cp <= 1114111) && ((cp < 55296) || (cp > 57343))


# Byte index of the codepoint boundary before byte i (0 at the start):
# the caret's step left over one character.
int ui_utf8_prev(char* s, int i):
	if (i <= 0):
		return 0
	int j = i - 1
	# Back over continuation bytes, at most three.
	while ((j > 0) && (i - j < 4) && ((s[j] & 192) == 128)):
		j = j - 1
	# Only take the long step when it decodes to exactly this span.
	int cp = 0
	if (ui_utf8_next(s, j, &cp) == i):
		return j
	return i - 1


# Pixel width of the first limit bytes of s in strike (limit < 0: to
# the terminator), with kerning. A codepoint counts when it starts
# before limit.
int ui_text_width_strike_n(char* s, int limit, int strike):
	int width = 0
	int i = 0
	ui_glyph prev
	prev.face = 0 - 1
	while ((s[i] != 0) && ((limit < 0) || (i < limit))):
		int cp = 0
		i = ui_utf8_next(s, i, &cp)
		ui_glyph g = ui_font_glyph(strike, cp)
		width = width + ui_font_kern(strike, &prev, &g) + g.advance
		prev = g
	return width


# Proportional pixel width of a string in strike.
int ui_text_width_strike(char* s, int strike):
	return ui_text_width_strike_n(s, 0 - 1, strike)


# Proportional pixel width of a string at the strike text_scale
# selects.
int ui_text_width(char* s, int scale):
	return ui_text_width_strike(s, ui_font_strike_from_scale(scale))


# Line-box height (ascent + descent) of a strike.
int ui_text_height_strike(int strike):
	return ui_font_strike_ascent(strike) + ui_font_strike_descent(strike)


# Line-box height (ascent + descent) of the strike text_scale selects.
int ui_text_height(int scale):
	return ui_text_height_strike(ui_font_strike_from_scale(scale))


# Width of the first count bytes (caret positioning); count is a byte
# offset on a codepoint boundary.
int ui_text_prefix_width(char* s, int count, int scale):
	return ui_text_width_strike_n(s, count, ui_font_strike_from_scale(scale))


# Nearest codepoint boundary (a byte offset) to the pixel offset x_rel
# from the string's left edge in strike (caret placement from a click).
int ui_text_caret_from_x_strike(char* s, int strike, int x_rel):
	int acc = 0
	int i = 0
	ui_glyph prev
	prev.face = 0 - 1
	while (s[i] != 0):
		int cp = 0
		int next = ui_utf8_next(s, i, &cp)
		ui_glyph g = ui_font_glyph(strike, cp)
		acc = acc + ui_font_kern(strike, &prev, &g)
		if (x_rel < acc + g.advance / 2):
			return i
		acc = acc + g.advance
		prev = g
		i = next
	return i


int ui_text_caret_from_x(char* s, int scale, int x_rel):
	return ui_text_caret_from_x_strike(s, ui_font_strike_from_scale(scale), x_rel)


# Bytes of s (whole codepoints) whose glyphs fit in max_w pixels in
# strike: how much of a string a fixed-width field can show.
int ui_text_fit_strike(char* s, int strike, int max_w):
	int pen = 0
	int i = 0
	ui_glyph prev
	prev.face = 0 - 1
	while (s[i] != 0):
		int cp = 0
		int next = ui_utf8_next(s, i, &cp)
		ui_glyph g = ui_font_glyph(strike, cp)
		int end = pen + ui_font_kern(strike, &prev, &g) + g.advance
		if (end > max_w):
			return i
		pen = end
		prev = g
		i = next
	return i
