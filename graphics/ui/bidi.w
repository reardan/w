# Optional Linux x64 paragraph bidi analysis. Shape logical source ranges;
# scalar position maps are not glyph order or a caret/selection model.
# Native ABI: https://github.com/fribidi/fribidi/blob/master/lib/fribidi-bidi.h
import lib.dlcall

const int UI_BIDI_OK = 0
const int UI_BIDI_INVALID = 1
const int UI_BIDI_UNAVAILABLE = 2
const int UI_BIDI_LIMIT = 3
const int UI_BIDI_FAILED = 4
const int UI_BIDI_AUTO = 0
const int UI_BIDI_LTR = 4
const int UI_BIDI_RTL = 5

struct ui_bidi_run:
	int byte_start
	int byte_length
	int scalar_start
	int scalar_count
	int level
	int direction

struct ui_bidi_paragraph:
	int status
	int direction
	int source_bytes
	int count
	int run_count
	int* byte_offsets
	char* levels
	int32* logical_to_visual
	int32* visual_to_logical
	ui_bidi_run* runs
	int32* visual_runs

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

void __ui_bidi_clear(ui_bidi_paragraph* paragraph):
	free(paragraph.byte_offsets)
	free(paragraph.levels)
	free(paragraph.logical_to_visual)
	free(paragraph.visual_to_logical)
	free(paragraph.runs)
	free(paragraph.visual_runs)
	paragraph.byte_offsets = 0
	paragraph.levels = 0
	paragraph.logical_to_visual = 0
	paragraph.visual_to_logical = 0
	paragraph.runs = 0
	paragraph.visual_runs = 0
	paragraph.count = 0
	paragraph.run_count = 0

void ui_bidi_paragraph_free(ui_bidi_paragraph* paragraph):
	if (paragraph == 0): return
	__ui_bidi_clear(paragraph)
	free(paragraph)

# Analyze one unwrapped paragraph (no hard line or paragraph separators).
# Strict explicit-length UTF-8, including NUL; max 65536 bytes/scalars.
# Always owned, including failures. Empty input succeeds without a native call.
# Controls retain indices. Runs cover logical source; visual_runs orders runs.
ui_bidi_paragraph* ui_bidi_utf8(char* text, int length, int direction, int max_scalars):
	ui_bidi_paragraph* paragraph = new ui_bidi_paragraph()
	paragraph.status = UI_BIDI_INVALID
	if ((length < 0) || ((text == 0) && (length > 0))): return paragraph
	if ((direction != UI_BIDI_AUTO) && (direction != UI_BIDI_LTR) && (direction != UI_BIDI_RTL)): return paragraph
	if ((length > 65536) || (max_scalars < 0) || (max_scalars > 65536)):
		paragraph.status = UI_BIDI_LIMIT
		return paragraph
	int count = 0
	int at = 0
	while (at < length):
		int cp = 0
		int size = utf8_scan(text + at, length - at, &cp)
		if (size == 0): return paragraph
		if (((cp >= 10) && (cp <= 13)) || ((cp >= 28) && (cp <= 30)) || (cp == 133) || (cp == 8232) || (cp == 8233)): return paragraph
		count = count + 1
		at = at + size
	if (count > max_scalars):
		paragraph.status = UI_BIDI_LIMIT
		return paragraph
	paragraph.direction = UI_BIDI_LTR
	if (direction == UI_BIDI_RTL): paragraph.direction = UI_BIDI_RTL
	paragraph.source_bytes = length
	if (count == 0):
		paragraph.status = UI_BIDI_OK
		paragraph.byte_offsets = cast(int*, malloc(sizeof(int)))
		paragraph.byte_offsets[0] = 0
		return paragraph
	if (!ui_bidi_available()):
		paragraph.status = UI_BIDI_UNAVAILABLE
		return paragraph
	paragraph.status = UI_BIDI_FAILED
	paragraph.count = count
	paragraph.byte_offsets = cast(int*, malloc((count + 1) * sizeof(int)))
	paragraph.levels = cast(char*, malloc(count))
	paragraph.logical_to_visual = cast(int32*, malloc(count * 4))
	paragraph.visual_to_logical = cast(int32*, malloc(count * 4))
	int32* scalars = cast(int32*, malloc(count * 4))
	int32* types = cast(int32*, malloc(count * 4))
	int32* brackets = cast(int32*, malloc(count * 4))
	at = 0
	for i in range(count):
		int cp = 0
		paragraph.byte_offsets[i] = at
		at = at + utf8_scan(text + at, length - at, &cp)
		scalars[i] = cp
		paragraph.visual_to_logical[i] = i
	paragraph.byte_offsets[count] = length
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
	args[4] = cast(int, paragraph.levels)
	# Native result is signed char, so only its low byte is defined by the ABI.
	int success = dl_call(__ui_bidi_functions[2], &args[0]) & 255
	if (success):
		args[0] = 0 # L2 mapping only: leave mark placement and mirroring to shaping.
		args[1] = cast(int, types)
		args[2] = count
		args[3] = 0
		args[4] = base
		args[5] = cast(int, paragraph.levels)
		args[6] = 0
		args[7] = cast(int, paragraph.visual_to_logical)
		success = dl_call(__ui_bidi_functions[3], &args[0]) & 255
	free(scalars)
	free(types)
	free(brackets)
	if (!success):
		__ui_bidi_clear(paragraph)
		return paragraph
	if (base & 1): paragraph.direction = UI_BIDI_RTL
	else: paragraph.direction = UI_BIDI_LTR
	paragraph.runs = cast(ui_bidi_run*, malloc(count * sizeof(ui_bidi_run)))
	paragraph.visual_runs = cast(int32*, malloc(count * 4))
	int32* owners = cast(int32*, malloc(count * 4))
	int start = 0
	while (start < count):
		int end = start + 1
		while ((end < count) && (paragraph.levels[end] == paragraph.levels[start])): end = end + 1
		ui_bidi_run* run = &paragraph.runs[paragraph.run_count]
		run.byte_start = paragraph.byte_offsets[start]
		run.byte_length = paragraph.byte_offsets[end] - run.byte_start
		run.scalar_start = start
		run.scalar_count = end - start
		run.level = paragraph.levels[start]
		run.direction = UI_BIDI_LTR
		if (run.level & 1): run.direction = UI_BIDI_RTL
		for i in range(start, end): owners[i] = paragraph.run_count
		paragraph.run_count = paragraph.run_count + 1
		start = end
	int previous = -1
	int visual_count = 0
	for i in range(count):
		int logical = paragraph.visual_to_logical[i]
		paragraph.logical_to_visual[logical] = i
		int owner = owners[logical]
		if (owner != previous):
			paragraph.visual_runs[visual_count] = owner
			visual_count = visual_count + 1
			previous = owner
	free(owners)
	paragraph.status = UI_BIDI_OK
	return paragraph
