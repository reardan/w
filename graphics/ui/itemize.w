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
# whenever that face has the mark. A grapheme presented as emoji (UTS #51:
# VS16, or a character with Emoji_Presentation) first takes the first of
# those faces with color glyphs that covers it, and one presented as text
# (VS15) the first without. Each face shapes at the strike's ppem.
# Each item shapes with the text around it as context, so Arabic joining
# continues across a face or script boundary inside a word.
#
# Line layout (issue #826): ui_paragraph_layout(p, text, width, flags)
# wraps the paragraph into p.lines at UAX #14 break opportunities
# (lib.linebreak), chosen by shaped width; each line is reordered by
# ui_bidi_portable_reorder_line (rule L1 resets included) and reshaped,
# with carets, hit-testing and drawing across lines.
import lib.lib
import lib.emoji
import lib.utf8
import lib.unicode_text
import lib.linebreak
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

# One wrapped line of a paragraph (ui_paragraph_layout). Its items are
# the paragraph's items cut to the line and to its bidi runs, reshaped.
struct ui_text_line:
	int byte_start        # logical paragraph byte range, trailing spaces included
	int byte_length
	int scalar_start      # the same range in paragraph scalars
	int scalar_count
	int item_count
	ui_text_item* items   # logical order; x from the line's left edge
	int32* visual_items   # item indices, left to right
	int advance           # total width, 26.6 pixels
	int trailing          # 26.6 width of the trailing whitespace inside advance
	int x                 # 26.6 left edge in the layout width, start-aligned
	int top               # pixels from the paragraph's top to the line box
	int ascent            # pixels, as for the paragraph
	int descent

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
	ui_bidi_paragraph* bidi   # the retained UAX #9 analysis, for lines
	int line_count        # lines from the last ui_paragraph_layout
	ui_text_line* lines
	int line_width        # that layout's width, 26.6 pixels
	int height            # pixels: the sum of the line heights

void __ui_items_free(ui_text_item* items, int count):
	for i in range(count): ui_shaped_run_free(items[i].run)
	free(items)

void __ui_paragraph_free_lines(ui_paragraph* p):
	for k in range(p.line_count):
		__ui_items_free(p.lines[k].items, p.lines[k].item_count)
		free(p.lines[k].visual_items)
	free(p.lines)
	p.lines = cast(ui_text_line*, 0)
	p.line_count = 0
	p.height = 0

void ui_paragraph_free(ui_paragraph* p):
	if (p == 0): return
	__ui_paragraph_free_lines(p)
	__ui_items_free(p.items, p.item_count)
	free(p.visual_items)
	ui_bidi_paragraph_free(p.bidi)
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

# The first of previous, base_face, the fallbacks and the default Regular
# that covers text[start, end) and has color glyphs exactly when color is
# set, else -1.
int __ui_item_face_presented(int base_face, int previous, char* text, int start, int end, int color):
	int i = 0 - 2
	while (i <= ui_font_st.fallback_count):
		int f = previous
		if (i == 0 - 1): f = base_face
		else if (i == ui_font_st.fallback_count): f = UI_FACE_REGULAR
		else if (i >= 0): f = ui_font_st.fallbacks[i]
		i = i + 1
		if (f < 0): continue
		if ((ui_font_face_has_color(f) != 0) != (color != 0)): continue
		if (__ui_item_covers(f, text, start, end)): return f
	return 0 - 1

# The face for the grapheme text[start, end) in a strike of base_face,
# preferring previous (-1 for none); see the header comment.
int __ui_item_face(int base_face, int previous, char* text, int start, int end):
	int presentation = emoji_presentation_utf8(text, start, end)
	if (presentation != EMOJI_PRESENTATION_NONE):
		int presented = __ui_item_face_presented(base_face, previous, text, start, end, presentation == EMOJI_PRESENTATION_EMOJI)
		if (presented >= 0): return presented
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

void __ui_item_set(ui_text_item* item, int start, int end, int level, int script, int face):
	item.byte_start = start
	item.byte_length = end - start
	item.level = level
	item.script = script
	item.face = face
	item.strike = 0 - 1
	item.x = 0
	item.run = cast(ui_shaped_run*, 0)

void __ui_item_add(ui_paragraph* p, int start, int end, int level, int script, int face):
	__ui_item_set(&p.items[p.item_count], start, end, level, script, face)
	p.item_count = p.item_count + 1

# Visual order of items made run by run: the runs as UAX #9 orders them
# (visual_runs), the items inside a right-to-left run reversed. Items
# first_item[r] .. item_end[r] - 1 belong to run r.
void __ui_items_order(ui_bidi_run* runs, int32* visual_runs, int run_count, int32* first_item, int32* item_end, int32* visual):
	int v = 0
	for k in range(run_count):
		int r = visual_runs[k]
		if (runs[r].level & 1):
			int i = item_end[r] - 1
			while (i >= first_item[r]):
				visual[v] = i
				v = v + 1
				i = i - 1
		else:
			for i in range(first_item[r], item_end[r]):
				visual[v] = i
				v = v + 1

# Shapes items (their face, level and script set) at the base strike's
# ppem, in sibling strikes that keep its options (hinting), with
# text[context_start, context_end) as shaping context, then places them
# left to right by visual. Raises ascent/descent to every strike used.
# Returns the total advance, or -1 with status set on a failure.
int __ui_items_shape(ui_text_item* items, int count, int32* visual, char* text, int context_start, int context_end, int base_strike, int* ascent, int* descent, int* status):
	int ppem = ui_font_st.strikes[base_strike].ppem
	for i in range(count):
		ui_text_item* item = &items[i]
		item.strike = ui_font_strike_sibling(base_strike, item.face, ppem)
		if (item.strike < 0):
			status[0] = UI_SHAPE_FAILED
			return -1
		int item_direction = UI_SHAPE_LTR
		if (item.level & 1): item_direction = UI_SHAPE_RTL
		item.run = ui_shape_portable_item(text + context_start, context_end - context_start, item.byte_start - context_start, item.byte_length, item.strike, item_direction, __ui_item_script_tag(item.script), 0, 1048576)
		if (item.run.status != UI_SHAPE_OK):
			status[0] = item.run.status
			return -1
		if (ui_font_strike_ascent(item.strike) > ascent[0]): ascent[0] = ui_font_strike_ascent(item.strike)
		if (ui_font_strike_descent(item.strike) > descent[0]): descent[0] = ui_font_strike_descent(item.strike)
	int pen = 0
	for k in range(count):
		ui_text_item* item = &items[visual[k]]
		item.x = pen
		pen = pen + item.run.advance
	return pen

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
	__ui_items_order(bidi.runs, bidi.visual_runs, bidi.run_count, first_item, item_end, p.visual_items)
	free(first_item)
	free(item_end)
	free(scripts)
	p.bidi = bidi
	p.ascent = ui_font_strike_ascent(strike)
	p.descent = ui_font_strike_descent(strike)
	int status = UI_SHAPE_OK
	int advance = __ui_items_shape(p.items, p.item_count, p.visual_items, text, 0, length, strike, &p.ascent, &p.descent, &status)
	if (advance < 0):
		p.status = status
		return p
	p.advance = advance
	p.status = UI_SHAPE_OK
	return p

# The caret x of offset over a logical item list (see ui_paragraph_caret_x).
int __ui_items_caret_x(ui_text_item* items, int count, char* text, int offset):
	if (count == 0): return 0
	if (offset < items[0].byte_start): offset = items[0].byte_start
	for i in range(count):
		ui_text_item* item = &items[i]
		if ((offset >= item.byte_start) && (offset < item.byte_start + item.byte_length)):
			return item.x + ui_shaped_caret_x(item.run, text + item.byte_start, offset - item.byte_start)
	ui_text_item* last = &items[count - 1]
	return last.x + ui_shaped_caret_x(last.run, text + last.byte_start, last.byte_length)

# Caret x (26.6 pixels from the paragraph's left edge) for a byte offset in
# the text p was shaped from. An offset at an item boundary belongs to the
# item that starts there (the character after the caret); the end of the
# text takes the logical end of the last item.
int ui_paragraph_caret_x(ui_paragraph* p, char* text, int offset):
	if ((p == 0) || (p.status != UI_SHAPE_OK)): return 0
	return __ui_items_caret_x(p.items, p.item_count, text, offset)

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

void __ui_items_draw(ui_renderer* renderer, float32 x, float32 y, ui_text_item* items, int count, int32* visual, int ascent, ui_color color):
	for k in range(count):
		ui_text_item* item = &items[visual[k]]
		float32 drop = cast(float32, ascent - ui_font_strike_ascent(item.strike))
		ui_draw_shaped_run(renderer, x + cast(float32, item.x) / 64.0, y + drop, item.run, color)

# Draw at the line box's top-left x,y. Items of other faces share the
# paragraph's baseline (p.ascent below y).
int ui_paragraph_draw(ui_renderer* renderer, float32 x, float32 y, ui_paragraph* p, ui_color color):
	if ((p == 0) || (p.status != UI_SHAPE_OK)): return 0
	__ui_items_draw(renderer, x, y, p.items, p.item_count, p.visual_items, p.ascent, color)
	return 1

# Width-fit helper for simple wrapping: the largest byte offset k at a
# space break (just after a space, or the end of the text) whose logical
# prefix [0, k) is at most max_width (26.6 pixels) wide, measured from the
# shaped glyphs without reshaping. When even the first break is wider, the
# first break, so a caller always advances. Spaces only: this is not
# UAX #14 line breaking; ui_paragraph_layout is.
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

# ---- Line layout (issue #826) ------------------------------------------

# The paragraph scalar index of byte offset (a scalar boundary).
int __ui_paragraph_scalar_at(ui_paragraph* p, int offset):
	int lo = 0
	int hi = p.bidi.count
	while (lo < hi):
		int mid = (lo + hi) >> 1
		if (p.bidi.byte_offsets[mid] < offset): lo = mid + 1
		else: hi = mid
	return lo

# The end of text[start, end) without its trailing whitespace (bidi WS
# and S, the characters rule L1 resets), which hangs past the line's
# width.
int __ui_line_visible_end(ui_paragraph* p, char* text, int start, int end):
	int k = __ui_paragraph_scalar_at(p, end)
	while (k > 0):
		int at = p.bidi.byte_offsets[k - 1]
		if (at < start): break
		int cp = 0
		utf8_scan(text + at, end - at, &cp)
		int cls = ut_bidi_class(cp)
		if ((cls != ut_bidi_ws) && (cls != ut_bidi_s)): break
		end = at
		k = k - 1
	return end

# The break that ends the line starting at start, from the unwrapped
# shaping: the last break opportunity whose line (without trailing
# whitespace) is at most max_width wide, ending at a mandatory break.
# When even the first opportunity is wider, the line breaks inside that
# word at the last grapheme boundary that fits (at least one grapheme).
# prefix[b] is the 26.6 advance of the glyphs whose cluster starts before
# byte b.
int __ui_line_choose(ui_paragraph* p, char* text, char* breaks, int32* prefix, int start, int max_width):
	int length = p.source_bytes
	int best = -1
	int over = -1
	for e in range(start + 1, length + 1):
		if (breaks[e] == lb_break_none): continue
		if (prefix[__ui_line_visible_end(p, text, start, e)] - prefix[start] > max_width):
			over = e
			break
		best = e
		if (breaks[e] == lb_break_mandatory): return e
	if (best >= 0): return best
	if (over < 0): return length
	# An emergency break inside the word ending at over.
	int fit = -1
	int at = start
	while (at < over):
		int next = ui_grapheme_next_n(text, length, at)
		if ((next <= at) || (next > over)): next = over
		if ((fit >= 0) && (prefix[next] - prefix[start] > max_width)): break
		fit = next
		at = next
	return fit

# Builds line [start, end): its bidi line order, items and reshaping.
# Returns UI_SHAPE_OK or a failure status.
int __ui_line_build(ui_paragraph* p, char* text, int start, int end, ui_text_line* line):
	line.items = cast(ui_text_item*, 0)
	line.visual_items = cast(int32*, 0)
	line.item_count = 0
	line.advance = 0
	line.trailing = 0
	line.x = 0
	line.top = 0
	line.byte_start = start
	line.byte_length = end - start
	line.scalar_start = __ui_paragraph_scalar_at(p, start)
	line.scalar_count = __ui_paragraph_scalar_at(p, end) - line.scalar_start
	line.ascent = ui_font_strike_ascent(p.strike)
	line.descent = ui_font_strike_descent(p.strike)
	ui_bidi_line* order = ui_bidi_portable_reorder_line(p.bidi, line.scalar_start, line.scalar_count)
	if (order.status != UI_BIDI_OK):
		ui_bidi_line_free(order)
		return UI_SHAPE_FAILED
	int capacity = p.item_count + order.run_count + 1
	line.items = cast(ui_text_item*, __w_alloc(__w_size_mul(capacity, sizeof(ui_text_item))))
	line.visual_items = cast(int32*, malloc(capacity * 4))
	int32* first_item = cast(int32*, malloc(order.run_count * 4 + 4))
	int32* item_end = cast(int32*, malloc(order.run_count * 4 + 4))
	# The paragraph's items cut to each of the line's bidi runs, which
	# carry the line's levels (after the L1 resets).
	for r in range(order.run_count):
		ui_bidi_run* run = &order.runs[r]
		int run_end = run.byte_start + run.byte_length
		first_item[r] = line.item_count
		for i in range(p.item_count):
			ui_text_item* item = &p.items[i]
			int lo = item.byte_start
			int hi = item.byte_start + item.byte_length
			if (lo < run.byte_start): lo = run.byte_start
			if (hi > run_end): hi = run_end
			if (lo >= hi): continue
			__ui_item_set(&line.items[line.item_count], lo, hi, run.level, item.script, item.face)
			line.item_count = line.item_count + 1
		item_end[r] = line.item_count
	__ui_items_order(order.runs, order.visual_runs, order.run_count, first_item, item_end, line.visual_items)
	free(first_item)
	free(item_end)
	ui_bidi_line_free(order)
	int status = UI_SHAPE_OK
	int advance = __ui_items_shape(line.items, line.item_count, line.visual_items, text, start, end, p.strike, &line.ascent, &line.descent, &status)
	if (advance < 0): return status
	line.advance = advance
	int visible = __ui_line_visible_end(p, text, start, end)
	for i in range(line.item_count):
		ui_text_item* item = &line.items[i]
		for g in range(item.run.count):
			if (item.byte_start + item.run.glyphs[g].cluster >= visible): line.trailing = line.trailing + item.run.glyphs[g].x_advance
	return UI_SHAPE_OK

void __ui_line_clear(ui_text_line* line):
	__ui_items_free(line.items, line.item_count)
	free(line.visual_items)
	line.items = cast(ui_text_item*, 0)
	line.visual_items = cast(int32*, 0)
	line.item_count = 0
	line.advance = 0
	line.trailing = 0

# Wraps the shaped paragraph p (shaped from text) into lines at most
# max_width (26.6 pixels) wide, replacing earlier lines: p.lines[0,
# p.line_count) in order from the top, p.height their total height.
# flags are lib.linebreak tailorings (lb_tailor_*). Breaks are UAX #14
# opportunities chosen by the unwrapped shaped width; each line is then
# reordered (UAX #9 L1-L2 for that line) and reshaped, and when the
# reshaped line is wider than max_width it breaks at an earlier
# opportunity instead. Trailing whitespace hangs: it does not count
# towards the width. A word wider than max_width alone breaks between
# graphemes. Empty text has one empty line. Returns UI_SHAPE_OK, or
# UI_SHAPE_INVALID / _FAILED with no lines.
int ui_paragraph_layout(ui_paragraph* p, char* text, int max_width, int flags):
	if (p == 0): return UI_SHAPE_INVALID
	__ui_paragraph_free_lines(p)
	if ((p.status != UI_SHAPE_OK) || ((text == 0) && (p.source_bytes > 0))): return UI_SHAPE_INVALID
	int length = p.source_bytes
	p.line_width = max_width
	p.lines = cast(ui_text_line*, __w_alloc(__w_size_mul(p.bidi.count + 1, sizeof(ui_text_line))))
	char* breaks = cast(char*, malloc(length + 1))
	lb_breaks_utf8(text, length, flags, breaks)
	int32* prefix = cast(int32*, malloc(length * 4 + 4))
	for b in range(length + 1): prefix[b] = 0
	for i in range(p.item_count):
		ui_text_item* item = &p.items[i]
		for g in range(item.run.count):
			int at = item.byte_start + item.run.glyphs[g].cluster
			if (at < length): prefix[at + 1] = prefix[at + 1] + item.run.glyphs[g].x_advance
	for b in range(length): prefix[b + 1] = prefix[b + 1] + prefix[b]
	int status = UI_SHAPE_OK
	int start = 0
	while ((status == UI_SHAPE_OK) && ((start < length) || (p.line_count == 0))):
		int end = __ui_line_choose(p, text, breaks, prefix, start, max_width)
		ui_text_line* line = &p.lines[p.line_count]
		while (1):
			status = __ui_line_build(p, text, start, end, line)
			if ((status != UI_SHAPE_OK) || (line.advance - line.trailing <= max_width)): break
			# Reshaping widened the line: try the previous opportunity.
			int earlier = end - 1
			while ((earlier > start) && (breaks[earlier] == lb_break_none)): earlier = earlier - 1
			if (earlier <= start): break
			__ui_line_clear(line)
			end = earlier
		p.line_count = p.line_count + 1
		start = end
	free(breaks)
	free(prefix)
	if (status != UI_SHAPE_OK):
		__ui_paragraph_free_lines(p)
		return status
	int top = 0
	for k in range(p.line_count):
		ui_text_line* line = &p.lines[k]
		line.top = top
		top = top + line.ascent + line.descent
		if (p.direction == UI_SHAPE_RTL): line.x = max_width - line.advance
	p.height = top
	return UI_SHAPE_OK

# The line holding byte offset, -1 without lines. An offset at a line
# break belongs to the line that starts there; the end of the text to
# the last line.
int ui_paragraph_line_at(ui_paragraph* p, int offset):
	if ((p == 0) || (p.line_count == 0)): return -1
	for k in range(p.line_count - 1):
		if (offset < p.lines[k + 1].byte_start): return k
	return p.line_count - 1

# The line whose box holds y (pixels from the paragraph's top), clamped
# to the first and last lines; -1 without lines.
int ui_paragraph_line_at_y(ui_paragraph* p, int y):
	if ((p == 0) || (p.line_count == 0)): return -1
	for k in range(p.line_count - 1):
		if (y < p.lines[k + 1].top): return k
	return p.line_count - 1

# Caret position of byte offset across the lines: returns x (26.6 pixels
# from the layout's left edge, line.x included) and stores the line index
# in line_index (the caret box is that line's top, ascent and descent).
int ui_paragraph_line_caret_x(ui_paragraph* p, char* text, int offset, int* line_index):
	int k = ui_paragraph_line_at(p, offset)
	line_index[0] = k
	if (k < 0): return 0
	ui_text_line* line = &p.lines[k]
	return line.x + __ui_items_caret_x(line.items, line.item_count, text, offset)

# Hit-testing across lines: the grapheme boundary whose caret is nearest
# x (26.6 pixels from the layout's left edge) on the line at y (pixels
# from the paragraph's top). A wrapped line's own end offset is the next
# line's start, so a hit there returns its last boundary before it.
int ui_paragraph_hit_test(ui_paragraph* p, char* text, int x, int y):
	int k = ui_paragraph_line_at_y(p, y)
	if (k < 0): return 0
	ui_text_line* line = &p.lines[k]
	int end = line.byte_start + line.byte_length
	int last = end
	if (k + 1 < p.line_count): last = end - 1
	int best = line.byte_start
	int best_distance = -1
	int at = line.byte_start
	while (at <= last):
		int distance = line.x + __ui_items_caret_x(line.items, line.item_count, text, at) - x
		if (distance < 0): distance = 0 - distance
		if ((best_distance < 0) || (distance < best_distance)):
			best = at
			best_distance = distance
		if (at >= end): break
		int next = ui_grapheme_next_n(text, p.source_bytes, at)
		if (next <= at): next = at + 1
		at = next
	return best

# Draws the lines with the layout's top-left at x,y; each line sits at
# its top and x, on its own baseline (line.ascent below its top).
int ui_paragraph_draw_lines(ui_renderer* renderer, float32 x, float32 y, ui_paragraph* p, ui_color color):
	if ((p == 0) || (p.status != UI_SHAPE_OK) || (p.line_count == 0)): return 0
	for k in range(p.line_count):
		ui_text_line* line = &p.lines[k]
		__ui_items_draw(renderer, x + cast(float32, line.x) / 64.0, y + cast(float32, line.top), line.items, line.item_count, line.visual_items, line.ascent, color)
	return 1
