# Paragraph itemization: one UTF-8 paragraph into shaped runs of one bidi
# level, script and face each, in visual order, with paragraph-wide carets
# and drawing. Pure W (the portable bidi and shaping engines), so it runs
# on every target. See docs/projects/text_shaping.md (issue #459).
#
#	ui_paragraph* p = ui_paragraph_shape(text, length, strike, UI_SHAPE_AUTO)
#	if (p.status == UI_SHAPE_OK): ui_paragraph_draw(renderer, x, y, p, color)
#	ui_paragraph_free(p)
#
# Bidi levels come from graphics.ui.bidi_portable (UAX #9, unwrapped).
# Scripts resolve the way HarfBuzz and ICU itemize (UAX #24 practice):
# Common, Inherited and Unknown characters take the script before them, a
# leading run of them takes the first real script after it, and a closing
# paired bracket takes the script of its opener (which is then restored).
# Faces follow the UI fallback chain at grapheme granularity: a grapheme
# keeps the previous grapheme's face when that face covers all of it, else
# takes the first of the strike's face, the fallbacks (ui_font_add_fallback)
# and the default Regular that covers it, else the face supplying its base
# character in codepoint text. Default-ignorable and control characters
# count as covered, and a combining mark therefore stays in its base's face
# whenever that face has the mark. Each face shapes at the strike's ppem.
import lib.lib
import lib.utf8
import lib.unicode_text
import graphics.ui.bidi_portable
import graphics.ui.shape_ot

const int UI_PARAGRAPH_MAX_BYTES = 65536

# One shaped run. Byte ranges name the paragraph's text; the run's own
# glyph clusters are relative to byte_start.
struct ui_text_item:
	int byte_start
	int byte_length
	int level
	int script            # lib.unicode_text script id; -1 for only shared characters
	int face
	int strike
	int x                 # 26.6 pixels from the paragraph's left edge
	ui_shaped_run* run

struct ui_paragraph:
	int status            # UI_SHAPE_OK, _INVALID, _LIMIT or _FAILED
	int direction         # the paragraph's resolved UI_SHAPE_LTR or _RTL
	int source_bytes
	int strike
	int item_count
	ui_text_item* items   # logical order
	int32* visual_items   # item indices, left to right
	int advance           # total width, 26.6 pixels
	int ascent            # line ascent in pixels: the tallest item strike
	int descent

void ui_paragraph_free(ui_paragraph* p):
	if (p == 0): return
	for i in range(p.item_count): ui_shaped_run_free(p.items[i].run)
	free(p.items)
	free(p.visual_items)
	free(p)

# Whether face has a glyph for every character of text[start, end) that
# draws: controls and default-ignorable characters always count.
int __ui_item_covers(int face, char* text, int start, int end):
	ttf_font* font = ui_font_face_font(face)
	if (font == 0): return 0
	int at = start
	while (at < end):
		int cp = 0
		at = at + utf8_scan(text + at, end - at, &cp)
		if (ui_font_is_control(cp) || ut_default_ignorable(cp)): continue
		if (ttf_glyph_id(font, cp) == 0): return 0
	return 1

# The face for the grapheme text[start, end) in a strike of base_face,
# preferring previous (-1 for none); see the header comment.
int __ui_item_face(int base_face, int previous, char* text, int start, int end):
	if ((previous >= 0) && __ui_item_covers(previous, text, start, end)): return previous
	if (__ui_item_covers(base_face, text, start, end)): return base_face
	for i in range(ui_font_st.fallback_count):
		int f = ui_font_st.fallbacks[i]
		if (__ui_item_covers(f, text, start, end)): return f
	if (__ui_item_covers(UI_FACE_REGULAR, text, start, end)): return UI_FACE_REGULAR
	int cp = 0
	utf8_scan(text + start, end - start, &cp)
	int gid = 0
	return ui_font_resolve(base_face, cp, &gid)

# Per-scalar script ids (scripts[i] for the scalar at byte_offsets[i]),
# resolved as described in the header comment.
void __ui_item_scripts(char* text, int* byte_offsets, int count, int32* scripts):
	int32* stack_closer = cast(int32*, malloc(64 * 4))
	int32* stack_index = cast(int32*, malloc(64 * 4))
	int depth = 0
	int current = -1
	int pending = 0       # leading shared scalars still without a script
	for i in range(count):
		int cp = 0
		utf8_scan(text + byte_offsets[i], byte_offsets[i + 1] - byte_offsets[i], &cp)
		int sc = ut_script(cp)
		if (!ut_script_is_shared(sc)):
			if (current < 0):
				for k in range(pending): scripts[k] = sc
			current = sc
			scripts[i] = sc
			continue
		int partner = 0
		int kind = ut_bracket(cp, &partner)
		if (kind == 1):
			if (depth < 64):
				stack_closer[depth] = ut_bracket_canonical(partner)
				stack_index[depth] = i
				depth = depth + 1
		else if (kind == 2):
			int want = ut_bracket_canonical(cp)
			int d = depth - 1
			while ((d >= 0) && (stack_closer[d] != want)): d = d - 1
			if (d >= 0):
				depth = d
				# The opener's script, once resolved, also resumes after it.
				if (scripts[stack_index[d]] >= 0): current = scripts[stack_index[d]]
		scripts[i] = current
		if (current < 0): pending = i + 1
	free(stack_closer)
	free(stack_index)

# The ISO 15924 tag of a script id packed big-endian, or 0 (guess).
int __ui_item_script_tag(int script):
	if (script < 0): return 0
	char* code = ut_script_code(script)
	return ((code[0] & 255) << 24) | ((code[1] & 255) << 16) | ((code[2] & 255) << 8) | (code[3] & 255)

void __ui_item_add(ui_paragraph* p, int start, int end, int level, int script, int face):
	ui_text_item* item = &p.items[p.item_count]
	item.byte_start = start
	item.byte_length = end - start
	item.level = level
	item.script = script
	item.face = face
	item.strike = 0 - 1
	item.x = 0
	item.run = cast(ui_shaped_run*, 0)
	p.item_count = p.item_count + 1

# Split one bidi run text[start, end) at script and face changes.
void __ui_item_split(ui_paragraph* p, char* text, int length, int start, int end, int level, int* byte_offsets, int count, int32* scripts, int scalar_start, int* face_state):
	int base_face = ui_font_st.strikes[p.strike].face
	int item_start = start
	int item_script = -2
	int item_face = -1
	int scalar = scalar_start
	int at = start
	while (at < end):
		int next = ui_grapheme_next_n(text, length, at)
		if ((next <= at) || (next > end)): next = end
		int script = scripts[scalar]
		int face = __ui_item_face(base_face, face_state[0], text, at, next)
		face_state[0] = face
		if ((item_script != -2) && ((script != item_script) || (face != item_face))):
			__ui_item_add(p, item_start, at, level, item_script, item_face)
			item_start = at
		item_script = script
		item_face = face
		while ((scalar < count) && (byte_offsets[scalar] < next)): scalar = scalar + 1
		at = next
	if (end > item_start): __ui_item_add(p, item_start, end, level, item_script, item_face)

# Shape text[0, length) as a paragraph for strike, whose face leads the
# fallback chain. direction is UI_SHAPE_AUTO, _LTR or _RTL. Always returns
# an owned paragraph; check status. At most 65536 bytes.
ui_paragraph* ui_paragraph_shape(char* text, int length, int strike, int direction):
	ui_paragraph* p = new ui_paragraph()
	p.status = UI_SHAPE_INVALID
	p.direction = UI_SHAPE_LTR
	ui_font_init()
	if ((length < 0) || ((text == 0) && (length > 0))): return p
	if ((strike < 0) || (strike >= ui_font_st.strike_count)): return p
	if ((direction != UI_SHAPE_AUTO) && (direction != UI_SHAPE_LTR) && (direction != UI_SHAPE_RTL)): return p
	if (length > UI_PARAGRAPH_MAX_BYTES):
		p.status = UI_SHAPE_LIMIT
		return p
	if (!utf8_validate_bytes(text, length)): return p
	p.strike = strike
	p.source_bytes = length
	int bidi_direction = UI_BIDI_AUTO
	if (direction == UI_SHAPE_LTR): bidi_direction = UI_BIDI_LTR
	if (direction == UI_SHAPE_RTL): bidi_direction = UI_BIDI_RTL
	ui_bidi_paragraph* bidi = ui_bidi_portable_utf8(text, length, bidi_direction, UI_PARAGRAPH_MAX_BYTES)
	if (bidi.status != UI_BIDI_OK):
		p.status = UI_SHAPE_FAILED
		ui_bidi_paragraph_free(bidi)
		return p
	if (bidi.direction == UI_BIDI_RTL): p.direction = UI_SHAPE_RTL
	int count = bidi.count
	int32* scripts = cast(int32*, malloc(count * 4 + 4))
	__ui_item_scripts(text, bidi.byte_offsets, count, scripts)
	# At most one item per grapheme, so count bounds the item array.
	p.items = cast(ui_text_item*, __w_alloc(__w_size_mul(count + 1, sizeof(ui_text_item))))
	p.visual_items = cast(int32*, malloc(count * 4 + 4))
	int32* first_item = cast(int32*, malloc(bidi.run_count * 4 + 4))
	int32* item_end = cast(int32*, malloc(bidi.run_count * 4 + 4))
	int face_state = -1
	for r in range(bidi.run_count):
		ui_bidi_run* run = &bidi.runs[r]
		first_item[r] = p.item_count
		__ui_item_split(p, text, length, run.byte_start, run.byte_start + run.byte_length, run.level, bidi.byte_offsets, count, scripts, run.scalar_start, &face_state)
		item_end[r] = p.item_count
	# Visual order: bidi runs as UAX #9 orders them; the items inside a
	# right-to-left run reversed.
	int v = 0
	for k in range(bidi.run_count):
		int r = bidi.visual_runs[k]
		if (bidi.runs[r].level & 1):
			int i = item_end[r] - 1
			while (i >= first_item[r]):
				p.visual_items[v] = i
				v = v + 1
				i = i - 1
		else:
			for i in range(first_item[r], item_end[r]):
				p.visual_items[v] = i
				v = v + 1
	free(first_item)
	free(item_end)
	free(scripts)
	ui_bidi_paragraph_free(bidi)
	int ppem = ui_font_st.strikes[strike].ppem
	p.ascent = ui_font_strike_ascent(strike)
	p.descent = ui_font_strike_descent(strike)
	for i in range(p.item_count):
		ui_text_item* item = &p.items[i]
		item.strike = ui_font_strike_sibling(strike, item.face, ppem)
		if (item.strike < 0):
			p.status = UI_SHAPE_FAILED
			return p
		int item_direction = UI_SHAPE_LTR
		if (item.level & 1): item_direction = UI_SHAPE_RTL
		item.run = ui_shape_portable_utf8(text + item.byte_start, item.byte_length, item.strike, item_direction, __ui_item_script_tag(item.script), 0, 1048576)
		if (item.run.status != UI_SHAPE_OK):
			p.status = item.run.status
			return p
		if (ui_font_strike_ascent(item.strike) > p.ascent): p.ascent = ui_font_strike_ascent(item.strike)
		if (ui_font_strike_descent(item.strike) > p.descent): p.descent = ui_font_strike_descent(item.strike)
	int pen = 0
	for k in range(p.item_count):
		ui_text_item* item = &p.items[p.visual_items[k]]
		item.x = pen
		pen = pen + item.run.advance
	p.advance = pen
	p.status = UI_SHAPE_OK
	return p

# Caret x (26.6 pixels from the paragraph's left edge) for a byte offset in
# the text p was shaped from. An offset at an item boundary belongs to the
# item that starts there (the character after the caret); the end of the
# text takes the logical end of the last item.
int ui_paragraph_caret_x(ui_paragraph* p, char* text, int offset):
	if ((p == 0) || (p.status != UI_SHAPE_OK) || (p.item_count == 0)): return 0
	if (offset < 0): offset = 0
	for i in range(p.item_count):
		ui_text_item* item = &p.items[i]
		if ((offset >= item.byte_start) && (offset < item.byte_start + item.byte_length)):
			return item.x + ui_shaped_caret_x(item.run, text + item.byte_start, offset - item.byte_start)
	ui_text_item* last = &p.items[p.item_count - 1]
	return last.x + ui_shaped_caret_x(last.run, text + last.byte_start, last.byte_length)

# The grapheme boundary whose caret is nearest x (26.6 pixels).
int ui_paragraph_offset_from_x(ui_paragraph* p, char* text, int x):
	if ((p == 0) || (p.status != UI_SHAPE_OK)): return 0
	int best = 0
	int best_distance = -1
	int at = 0
	while (1):
		int distance = ui_paragraph_caret_x(p, text, at) - x
		if (distance < 0): distance = 0 - distance
		if ((best_distance < 0) || (distance < best_distance)):
			best = at
			best_distance = distance
		if (at >= p.source_bytes): break
		int next = ui_grapheme_next_n(text, p.source_bytes, at)
		if (next <= at): next = at + 1
		at = next
	return best

# Draw at the line box's top-left x,y. Items of other faces share the
# paragraph's baseline (p.ascent below y).
int ui_paragraph_draw(ui_renderer* renderer, float32 x, float32 y, ui_paragraph* p, ui_color color):
	if ((p == 0) || (p.status != UI_SHAPE_OK)): return 0
	for k in range(p.item_count):
		ui_text_item* item = &p.items[p.visual_items[k]]
		float32 drop = cast(float32, p.ascent - ui_font_strike_ascent(item.strike))
		ui_draw_shaped_run(renderer, x + cast(float32, item.x) / 64.0, y + drop, item.run, color)
	return 1

# Width-fit helper for simple wrapping: the largest byte offset k at a
# space break (just after a space, or the end of the text) whose logical
# prefix [0, k) is at most max_width (26.6 pixels) wide, measured from the
# shaped glyphs without reshaping. When even the first break is wider, the
# first break, so a caller always advances. Spaces only: this is not
# UAX #14 line breaking.
int ui_paragraph_fit(ui_paragraph* p, char* text, int max_width):
	if ((p == 0) || (p.status != UI_SHAPE_OK) || (p.source_bytes == 0)): return 0
	int first = -1
	int best = -1
	int k = 1
	while (k <= p.source_bytes):
		if ((k == p.source_bytes) || (text[k - 1] == ' ')):
			int width = 0
			for i in range(p.item_count):
				ui_text_item* item = &p.items[i]
				for g in range(item.run.count):
					if (item.byte_start + item.run.glyphs[g].cluster < k): width = width + item.run.glyphs[g].x_advance
			if (first < 0): first = k
			if (width <= max_width): best = k
			else: break
		k = k + 1
	if (best < 0): return first
	return best
