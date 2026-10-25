# Paragraph bidi analysis with no native dependency: the result types of
# graphics.ui.bidi and the lib.bidi (UAX #9) implementation behind them.
# Import this module where the FriBidi adapter cannot be used (static
# x86, wasm, macOS, Windows); graphics.ui.bidi adds the optional Linux x64
# FriBidi engine and falls back to this one. See docs/projects/text_shaping.md.
import lib.lib
import lib.bidi

const int UI_BIDI_OK = 0
const int UI_BIDI_INVALID = 1
const int UI_BIDI_UNAVAILABLE = 2
const int UI_BIDI_LIMIT = 3
const int UI_BIDI_FAILED = 4
const int UI_BIDI_AUTO = 0
const int UI_BIDI_LTR = 4
const int UI_BIDI_RTL = 5
# Which implementation produced a paragraph (ui_bidi_paragraph.engine).
const int UI_BIDI_ENGINE_AUTO = 0
const int UI_BIDI_ENGINE_NATIVE = 1
const int UI_BIDI_ENGINE_PORTABLE = 2

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
	# Retained analysis before line-specific whitespace resets: FriBidi
	# type masks (native) or Bidi_Class values (portable), per engine.
	int32* bidi_types
	char* resolved_levels
	int engine

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
	int engine

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

# Validates arguments and UTF-8 for ui_bidi_utf8 and fills the paragraph's
# status, direction and source size. Returns the scalar count, or -1 with
# the failure status set.
int __ui_bidi_validate(ui_bidi_paragraph* paragraph, char* text, int length, int direction, int max_scalars):
	paragraph.status = UI_BIDI_INVALID
	if ((length < 0) || ((text == 0) && (length > 0))): return -1
	if ((direction != UI_BIDI_AUTO) && (direction != UI_BIDI_LTR) && (direction != UI_BIDI_RTL)): return -1
	if ((length > 65536) || (max_scalars < 0) || (max_scalars > 65536)):
		paragraph.status = UI_BIDI_LIMIT
		return -1
	int count = 0
	int at = 0
	while (at < length):
		int cp = 0
		int size = utf8_scan(text + at, length - at, &cp)
		if (size == 0): return -1
		if (((cp >= 10) && (cp <= 13)) || ((cp >= 28) && (cp <= 30)) || (cp == 133) || (cp == 8232) || (cp == 8233)): return -1
		count = count + 1
		at = at + size
	if (count > max_scalars):
		paragraph.status = UI_BIDI_LIMIT
		return -1
	paragraph.direction = UI_BIDI_LTR
	if (direction == UI_BIDI_RTL): paragraph.direction = UI_BIDI_RTL
	paragraph.source_bytes = length
	if (count == 0):
		paragraph.status = UI_BIDI_OK
		paragraph.byte_offsets = cast(int*, malloc(sizeof(int)))
		paragraph.byte_offsets[0] = 0
	return count

# Allocates the per-scalar arrays and decodes byte offsets and scalars;
# visual_to_logical starts as the identity.
void __ui_bidi_alloc(ui_bidi_paragraph* paragraph, char* text, int length, int count, int32* scalars):
	paragraph.count = count
	paragraph.byte_offsets = cast(int*, malloc((count + 1) * sizeof(int)))
	paragraph.levels = cast(char*, malloc(count))
	paragraph.logical_to_visual = cast(int32*, malloc(count * 4))
	paragraph.visual_to_logical = cast(int32*, malloc(count * 4))
	paragraph.bidi_types = cast(int32*, malloc(count * 4))
	paragraph.resolved_levels = cast(char*, malloc(count))
	int at = 0
	for i in range(count):
		int cp = 0
		paragraph.byte_offsets[i] = at
		at = at + utf8_scan(text + at, length - at, &cp)
		scalars[i] = cp
		paragraph.visual_to_logical[i] = i
	paragraph.byte_offsets[count] = length

void __ui_bidi_finish(ui_bidi_paragraph* paragraph):
	int count = paragraph.count
	paragraph.runs = cast(ui_bidi_run*, malloc(count * sizeof(ui_bidi_run)))
	paragraph.visual_runs = cast(int32*, malloc(count * 4))
	paragraph.run_count = __ui_bidi_runs(count, 0, paragraph.byte_offsets, paragraph.levels, paragraph.logical_to_visual, paragraph.visual_to_logical, paragraph.runs, paragraph.visual_runs)
	paragraph.status = UI_BIDI_OK

# lib.bidi rule L1 and L2 on one slice of retained Bidi_Class values.
void __ui_bidi_portable_reorder(int32* types, int count, int direction, char* levels, int32* visual_to_logical):
	char* classes = cast(char*, malloc(count + 1))
	for i in range(count): classes[i] = types[i]
	bidi_line_levels(classes, levels, count, direction == UI_BIDI_RTL)
	bidi_reorder(levels, count, visual_to_logical)
	free(classes)

# Fill a validated, nonempty paragraph with the portable engine.
void __ui_bidi_portable_fill(ui_bidi_paragraph* paragraph, char* text, int length, int direction, int count):
	paragraph.engine = UI_BIDI_ENGINE_PORTABLE
	int32* scalars = cast(int32*, malloc(count * 4))
	__ui_bidi_alloc(paragraph, text, length, count, scalars)
	char* classes = cast(char*, malloc(count))
	int base = -1
	if (direction == UI_BIDI_LTR): base = 0
	if (direction == UI_BIDI_RTL): base = 1
	int para = bidi_resolve(scalars, count, base, classes, paragraph.resolved_levels)
	paragraph.direction = UI_BIDI_LTR + para
	for i in range(count):
		paragraph.bidi_types[i] = classes[i]
		paragraph.levels[i] = paragraph.resolved_levels[i]
	__ui_bidi_portable_reorder(paragraph.bidi_types, count, paragraph.direction, paragraph.levels, paragraph.visual_to_logical)
	free(classes)
	free(scalars)
	__ui_bidi_finish(paragraph)

# ui_bidi_utf8 with the portable engine only; same contract.
ui_bidi_paragraph* ui_bidi_portable_utf8(char* text, int length, int direction, int max_scalars):
	ui_bidi_paragraph* paragraph = new ui_bidi_paragraph()
	paragraph.engine = UI_BIDI_ENGINE_PORTABLE
	int count = __ui_bidi_validate(paragraph, text, length, direction, max_scalars)
	if (count <= 0): return paragraph
	__ui_bidi_portable_fill(paragraph, text, length, direction, count)
	return paragraph

# Validates a line request and sets up its byte offsets and identity map.
# Returns 1 when the caller must still reorder levels (a nonempty range).
int __ui_bidi_line_begin(ui_bidi_line* line, ui_bidi_paragraph* paragraph, int scalar_start, int scalar_count):
	line.status = UI_BIDI_INVALID
	if ((paragraph == 0) || (paragraph.status != UI_BIDI_OK)): return 0
	if ((scalar_start < 0) || (scalar_start > paragraph.count) || (scalar_count < 0)): return 0
	if (scalar_count > paragraph.count - scalar_start): return 0
	line.engine = paragraph.engine
	line.direction = paragraph.direction
	line.scalar_start = scalar_start
	line.byte_start = paragraph.byte_offsets[scalar_start]
	line.byte_length = paragraph.byte_offsets[scalar_start + scalar_count] - line.byte_start
	return 1

void __ui_bidi_line_alloc(ui_bidi_line* line, ui_bidi_paragraph* paragraph, int scalar_start, int scalar_count):
	line.byte_offsets = cast(int*, malloc((scalar_count + 1) * sizeof(int)))
	for i in range(scalar_count + 1): line.byte_offsets[i] = paragraph.byte_offsets[scalar_start + i]
	if (scalar_count == 0):
		line.status = UI_BIDI_OK
		return
	line.levels = cast(char*, malloc(scalar_count))
	line.logical_to_visual = cast(int32*, malloc(scalar_count * 4))
	line.visual_to_logical = cast(int32*, malloc(scalar_count * 4))
	for i in range(scalar_count):
		line.levels[i] = paragraph.resolved_levels[scalar_start + i]
		line.visual_to_logical[i] = i

void __ui_bidi_line_finish(ui_bidi_line* line, int scalar_start, int scalar_count):
	line.count = scalar_count
	line.runs = cast(ui_bidi_run*, malloc(scalar_count * sizeof(ui_bidi_run)))
	line.visual_runs = cast(int32*, malloc(scalar_count * 4))
	line.run_count = __ui_bidi_runs(scalar_count, scalar_start, line.byte_offsets, line.levels, line.logical_to_visual, line.visual_to_logical, line.runs, line.visual_runs)
	line.status = UI_BIDI_OK

# ui_bidi_reorder_line for a paragraph from the portable engine.
ui_bidi_line* ui_bidi_portable_reorder_line(ui_bidi_paragraph* paragraph, int scalar_start, int scalar_count):
	ui_bidi_line* line = new ui_bidi_line()
	if (!__ui_bidi_line_begin(line, paragraph, scalar_start, scalar_count)): return line
	if ((scalar_count > 0) && (paragraph.engine != UI_BIDI_ENGINE_PORTABLE)):
		line.status = UI_BIDI_INVALID
		return line
	__ui_bidi_line_alloc(line, paragraph, scalar_start, scalar_count)
	if (scalar_count == 0): return line
	__ui_bidi_portable_reorder(&paragraph.bidi_types[scalar_start], scalar_count, line.direction, line.levels, line.visual_to_logical)
	__ui_bidi_line_finish(line, scalar_start, scalar_count)
	return line
