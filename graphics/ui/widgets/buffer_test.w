# Unit tests for the multi-line text buffer: edits at every boundary,
# growth past the initial capacity, the line index, and offset <-> line/
# col round trips. Pure code (no GL or windowing), so it runs on the
# default 32-bit target, x64, and wasm alike.
# wbuild: name=graphics_ui_buffer_test x64 group=wasm_smoke_test@wasm
import lib.testing
import graphics.ui.widgets.buffer


# 1 when the buffer's text equals s.
int text_is(ui_text_buffer* b, char* s):
	if (b.length != strlen(s)):
		return 0
	return strcmp(b.data, s) == 0


void test_empty_buffer_is_one_empty_line():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	assert_equal(0, b.length)
	# One empty line, not zero lines: every caret position is on a line.
	assert_equal(1, b.line_count)
	assert_equal(0, ui_text_buffer_line_start(&b, 0))
	assert_equal(0, ui_text_buffer_line_length(&b, 0))
	assert_equal(0, ui_text_buffer_offset_to_line(&b, 0))
	ui_text_buffer_free(&b)


void test_set_and_line_index():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	ui_text_buffer_set(&b, c"alpha\nbeta\ngamma")
	assert_equal(16, b.length)
	assert_equal(3, b.line_count)
	assert_equal(0, ui_text_buffer_line_start(&b, 0))
	assert_equal(6, ui_text_buffer_line_start(&b, 1))
	assert_equal(11, ui_text_buffer_line_start(&b, 2))
	assert_equal(5, ui_text_buffer_line_length(&b, 0))
	assert_equal(4, ui_text_buffer_line_length(&b, 1))
	assert_equal(5, ui_text_buffer_line_length(&b, 2))
	ui_text_buffer_free(&b)


void test_trailing_newline_is_a_final_empty_line():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	ui_text_buffer_set(&b, c"one\ntwo\n")
	# What an editor shows: three lines, the last one empty.
	assert_equal(3, b.line_count)
	assert_equal(8, ui_text_buffer_line_start(&b, 2))
	assert_equal(0, ui_text_buffer_line_length(&b, 2))
	# A leading newline is a first empty line, symmetrically.
	ui_text_buffer_set(&b, c"\nx")
	assert_equal(2, b.line_count)
	assert_equal(0, ui_text_buffer_line_length(&b, 0))
	assert_equal(1, ui_text_buffer_line_length(&b, 1))
	ui_text_buffer_free(&b)


void test_insert_at_every_boundary():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	ui_text_buffer_set(&b, c"bc")
	# Front.
	ui_text_buffer_insert(&b, 0, 'a')
	assert_equal(1, text_is(&b, c"abc"))
	# Middle.
	ui_text_buffer_insert(&b, 2, 'X')
	assert_equal(1, text_is(&b, c"abXc"))
	# End.
	ui_text_buffer_insert(&b, 4, 'd')
	assert_equal(1, text_is(&b, c"abXcd"))
	# Past the end clamps rather than corrupting.
	ui_text_buffer_insert(&b, 999, '!')
	assert_equal(1, text_is(&b, c"abXcd!"))
	ui_text_buffer_insert(&b, 0 - 5, '^')
	assert_equal(1, text_is(&b, c"^abXcd!"))
	ui_text_buffer_free(&b)


void test_insert_newline_splits_a_line():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	ui_text_buffer_set(&b, c"abcd")
	assert_equal(1, b.line_count)
	ui_text_buffer_insert(&b, 2, '\n')
	assert_equal(2, b.line_count)
	assert_equal(2, ui_text_buffer_line_length(&b, 0))
	assert_equal(2, ui_text_buffer_line_length(&b, 1))
	assert_equal(3, ui_text_buffer_line_start(&b, 1))
	ui_text_buffer_free(&b)


void test_insert_text():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	ui_text_buffer_set(&b, c"ad")
	ui_text_buffer_insert_text(&b, 1, c"bc")
	assert_equal(1, text_is(&b, c"abcd"))
	# At the end.
	ui_text_buffer_insert_text(&b, 4, c"ef")
	assert_equal(1, text_is(&b, c"abcdef"))
	# At the front, and with newlines, which reindex.
	ui_text_buffer_insert_text(&b, 0, c"x\ny\n")
	assert_equal(1, text_is(&b, c"x\ny\nabcdef"))
	assert_equal(3, b.line_count)
	# Empty insert is a no-op.
	ui_text_buffer_insert_text(&b, 3, c"")
	assert_equal(1, text_is(&b, c"x\ny\nabcdef"))
	ui_text_buffer_free(&b)


void test_delete_at_every_boundary():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	ui_text_buffer_set(&b, c"abcdef")
	# Middle.
	ui_text_buffer_delete(&b, 2, 2)
	assert_equal(1, text_is(&b, c"abef"))
	# Front.
	ui_text_buffer_delete(&b, 0, 1)
	assert_equal(1, text_is(&b, c"bef"))
	# End.
	ui_text_buffer_delete(&b, 2, 1)
	assert_equal(1, text_is(&b, c"be"))
	# Past the end deletes what exists and stops.
	ui_text_buffer_delete(&b, 1, 100)
	assert_equal(1, text_is(&b, c"b"))
	# Zero and negative counts, and offsets past the end, do nothing.
	ui_text_buffer_delete(&b, 0, 0)
	ui_text_buffer_delete(&b, 0, 0 - 3)
	ui_text_buffer_delete(&b, 50, 1)
	assert_equal(1, text_is(&b, c"b"))
	# Down to empty, which is still one line.
	ui_text_buffer_delete(&b, 0, 1)
	assert_equal(0, b.length)
	assert_equal(1, b.line_count)
	ui_text_buffer_free(&b)


void test_delete_newline_joins_lines():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	ui_text_buffer_set(&b, c"ab\ncd")
	assert_equal(2, b.line_count)
	ui_text_buffer_delete(&b, 2, 1)
	assert_equal(1, b.line_count)
	assert_equal(1, text_is(&b, c"abcd"))
	assert_equal(4, ui_text_buffer_line_length(&b, 0))
	ui_text_buffer_free(&b)


void test_growth_past_initial_capacity():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	int start_cap = b.capacity
	int i = 0
	while (i < 500):
		ui_text_buffer_insert(&b, b.length, 'x')
		i = i + 1
	assert_equal(500, b.length)
	asserts(c"grew", b.capacity > start_cap)
	# Every byte survived the reallocs, and the NUL still terminates.
	i = 0
	while (i < 500):
		assert_equal('x', b.data[i])
		i = i + 1
	assert_equal(0, b.data[500])
	ui_text_buffer_free(&b)


void test_line_index_grows_too():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	int start_cap = b.line_capacity
	int i = 0
	while (i < 300):
		ui_text_buffer_insert(&b, b.length, '\n')
		i = i + 1
	# 300 newlines make 301 lines, the last one empty.
	assert_equal(301, b.line_count)
	asserts(c"line index grew", b.line_capacity > start_cap)
	assert_equal(150, ui_text_buffer_line_start(&b, 150))
	ui_text_buffer_free(&b)


void test_offset_to_line():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	ui_text_buffer_set(&b, c"alpha\nbeta\ngamma")
	assert_equal(0, ui_text_buffer_offset_to_line(&b, 0))
	assert_equal(0, ui_text_buffer_offset_to_line(&b, 5))
	# The newline byte belongs to the line it ends.
	assert_equal(1, ui_text_buffer_offset_to_line(&b, 6))
	assert_equal(1, ui_text_buffer_offset_to_line(&b, 10))
	assert_equal(2, ui_text_buffer_offset_to_line(&b, 11))
	assert_equal(2, ui_text_buffer_offset_to_line(&b, 16))
	# Out of range clamps to the ends.
	assert_equal(0, ui_text_buffer_offset_to_line(&b, 0 - 4))
	assert_equal(2, ui_text_buffer_offset_to_line(&b, 900))
	ui_text_buffer_free(&b)


void test_line_col_round_trips():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	ui_text_buffer_set(&b, c"alpha\nbeta\ngamma")
	int line = 0
	while (line < b.line_count):
		int col = 0
		while (col <= ui_text_buffer_line_length(&b, line)):
			int offset = ui_text_buffer_line_col_to_offset(&b, line, col)
			assert_equal(line, ui_text_buffer_offset_to_line(&b, offset))
			assert_equal(offset - ui_text_buffer_line_start(&b, line), col)
			col = col + 1
		line = line + 1

	# A column past a short line clamps to its end — the goal-column
	# behavior vertical caret motion depends on.
	assert_equal(ui_text_buffer_line_start(&b, 1) + 4, ui_text_buffer_line_col_to_offset(&b, 1, 99))
	# Out-of-range lines clamp too.
	assert_equal(0, ui_text_buffer_line_col_to_offset(&b, 0 - 2, 0))
	assert_equal(ui_text_buffer_line_start(&b, 2), ui_text_buffer_line_col_to_offset(&b, 50, 0))
	ui_text_buffer_free(&b)


void test_free_leaves_a_reusable_zeroed_struct():
	ui_text_buffer b
	ui_text_buffer_init(&b)
	ui_text_buffer_set(&b, c"content")
	ui_text_buffer_free(&b)
	assert_equal(0, b.length)
	assert_equal(0, b.capacity)
	assert_equal(0, b.line_count)
	# Freeing twice is safe...
	ui_text_buffer_free(&b)
	# ...and the struct can be initialized again.
	ui_text_buffer_init(&b)
	assert_equal(1, b.line_count)
	ui_text_buffer_set(&b, c"again")
	assert_equal(1, text_is(&b, c"again"))
	ui_text_buffer_free(&b)
