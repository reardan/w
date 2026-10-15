# Optional Linux x64 OpenType shaping. Import explicitly; plain UI text has no
# shared-library dependency on HarfBuzz. Output positions use 26.6 pixels.
# https://harfbuzz.github.io/shaping-and-shape-plans.html
import lib.dlcall
import graphics.ui.render

const int UI_SHAPE_OK = 0
const int UI_SHAPE_INVALID = 1
const int UI_SHAPE_UNAVAILABLE = 2
const int UI_SHAPE_LIMIT = 3
const int UI_SHAPE_FAILED = 4
const int UI_SHAPE_AUTO = 0
const int UI_SHAPE_LTR = 4
const int UI_SHAPE_RTL = 5

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

int __ui_hb_state
int[21] __ui_hb_functions

int ui_shape_available():
	if (__ui_hb_state != 0): return __ui_hb_state == 1
	__ui_hb_state = -1
	if ((__word_size__ != 8) || (__target_isa__ != 0) || os_windows()): return 0
	char* library = dl_open(c"libharfbuzz.so.0")
	if (library == 0): return 0
	__ui_hb_functions[0] = dl_trampoline_argv(dl_sym(library, c"hb_blob_create"), 5, 0)
	if (__ui_hb_functions[0] == 0): return 0
	__ui_hb_functions[1] = dl_trampoline_argv(dl_sym(library, c"hb_blob_destroy"), 1, 0)
	if (__ui_hb_functions[1] == 0): return 0
	__ui_hb_functions[2] = dl_trampoline_argv(dl_sym(library, c"hb_face_create"), 2, 0)
	if (__ui_hb_functions[2] == 0): return 0
	__ui_hb_functions[3] = dl_trampoline_argv(dl_sym(library, c"hb_face_destroy"), 1, 0)
	if (__ui_hb_functions[3] == 0): return 0
	__ui_hb_functions[4] = dl_trampoline_argv(dl_sym(library, c"hb_font_create"), 1, 0)
	if (__ui_hb_functions[4] == 0): return 0
	__ui_hb_functions[5] = dl_trampoline_argv(dl_sym(library, c"hb_font_destroy"), 1, 0)
	if (__ui_hb_functions[5] == 0): return 0
	__ui_hb_functions[6] = dl_trampoline_argv(dl_sym(library, c"hb_ot_font_set_funcs"), 1, 0)
	if (__ui_hb_functions[6] == 0): return 0
	__ui_hb_functions[7] = dl_trampoline_argv(dl_sym(library, c"hb_font_set_scale"), 3, 0)
	if (__ui_hb_functions[7] == 0): return 0
	__ui_hb_functions[8] = dl_trampoline_argv(dl_sym(library, c"hb_buffer_create"), 0, 0)
	if (__ui_hb_functions[8] == 0): return 0
	__ui_hb_functions[9] = dl_trampoline_argv(dl_sym(library, c"hb_buffer_destroy"), 1, 0)
	if (__ui_hb_functions[9] == 0): return 0
	__ui_hb_functions[10] = dl_trampoline_argv(dl_sym(library, c"hb_buffer_add_utf8"), 5, 0)
	if (__ui_hb_functions[10] == 0): return 0
	__ui_hb_functions[11] = dl_trampoline_argv(dl_sym(library, c"hb_buffer_set_direction"), 2, 0)
	if (__ui_hb_functions[11] == 0): return 0
	__ui_hb_functions[12] = dl_trampoline_argv(dl_sym(library, c"hb_buffer_set_script"), 2, 0)
	if (__ui_hb_functions[12] == 0): return 0
	__ui_hb_functions[13] = dl_trampoline_argv(dl_sym(library, c"hb_language_from_string"), 2, 0)
	if (__ui_hb_functions[13] == 0): return 0
	__ui_hb_functions[14] = dl_trampoline_argv(dl_sym(library, c"hb_buffer_set_language"), 2, 0)
	if (__ui_hb_functions[14] == 0): return 0
	__ui_hb_functions[15] = dl_trampoline_argv(dl_sym(library, c"hb_buffer_guess_segment_properties"), 1, 0)
	if (__ui_hb_functions[15] == 0): return 0
	__ui_hb_functions[16] = dl_trampoline_argv(dl_sym(library, c"hb_shape_full"), 5, 1)
	if (__ui_hb_functions[16] == 0): return 0
	__ui_hb_functions[17] = dl_trampoline_argv(dl_sym(library, c"hb_buffer_allocation_successful"), 1, 1)
	if (__ui_hb_functions[17] == 0): return 0
	__ui_hb_functions[18] = dl_trampoline_argv(dl_sym(library, c"hb_buffer_get_glyph_infos"), 2, 0)
	if (__ui_hb_functions[18] == 0): return 0
	__ui_hb_functions[19] = dl_trampoline_argv(dl_sym(library, c"hb_buffer_get_glyph_positions"), 2, 0)
	if (__ui_hb_functions[19] == 0): return 0
	__ui_hb_functions[20] = dl_trampoline_argv(dl_sym(library, c"hb_buffer_get_direction"), 1, 1)
	if (__ui_hb_functions[20] == 0): return 0
	__ui_hb_state = 1
	return 1

# Positions are signed 32-bit C fields, even on a 64-bit W target.
int __ui_shape_signed(char* data):
	int value = load_le32(data)
	if (value > 2147483647): value = value - (2147483647 + 1) * 2
	return value

# One font/script/direction run. The host segments paragraphs, chooses fallback
# faces and line breaks. AUTO guesses direction/script from the run, not bidi.
# script is an ISO 15924 tag packed big endian, or zero to guess; language is a
# terminated BCP 47 name or null for "und". Source is strict explicit-length UTF-8.
# Always returns an owned result, including failure; no partial glyphs on error.
ui_shaped_run* ui_shape_utf8(char* text, int length, int strike, int direction, int script, char* language, int max_glyphs):
	ui_shaped_run* run = new ui_shaped_run()
	run.status = UI_SHAPE_INVALID
	ui_font_init()
	if ((length < 0) || ((text == 0) && (length > 0))): return run
	if ((strike < 0) || (strike >= ui_font_st.strike_count)): return run
	if ((direction != UI_SHAPE_AUTO) && (direction != UI_SHAPE_LTR) && (direction != UI_SHAPE_RTL)): return run
	if ((max_glyphs < 0) || (max_glyphs > 1048576) || (length > 65536)):
		run.status = UI_SHAPE_LIMIT
		return run
	if (!utf8_validate_bytes(text, length)): return run
	if (language == 0): language = c"und"
	if (strlen(language) > 64): return run
	run.strike = strike
	run.source_bytes = length
	if (!ui_shape_available()):
		run.status = UI_SHAPE_UNAVAILABLE
		return run
	run.status = UI_SHAPE_FAILED
	ttf_font* source = ui_font_face_font(ui_font_st.strikes[strike].face)
	int[5] args
	args[0] = cast(int, source.data)
	args[1] = source.size
	args[2] = 1 # HB_MEMORY_MODE_READONLY; font bytes outlive this call.
	args[3] = 0
	args[4] = 0
	int blob = dl_call(__ui_hb_functions[0], &args[0])
	args[0] = blob
	args[1] = 0
	int face = dl_call(__ui_hb_functions[2], &args[0])
	args[0] = face
	int font = dl_call(__ui_hb_functions[4], &args[0])
	args[0] = font
	dl_call(__ui_hb_functions[6], &args[0])
	args[1] = ui_font_st.strikes[strike].ppem * 64
	args[2] = args[1]
	dl_call(__ui_hb_functions[7], &args[0])
	int buffer = dl_call(__ui_hb_functions[8], &args[0])
	args[0] = buffer
	args[1] = cast(int, text)
	args[2] = length
	args[3] = 0
	args[4] = length
	dl_call(__ui_hb_functions[10], &args[0])
	if (direction != UI_SHAPE_AUTO):
		args[1] = direction
		dl_call(__ui_hb_functions[11], &args[0])
	if (script != 0):
		args[1] = script
		dl_call(__ui_hb_functions[12], &args[0])
	args[0] = cast(int, language)
	args[1] = strlen(language)
	int lang = dl_call(__ui_hb_functions[13], &args[0])
	args[0] = buffer
	args[1] = lang
	dl_call(__ui_hb_functions[14], &args[0])
	dl_call(__ui_hb_functions[15], &args[0])
	run.direction = dl_call(__ui_hb_functions[20], &args[0])
	args[0] = font
	args[1] = buffer
	args[2] = 0
	args[3] = 0
	args[4] = 0
	int success = dl_call(__ui_hb_functions[16], &args[0])
	args[0] = buffer
	if (success): success = dl_call(__ui_hb_functions[17], &args[0])
	if (success):
		int32 count = 0
		args[1] = cast(int, &count)
		char* infos = cast(char*, dl_call(__ui_hb_functions[18], &args[0]))
		char* positions = cast(char*, dl_call(__ui_hb_functions[19], &args[0]))
		if ((count < 0) || (count > max_glyphs)): run.status = UI_SHAPE_LIMIT
		else:
			run.count = count
			run.glyphs = cast(ui_shaped_glyph*, __w_alloc(__w_size_mul(count, sizeof(ui_shaped_glyph))))
			run.status = UI_SHAPE_OK
			for i in range(count):
				ui_shaped_glyph* glyph = &run.glyphs[i]
				glyph.gid = load_le32(infos + i * 20)
				glyph.cluster = load_le32(infos + i * 20 + 8)
				glyph.x_advance = __ui_shape_signed(positions + i * 20)
				glyph.y_advance = __ui_shape_signed(positions + i * 20 + 4)
				glyph.x_offset = __ui_shape_signed(positions + i * 20 + 8)
				glyph.y_offset = __ui_shape_signed(positions + i * 20 + 12)
				run.advance = run.advance + glyph.x_advance
	args[0] = buffer
	dl_call(__ui_hb_functions[9], &args[0])
	args[0] = font
	dl_call(__ui_hb_functions[5], &args[0])
	args[0] = face
	dl_call(__ui_hb_functions[3], &args[0])
	args[0] = blob
	dl_call(__ui_hb_functions[1], &args[0])
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
