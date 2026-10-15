# wbuild: name=graphics_ui_bidi_test arch_only=x64
# Optional native bidi plus HarfBuzz integration; headless, no system fonts.
import lib.testing
import graphics.ui.bidi
import graphics.ui.shape

void bidi_assert_failure(char* text, int length, int direction, int budget, int expected):
	ui_bidi_paragraph* paragraph = ui_bidi_utf8(text, length, direction, budget)
	assert_equal(expected, paragraph.status)
	assert_equal(0, paragraph.count)
	assert_equal(0, paragraph.run_count)
	asserts(c"failure owns no partial output", (paragraph.byte_offsets == 0) && (paragraph.levels == 0) && (paragraph.runs == 0) && (paragraph.visual_runs == 0) && (paragraph.logical_to_visual == 0) && (paragraph.visual_to_logical == 0))
	ui_bidi_paragraph_free(paragraph)

void bidi_assert_invariants(ui_bidi_paragraph* paragraph):
	assert_equal(UI_BIDI_OK, paragraph.status)
	assert_equal(0, paragraph.byte_offsets[0])
	assert_equal(paragraph.source_bytes, paragraph.byte_offsets[paragraph.count])
	for i in range(paragraph.count):
		int logical = paragraph.visual_to_logical[i]
		asserts(c"map in range", (logical >= 0) && (logical < paragraph.count))
		assert_equal(i, paragraph.logical_to_visual[logical])
		asserts(c"scalar byte offsets advance", paragraph.byte_offsets[i] < paragraph.byte_offsets[i + 1])
	int offset = 0
	int scalar = 0
	for i in range(paragraph.run_count):
		ui_bidi_run* run = &paragraph.runs[i]
		assert_equal(offset, run.byte_start)
		assert_equal(scalar, run.scalar_start)
		asserts(c"nonempty run", (run.byte_length > 0) && (run.scalar_count > 0))
		assert_equal(UI_BIDI_LTR + (run.level & 1), run.direction)
		for j in range(run.scalar_start, run.scalar_start + run.scalar_count): assert_equal(run.level, paragraph.levels[j])
		offset = offset + run.byte_length
		scalar = scalar + run.scalar_count
		int visual = paragraph.visual_runs[i]
		asserts(c"visual run in range", (visual >= 0) && (visual < paragraph.run_count))
		for j in range(i): asserts(c"visual runs unique", visual != paragraph.visual_runs[j])
	assert_equal(paragraph.source_bytes, offset)
	assert_equal(paragraph.count, scalar)

void test_bidi_validation_and_unavailable():
	bidi_assert_failure(0, 1, UI_BIDI_AUTO, 10, UI_BIDI_INVALID)
	bidi_assert_failure(c"a", -1, UI_BIDI_AUTO, 10, UI_BIDI_INVALID)
	bidi_assert_failure(c"a", 1, 99, 10, UI_BIDI_INVALID)
	bidi_assert_failure(c"\xff", 1, UI_BIDI_AUTO, 10, UI_BIDI_INVALID)
	bidi_assert_failure(c"\xc0\x80", 2, UI_BIDI_AUTO, 10, UI_BIDI_INVALID)
	bidi_assert_failure(c"\xed\xa0\x80", 3, UI_BIDI_AUTO, 10, UI_BIDI_INVALID)
	bidi_assert_failure(c"\xf0\x9f\x98", 3, UI_BIDI_AUTO, 10, UI_BIDI_INVALID)
	bidi_assert_failure(c"a\nb", 3, UI_BIDI_AUTO, 10, UI_BIDI_INVALID)
	bidi_assert_failure(c"\xe2\x80\xa8", 3, UI_BIDI_AUTO, 10, UI_BIDI_INVALID)
	bidi_assert_failure(c"\xe2\x80\xa9", 3, UI_BIDI_AUTO, 10, UI_BIDI_INVALID)
	bidi_assert_failure(c"\xc2\x85", 2, UI_BIDI_AUTO, 10, UI_BIDI_INVALID)
	bidi_assert_failure(c"abc", 3, UI_BIDI_AUTO, 2, UI_BIDI_LIMIT)
	bidi_assert_failure(c"a", 65537, UI_BIDI_AUTO, 10, UI_BIDI_LIMIT)
	bidi_assert_failure(c"a", 1, UI_BIDI_AUTO, 65537, UI_BIDI_LIMIT)
	bidi_assert_failure(c"a", 1, UI_BIDI_AUTO, -1, UI_BIDI_LIMIT)
	int state = __ui_bidi_state
	__ui_bidi_state = -1
	bidi_assert_failure(c"a", 1, UI_BIDI_AUTO, 10, UI_BIDI_UNAVAILABLE)
	ui_bidi_paragraph* empty = ui_bidi_utf8(0, 0, UI_BIDI_RTL, 0)
	bidi_assert_invariants(empty)
	assert_equal(UI_BIDI_RTL, empty.direction)
	ui_bidi_paragraph_free(empty)
	__ui_bidi_state = state
	ui_bidi_paragraph_free(0)

void test_bidi_mixed_numbers_and_runs():
	if (!ui_bidi_available()):
		print(c"SKIP: FriBidi Linux x64 unavailable\n")
		return
	# abc ALEF BET 12: digits keep LTR order inside the RTL span.
	ui_bidi_paragraph* paragraph = ui_bidi_utf8(c"abc \xd7\x90\xd7\x91 12", 11, UI_BIDI_AUTO, 9)
	bidi_assert_invariants(paragraph)
	assert_equal(UI_BIDI_LTR, paragraph.direction)
	assert_equal(9, paragraph.count)
	assert_equal(3, paragraph.run_count)
	char* expected = c"\x00\x01\x02\x03\x07\x08\x06\x05\x04"
	for i in range(9): assert_equal(expected[i], paragraph.visual_to_logical[i])
	assert_equal(0, paragraph.visual_runs[0])
	assert_equal(2, paragraph.visual_runs[1])
	assert_equal(1, paragraph.visual_runs[2])
	assert_equal(4, paragraph.runs[1].byte_start)
	assert_equal(5, paragraph.runs[1].byte_length)
	assert_equal(1, paragraph.runs[1].level)
	assert_equal(2, paragraph.runs[2].level)
	ui_bidi_paragraph_free(paragraph)
	# Paired brackets resolve around Hebrew in an LTR paragraph.
	paragraph = ui_bidi_utf8(c"a (\xd7\x90\xd7\x91) z", 10, UI_BIDI_AUTO, 20)
	bidi_assert_invariants(paragraph)
	assert_equal(0, paragraph.levels[2])
	assert_equal(1, paragraph.levels[3])
	assert_equal(1, paragraph.levels[4])
	assert_equal(0, paragraph.levels[5])
	assert_equal(4, paragraph.visual_to_logical[3])
	assert_equal(3, paragraph.visual_to_logical[4])
	ui_bidi_paragraph_free(paragraph)

void test_bidi_isolates_overrides_and_whitespace():
	if (!ui_bidi_available()): return
	# a RLI ALEF BET PDI b. Controls retain logical indices.
	ui_bidi_paragraph* paragraph = ui_bidi_utf8(c"a\xe2\x81\xa7\xd7\x90\xd7\x91\xe2\x81\xa9b", 12, UI_BIDI_AUTO, 10)
	bidi_assert_invariants(paragraph)
	char* isolated = c"\x00\x01\x03\x02\x04\x05"
	for i in range(6): assert_equal(isolated[i], paragraph.visual_to_logical[i])
	assert_equal(1, paragraph.levels[2])
	assert_equal(0, paragraph.levels[4])
	ui_bidi_paragraph_free(paragraph)
	# RLO abc PDF: Latin is explicitly overridden RTL.
	paragraph = ui_bidi_utf8(c"\xe2\x80\xaeabc\xe2\x80\xac", 9, UI_BIDI_LTR, 10)
	bidi_assert_invariants(paragraph)
	assert_equal(1, paragraph.levels[1])
	assert_equal(1, paragraph.levels[2])
	assert_equal(1, paragraph.levels[3])
	asserts(c"override reverses Latin scalars", paragraph.logical_to_visual[1] > paragraph.logical_to_visual[3])
	ui_bidi_paragraph_free(paragraph)
	# Trailing whitespace resets to explicit RTL paragraph level (L1).
	paragraph = ui_bidi_utf8(c"abc  ", 5, UI_BIDI_RTL, 5)
	bidi_assert_invariants(paragraph)
	assert_equal(UI_BIDI_RTL, paragraph.direction)
	assert_equal(2, paragraph.levels[0])
	assert_equal(1, paragraph.levels[3])
	assert_equal(1, paragraph.levels[4])
	assert_equal(4, paragraph.visual_to_logical[0])
	assert_equal(3, paragraph.visual_to_logical[1])
	ui_bidi_paragraph_free(paragraph)
	paragraph = ui_bidi_utf8(c"\xd7\x90", 2, UI_BIDI_AUTO, 1)
	bidi_assert_invariants(paragraph)
	assert_equal(UI_BIDI_RTL, paragraph.direction)
	ui_bidi_paragraph_free(paragraph)

void test_bidi_nul_supplementary_and_limits():
	if (!ui_bidi_available()): return
	ui_bidi_paragraph* paragraph = ui_bidi_utf8(c"a\0\xf0\x9f\x98\x80", 6, UI_BIDI_AUTO, 3)
	bidi_assert_invariants(paragraph)
	assert_equal(3, paragraph.count)
	assert_equal(2, paragraph.byte_offsets[2])
	assert_equal(6, paragraph.byte_offsets[3])
	ui_bidi_paragraph_free(paragraph)
	char* large = cast(char*, malloc(65536))
	for i in range(65536): large[i] = 'a'
	paragraph = ui_bidi_utf8(large, 65536, UI_BIDI_AUTO, 65536)
	bidi_assert_invariants(paragraph)
	assert_equal(65536, paragraph.count)
	assert_equal(1, paragraph.run_count)
	ui_bidi_paragraph_free(paragraph)
	bidi_assert_failure(large, 65536, UI_BIDI_AUTO, 65535, UI_BIDI_LIMIT)
	free(large)

int bidi_native_failure(int* args):
	# Match the adapter trampoline's W signature, including undefined high bits
	# of the native signed-char result. A zero low byte means native failure.
	return args[2] * 256

void test_bidi_native_failure_discards_partial_arrays():
	if (!ui_bidi_available()): return
	for stage in range(2, 4):
		int native = __ui_bidi_functions[stage]
		__ui_bidi_functions[stage] = cast(int, bidi_native_failure)
		bidi_assert_failure(c"abc", 3, UI_BIDI_AUTO, 3, UI_BIDI_FAILED)
		__ui_bidi_functions[stage] = native

void test_bidi_shaping_uses_logical_slices_in_visual_run_order():
	if (!ui_bidi_available()): return
	if (!ui_shape_available()):
		print(c"SKIP: HarfBuzz bidi rendering integration unavailable\n")
		return
	# Hebrew ALEF + SHEVA, BET, space, Latin ab. Keep mark with its base.
	char* text = c"\xd7\x90\xd6\xb0\xd7\x91 ab"
	ui_bidi_paragraph* paragraph = ui_bidi_utf8(text, 9, UI_BIDI_AUTO, 10)
	bidi_assert_invariants(paragraph)
	assert_equal(2, paragraph.run_count)
	assert_equal(1, paragraph.visual_runs[0])
	assert_equal(0, paragraph.visual_runs[1])
	int face = ui_font_face_load_ttf(c"tools/ui/LiberationSans-Regular.ttf")
	asserts(c"loaded fixture face", face >= 0)
	int strike = ui_font_strike(face, 24)
	ui_renderer renderer
	ui_render_init_headless(&renderer)
	ui_render_begin(&renderer, 300, 100)
	int advance = 0
	for i in range(paragraph.run_count):
		ui_bidi_run* directional = &paragraph.runs[paragraph.visual_runs[i]]
		ui_shaped_run* shaped = ui_shape_utf8(text + directional.byte_start, directional.byte_length, strike, directional.direction, 0, 0, 30)
		assert_equal(UI_SHAPE_OK, shaped.status)
		assert_equal(directional.direction, shaped.direction)
		assert_equal(1, ui_draw_shaped_run(&renderer, cast(float32, advance) / 64.0, 10.0, shaped, ui_gray(1.0)))
		if (directional.direction == UI_BIDI_RTL):
			int cluster_zero = 0
			for j in range(shaped.count):
				asserts(c"cluster starts inside logical run", shaped.glyphs[j].cluster < directional.byte_length)
				if (shaped.glyphs[j].cluster == 0): cluster_zero = cluster_zero + 1
			assert_equal(2, cluster_zero)
		advance = advance + shaped.advance
		ui_shaped_run_free(shaped)
	asserts(c"shaped advance positive", advance > 0)
	asserts(c"headless renderer received glyphs", renderer.layer_vert_count[UI_LAYER_BASE] > 0)
	ui_render_destroy(&renderer)
	ui_bidi_paragraph_free(paragraph)
