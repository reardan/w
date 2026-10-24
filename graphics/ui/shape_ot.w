# Shaped text runs with no native dependency: the result types of
# graphics.ui.shape, the portable lib.ttf_shape engine behind them, and
# drawing through the UI atlas. Import this module where the HarfBuzz
# adapter cannot be used (static x86, wasm, macOS, Windows); graphics.ui.shape
# adds the optional Linux x64 HarfBuzz engine and falls back to this one.
# Output positions use 26.6 pixels. See docs/projects/text_shaping.md.
import lib.lib
import lib.utf8
import lib.ttf
import lib.ttf_layout
import lib.ttf_shape
import lib.unicode_text
import graphics.ui.render

const int UI_SHAPE_OK = 0
const int UI_SHAPE_INVALID = 1
const int UI_SHAPE_UNAVAILABLE = 2
const int UI_SHAPE_LIMIT = 3
const int UI_SHAPE_FAILED = 4
const int UI_SHAPE_AUTO = 0
const int UI_SHAPE_LTR = 4
const int UI_SHAPE_RTL = 5
# Which implementation produced a run (ui_shaped_run.engine).
const int UI_SHAPE_ENGINE_AUTO = 0
const int UI_SHAPE_ENGINE_NATIVE = 1
const int UI_SHAPE_ENGINE_PORTABLE = 2

struct ui_shaped_glyph:
	int gid
	int cluster
	int x_advance
	int y_advance
	int x_offset
	int y_offset

struct ui_shaped_run:
	int status
	int strike
	int direction
	int source_bytes
	int count
	int advance
	ui_shaped_glyph* glyphs
	int engine

# Validates ui_shape_utf8 arguments into run. Returns 1 when shaping may
# proceed (status still INVALID), 0 with the failure status set.
int __ui_shape_validate(ui_shaped_run* run, char* text, int length, int strike, int direction, char* language, int max_glyphs):
	run.status = UI_SHAPE_INVALID
	ui_font_init()
	if ((length < 0) || ((text == 0) && (length > 0))): return 0
	if ((strike < 0) || (strike >= ui_font_st.strike_count)): return 0
	if ((direction != UI_SHAPE_AUTO) && (direction != UI_SHAPE_LTR) && (direction != UI_SHAPE_RTL)): return 0
	if ((max_glyphs < 0) || (max_glyphs > 1048576) || (length > 65536)):
		run.status = UI_SHAPE_LIMIT
		return 0
	if (!utf8_validate_bytes(text, length)): return 0
	if ((language != 0) && (strlen(language) > 64)): return 0
	run.strike = strike
	run.source_bytes = length
	return 1

# Font units to 26.6 pixels at ppem, rounded half away from zero.
int __ui_shape_scale(ttf_font* f, int ppem, int units):
	int scaled = units * ppem * 64
	if (scaled >= 0): return (scaled + f.upem / 2) / f.upem
	return 0 - ((f.upem / 2 - scaled) / f.upem)

# Shape with lib.ttf_shape. script is an ISO 15924 tag packed big-endian
# (0 guesses); AUTO direction follows the first strong bidi character.
void __ui_shape_portable_fill(ui_shaped_run* run, char* text, int length, int direction, int script, int max_glyphs):
	run.engine = UI_SHAPE_ENGINE_PORTABLE
	int strike = run.strike
	ttf_font* f = ui_font_face_font(ui_font_st.strikes[strike].face)
	int ppem = ui_font_st.strikes[strike].ppem
	int count = 0
	int at = 0
	while (at < length):
		int cp = 0
		at = at + utf8_scan(text + at, length - at, &cp)
		count = count + 1
	int32* cps = cast(int32*, malloc(count * 4 + 4))
	int32* clusters = cast(int32*, malloc(count * 4 + 4))
	at = 0
	int rtl = direction == UI_SHAPE_RTL
	int strong = 0
	for i in range(count):
		int cp = 0
		clusters[i] = at
		at = at + utf8_scan(text + at, length - at, &cp)
		cps[i] = cp
		if (strong == 0):
			int cls = ut_bidi_class(cp)
			if (cls == ut_bidi_l): strong = 1
			if ((cls == ut_bidi_r) || (cls == ut_bidi_al)): strong = 2
	if (direction == UI_SHAPE_AUTO):
		# The first strong character, else the script's own direction.
		rtl = strong == 2
		if (strong == 0): rtl = ttf_script_is_rtl(ttf_guess_script(cps, count))
	run.direction = UI_SHAPE_LTR
	if (rtl): run.direction = UI_SHAPE_RTL
	int script_id = -1
	if (script != 0):
		char[4] code
		code[0] = (script >> 24) & 255
		code[1] = (script >> 16) & 255
		code[2] = (script >> 8) & 255
		code[3] = script & 255
		script_id = ut_script_from_code(&code[0])
	otl_buffer* b = ttf_shape(f, cps, clusters, count, rtl, script_id, 0, 0)
	free(cps)
	free(clusters)
	if (b.count > max_glyphs):
		run.status = UI_SHAPE_LIMIT
		otl_buffer_free(b)
		return
	run.count = b.count
	run.glyphs = cast(ui_shaped_glyph*, __w_alloc(__w_size_mul(b.count + 1, sizeof(ui_shaped_glyph))))
	for i in range(b.count):
		otl_glyph* g = &b.glyphs[i]
		ui_shaped_glyph* out = &run.glyphs[i]
		out.gid = g.gid
		out.cluster = g.cluster
		out.x_advance = __ui_shape_scale(f, ppem, g.x_advance)
		out.y_advance = __ui_shape_scale(f, ppem, g.y_advance)
		out.x_offset = __ui_shape_scale(f, ppem, g.x_offset)
		out.y_offset = __ui_shape_scale(f, ppem, g.y_offset)
		run.advance = run.advance + out.x_advance
	otl_buffer_free(b)
	run.status = UI_SHAPE_OK

# ui_shape_utf8 with the portable engine only; same contract. The
# language is accepted for API parity; the font's default language
# system is used.
ui_shaped_run* ui_shape_portable_utf8(char* text, int length, int strike, int direction, int script, char* language, int max_glyphs):
	ui_shaped_run* run = new ui_shaped_run()
	run.engine = UI_SHAPE_ENGINE_PORTABLE
	if (!__ui_shape_validate(run, text, length, strike, direction, language, max_glyphs)): return run
	__ui_shape_portable_fill(run, text, length, direction, script, max_glyphs)
	return run

void ui_shaped_run_free(ui_shaped_run* run):
	if (run == 0): return
	free(run.glyphs)
	free(run)

# x,y are the line-box origin. Draw in visual glyph order using the same atlas
# and clip stack as normal UI text, with no second pair-kerning pass.
int ui_draw_shaped_run(ui_renderer* renderer, float32 x, float32 y, ui_shaped_run* run, ui_color color):
	if ((run == 0) || (run.status != UI_SHAPE_OK)): return 0
	int pen_x = 0
	int pen_y = 0
	for i in range(run.count):
		ui_shaped_glyph* glyph = &run.glyphs[i]
		ui_glyph metrics = ui_font_glyph_id(run.strike, glyph.gid)
		float32 gx = x + cast(float32, pen_x + glyph.x_offset) / 64.0
		float32 gy = y - cast(float32, pen_y + glyph.y_offset) / 64.0
		ui_render_glyph_metrics(renderer, gx, gy, metrics, run.strike, 0.0, color)
		pen_x = pen_x + glyph.x_advance
		pen_y = pen_y + glyph.y_advance
	return 1
