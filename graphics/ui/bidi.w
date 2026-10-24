# Paragraph bidi analysis: the optional Linux x64 FriBidi engine, with the
# portable lib.bidi engine of graphics.ui.bidi_portable whenever FriBidi is
# unavailable (or when ui_bidi_set_engine selects it). Scalar position maps
# are not glyph order or a caret/selection model.
# Native ABI: https://github.com/fribidi/fribidi/blob/master/lib/fribidi-bidi.h
import lib.dlcall
import graphics.ui.bidi_portable

int __ui_bidi_engine

# UI_BIDI_ENGINE_AUTO (FriBidi when present, else portable), _NATIVE
# (FriBidi only: UI_BIDI_UNAVAILABLE without it) or _PORTABLE.
void ui_bidi_set_engine(int engine):
	__ui_bidi_engine = engine

int __ui_bidi_state
int[4] __ui_bidi_functions

int ui_bidi_available():
	if (__ui_bidi_state != 0): return __ui_bidi_state == 1
	__ui_bidi_state = -1
	if ((__word_size__ != 8) || (__target_isa__ != 0) || os_windows()): return 0
	char* library = dl_open(c"libfribidi.so.0")
	if (library == 0): return 0
	__ui_bidi_functions[0] = dl_trampoline_argv(dl_sym(library, c"fribidi_get_bidi_types"), 3, 0)
	__ui_bidi_functions[1] = dl_trampoline_argv(dl_sym(library, c"fribidi_get_bracket_types"), 4, 0)
	__ui_bidi_functions[2] = dl_trampoline_argv(dl_sym(library, c"fribidi_get_par_embedding_levels_ex"), 5, 0)
	__ui_bidi_functions[3] = dl_trampoline_argv(dl_sym(library, c"fribidi_reorder_line"), 8, 0)
	for i in range(4):
		if (__ui_bidi_functions[i] == 0): return 0
	__ui_bidi_state = 1
	return 1

int __ui_bidi_reorder(int32* types, int count, int direction, char* levels, int32* visual_to_logical):
	# L1 includes trailing isolate controls. Native reorder_line versions omit
	# those from their trailing scan, so reset the entire suffix before L2.
	# FriBidi ABI masks: EXPLICIT | ISOLATE | BN | WS (bidi-types.h).
	int trailing_mask = 0x1000 | 0x8000 | 0x100000 | 0x800000
	int end = count
	while ((end > 0) && (types[end - 1] & trailing_mask)):
		end = end - 1
		levels[end] = direction & 1
	int[8] args
	args[0] = 0 # L2 mapping only: leave mark placement and mirroring to shaping.
	args[1] = cast(int, types)
	args[2] = count
	args[3] = 0 # All pointers already refer to the selected line slice.
	args[4] = 0x110
	if (direction == UI_BIDI_RTL): args[4] = 0x111
	args[5] = cast(int, levels)
	args[6] = 0
	args[7] = cast(int, visual_to_logical)
	return dl_call(__ui_bidi_functions[3], &args[0]) & 255

# Analyze one unwrapped paragraph (no hard line or paragraph separators).
# Strict explicit-length UTF-8, including NUL; max 65536 bytes/scalars.
# Always owned, including failures. Empty input succeeds without analysis.
# Controls retain indices. Runs cover logical source; visual_runs orders runs.
ui_bidi_paragraph* ui_bidi_utf8(char* text, int length, int direction, int max_scalars):
	ui_bidi_paragraph* paragraph = new ui_bidi_paragraph()
	int count = __ui_bidi_validate(paragraph, text, length, direction, max_scalars)
	if (count <= 0): return paragraph
	if (__ui_bidi_engine == UI_BIDI_ENGINE_PORTABLE):
		__ui_bidi_portable_fill(paragraph, text, length, direction, count)
		return paragraph
	if (!ui_bidi_available()):
		if (__ui_bidi_engine == UI_BIDI_ENGINE_AUTO):
			__ui_bidi_portable_fill(paragraph, text, length, direction, count)
			return paragraph
		paragraph.status = UI_BIDI_UNAVAILABLE
		return paragraph
	paragraph.engine = UI_BIDI_ENGINE_NATIVE
	paragraph.status = UI_BIDI_FAILED
	int32* scalars = cast(int32*, malloc(count * 4))
	__ui_bidi_alloc(paragraph, text, length, count, scalars)
	int32* types = paragraph.bidi_types
	int32* brackets = cast(int32*, malloc(count * 4))
	int[8] args
	args[0] = cast(int, scalars)
	args[1] = count
	args[2] = cast(int, types)
	dl_call(__ui_bidi_functions[0], &args[0])
	args[3] = cast(int, brackets)
	dl_call(__ui_bidi_functions[1], &args[0])
	# FriBidiParType is uint32_t. ON=0x40 guesses first strong; LTR=0x110.
	int32 base = 0x40
	if (direction == UI_BIDI_LTR): base = 0x110
	if (direction == UI_BIDI_RTL): base = 0x111
	args[0] = cast(int, types)
	args[1] = cast(int, brackets)
	args[2] = count
	args[3] = cast(int, &base)
	args[4] = cast(int, paragraph.resolved_levels)
	# Native result is signed char, so only its low byte is defined by the ABI.
	int success = dl_call(__ui_bidi_functions[2], &args[0]) & 255
	if (success):
		if (base & 1): paragraph.direction = UI_BIDI_RTL
		else: paragraph.direction = UI_BIDI_LTR
		for i in range(count): paragraph.levels[i] = paragraph.resolved_levels[i]
		success = __ui_bidi_reorder(types, count, paragraph.direction, paragraph.levels, paragraph.visual_to_logical)
	free(scalars)
	free(brackets)
	if (!success):
		__ui_bidi_clear(paragraph)
		return paragraph
	__ui_bidi_finish(paragraph)
	return paragraph


# Reorder a caller-selected scalar range using the original paragraph context.
# Owned output survives paragraph disposal. Maps/levels use line-local indices;
# byte offsets and run byte/scalar starts stay relative to the original paragraph.
# Caller chooses legal wrap boundaries (do not split graphemes/shaping clusters).
# The paragraph's own engine reorders the line.
ui_bidi_line* ui_bidi_reorder_line(ui_bidi_paragraph* paragraph, int scalar_start, int scalar_count):
	if ((paragraph != 0) && (paragraph.engine == UI_BIDI_ENGINE_PORTABLE)): return ui_bidi_portable_reorder_line(paragraph, scalar_start, scalar_count)
	ui_bidi_line* line = new ui_bidi_line()
	if (!__ui_bidi_line_begin(line, paragraph, scalar_start, scalar_count)): return line
	if ((scalar_count > 0) && !ui_bidi_available()):
		line.status = UI_BIDI_UNAVAILABLE
		return line
	__ui_bidi_line_alloc(line, paragraph, scalar_start, scalar_count)
	if (scalar_count == 0): return line
	line.status = UI_BIDI_FAILED
	if (!__ui_bidi_reorder(&paragraph.bidi_types[scalar_start], scalar_count, line.direction, line.levels, line.visual_to_logical)):
		__ui_bidi_line_clear(line)
		return line
	__ui_bidi_line_finish(line, scalar_start, scalar_count)
	return line
