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
	# Retained native analysis before line-specific whitespace resets.
	int32* bidi_types
	char* resolved_levels

struct ui_bidi_line:
	int status
	int direction
	int byte_start
	int byte_length
	int scalar_start
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
	free(paragraph.bidi_types)
	free(paragraph.resolved_levels)
	paragraph.byte_offsets = 0
	paragraph.levels = 0
	paragraph.logical_to_visual = 0
	paragraph.visual_to_logical = 0
	paragraph.runs = 0
	paragraph.visual_runs = 0
	paragraph.bidi_types = 0
	paragraph.resolved_levels = 0
	paragraph.count = 0
	paragraph.run_count = 0

void ui_bidi_paragraph_free(ui_bidi_paragraph* paragraph):
	if (paragraph == 0): return
	__ui_bidi_clear(paragraph)
	free(paragraph)

# Maps are local to the supplied slice; byte/scalar run spans name the paragraph.
int __ui_bidi_runs(int count, int scalar_start, int* byte_offsets, char* levels, int32* logical_to_visual, int32* visual_to_logical, ui_bidi_run* runs, int32* visual_runs):
	int run_count = 0
	int32* owners = cast(int32*, malloc(count * 4))
	int start = 0
	while (start < count):
		int end = start + 1
		while ((end < count) && (levels[end] == levels[start])): end = end + 1
		ui_bidi_run* run = &runs[run_count]
		run.byte_start = byte_offsets[start]
		run.byte_length = byte_offsets[end] - run.byte_start
		run.scalar_start = scalar_start + start
		run.scalar_count = end - start
		run.level = levels[start]
		run.direction = UI_BIDI_LTR
		if (run.level & 1): run.direction = UI_BIDI_RTL
		for i in range(start, end): owners[i] = run_count
		run_count = run_count + 1
		start = end
	int previous = -1
	int visual_count = 0
	for i in range(count):
		int logical = visual_to_logical[i]
		logical_to_visual[logical] = i
		int owner = owners[logical]
		if (owner != previous):
			visual_runs[visual_count] = owner
			visual_count = visual_count + 1
			previous = owner
	free(owners)
	return run_count

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
	paragraph.bidi_types = cast(int32*, malloc(count * 4))
	paragraph.resolved_levels = cast(char*, malloc(count))
	int32* types = paragraph.bidi_types
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
	paragraph.runs = cast(ui_bidi_run*, malloc(count * sizeof(ui_bidi_run)))
	paragraph.visual_runs = cast(int32*, malloc(count * 4))
	paragraph.run_count = __ui_bidi_runs(count, 0, paragraph.byte_offsets, paragraph.levels, paragraph.logical_to_visual, paragraph.visual_to_logical, paragraph.runs, paragraph.visual_runs)
	paragraph.status = UI_BIDI_OK
	return paragraph

void __ui_bidi_line_clear(ui_bidi_line* line):
	free(line.byte_offsets)
	free(line.levels)
	free(line.logical_to_visual)
	free(line.visual_to_logical)
	free(line.runs)
	free(line.visual_runs)
	line.byte_offsets = 0
	line.levels = 0
	line.logical_to_visual = 0
	line.visual_to_logical = 0
	line.runs = 0
	line.visual_runs = 0
	line.count = 0
	line.run_count = 0

void ui_bidi_line_free(ui_bidi_line* line):
	if (line == 0): return
	__ui_bidi_line_clear(line)
	free(line)

# Reorder a caller-selected scalar range using the original paragraph context.
# Owned output survives paragraph disposal. Maps/levels use line-local indices;
# byte offsets and run byte/scalar starts stay relative to the original paragraph.
# Caller chooses legal wrap boundaries (do not split graphemes/shaping clusters).
ui_bidi_line* ui_bidi_reorder_line(ui_bidi_paragraph* paragraph, int scalar_start, int scalar_count):
	ui_bidi_line* line = new ui_bidi_line()
	line.status = UI_BIDI_INVALID
	if ((paragraph == 0) || (paragraph.status != UI_BIDI_OK)): return line
	if ((scalar_start < 0) || (scalar_start > paragraph.count) || (scalar_count < 0)): return line
	if (scalar_count > paragraph.count - scalar_start): return line
	line.direction = paragraph.direction
	line.scalar_start = scalar_start
	line.byte_start = paragraph.byte_offsets[scalar_start]
	line.byte_length = paragraph.byte_offsets[scalar_start + scalar_count] - line.byte_start
	if ((scalar_count > 0) && !ui_bidi_available()):
		line.status = UI_BIDI_UNAVAILABLE
		return line
	line.byte_offsets = cast(int*, malloc((scalar_count + 1) * sizeof(int)))
	for i in range(scalar_count + 1): line.byte_offsets[i] = paragraph.byte_offsets[scalar_start + i]
	if (scalar_count == 0):
		line.status = UI_BIDI_OK
		return line
	line.levels = cast(char*, malloc(scalar_count))
	line.logical_to_visual = cast(int32*, malloc(scalar_count * 4))
	line.visual_to_logical = cast(int32*, malloc(scalar_count * 4))
	for i in range(scalar_count):
		line.levels[i] = paragraph.resolved_levels[scalar_start + i]
		line.visual_to_logical[i] = i
	line.status = UI_BIDI_FAILED
	if (!__ui_bidi_reorder(&paragraph.bidi_types[scalar_start], scalar_count, line.direction, line.levels, line.visual_to_logical)):
		__ui_bidi_line_clear(line)
		return line
	line.count = scalar_count
	line.runs = cast(ui_bidi_run*, malloc(scalar_count * sizeof(ui_bidi_run)))
	line.visual_runs = cast(int32*, malloc(scalar_count * 4))
	line.run_count = __ui_bidi_runs(scalar_count, scalar_start, line.byte_offsets, line.levels, line.logical_to_visual, line.visual_to_logical, line.runs, line.visual_runs)
	line.status = UI_BIDI_OK
	return line
