# Headless unit tests for the searchable dropdown: the matcher, the
# filter field living inside the popover (it takes focus and typed
# input there), picking by press and by return, and the ways it closes
# (docs/projects/ui_widgets.md §6, §9). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_dropdown_search_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets
import graphics.ui.testing


char** fruit():
	char** items = cast(char**, malloc(3 * __word_size__))
	items[0] = c"Apple"
	items[1] = c"Banana"
	items[2] = c"Cherry"
	return items


struct search_frame:
	int32 changed
	int32 ids_used
	int32 after_submit     # the textbox issued after the dropdown


# One frame: the dropdown at the first row (8, 8, 160, 32), then an
# unrelated textbox. Open, the surface spans y 44..196; inside its 8px
# pad the filter is (16, 52, 144, 32) and the matching rows follow at
# y 92..124, 124..156 and 156..188.
void run_frame(ui_context* ctx, char** items, int32* selected, int32* open, ui_textbox_state* query, ui_textbox_state* other, search_frame* out):
	ui_begin(ctx, 320, 240)
	out.changed = ui_dropdown_search(ctx, 160.0, items, 3, selected, open, query)
	out.ids_used = ctx.next_id
	out.after_submit = ui_textbox(ctx, 120.0, other)
	ui_end(ctx)


void test_matching_is_a_case_insensitive_substring():
	asserts(c"empty matches all", ui_dropdown_matches(c"Apple", c""))
	asserts(c"prefix", ui_dropdown_matches(c"Apple", c"ap"))
	asserts(c"middle", ui_dropdown_matches(c"Banana", c"NAN"))
	asserts(c"suffix", ui_dropdown_matches(c"Cherry", c"rry"))
	asserts(c"whole", ui_dropdown_matches(c"Cherry", c"cherry"))
	assert_equal(0, ui_dropdown_matches(c"Apple", c"x"))
	assert_equal(0, ui_dropdown_matches(c"Apple", c"apples"))
	assert_equal(0, ui_dropdown_matches(c"", c"a"))
	# Retrying after a partial match: "nana" is found after "na" first
	# fails to extend at index 2.
	asserts(c"overlapping retry", ui_dropdown_matches(c"bananas", c"nanas"))

	char** items = fruit()
	assert_equal(1, ui_dropdown_first_match(items, 3, c"an"))
	assert_equal(0, ui_dropdown_first_match(items, 3, c""))
	assert_equal(0 - 1, ui_dropdown_first_match(items, 3, c"zz"))


# Opening focuses the filter, which sits inside the popover's scope, and
# typing there reaches it: the whole reason the widget needs nesting.
void test_the_filter_inside_the_popover_takes_input():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	char** items = fruit()
	int32 selected = 0
	int32 open = 0
	ui_textbox_state query
	ui_textbox_init(&query)
	ui_textbox_set(&query, c"stale")
	ui_textbox_state other
	ui_textbox_init(&other)
	search_frame f

	ui_test_click(ctx, 20, 20)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	assert_equal(1, open)
	assert_equal(1, ctx.popup_depth)
	assert_equal(2, ctx.focus)
	assert_equal(0, query.length)
	asserts(c"drew on the popup layer", fx.r.layer_vert_count[UI_LAYER_POPUP] > 0)

	ui_test_text(ctx, c"ch")
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	asserts(c"typed into the filter", strcmp(&query.text[0], c"ch") == 0)
	assert_equal(0, other.length)
	assert_equal(1, open)

	# Clicking the filter itself keeps the list open and the focus.
	ui_test_click(ctx, 60, 68)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	assert_equal(1, open)
	assert_equal(2, ctx.focus)
	ui_render_destroy(&fx.r)


# Pressing a filtered row picks it — the first row is the first match,
# not the first item — and closes, releasing the filter's focus.
void test_pressing_a_match_picks_and_closes():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	char** items = fruit()
	int32 selected = 0
	int32 open = 0
	ui_textbox_state query
	ui_textbox_init(&query)
	ui_textbox_state other
	ui_textbox_init(&other)
	search_frame f

	ui_test_click(ctx, 20, 20)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	ui_test_text(ctx, c"rr")
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	ui_test_click(ctx, 40, 100)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	assert_equal(1, f.changed)
	assert_equal(2, selected)
	assert_equal(0, open)
	assert_equal(0, ctx.popup_depth)
	assert_equal(0, ctx.focus)

	# Typing now goes nowhere: the textbox after the dropdown did not
	# inherit the filter's focus.
	ui_test_text(ctx, c"x")
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	assert_equal(0, other.length)
	assert_equal(0, f.changed)
	ui_render_destroy(&fx.r)


# Return in the filter picks the first match.
void test_return_picks_the_first_match():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	char** items = fruit()
	int32 selected = 0
	int32 open = 0
	ui_textbox_state query
	ui_textbox_init(&query)
	ui_textbox_state other
	ui_textbox_init(&other)
	search_frame f

	ui_test_click(ctx, 20, 20)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	ui_test_text(ctx, c"AN")
	ui_test_char(ctx, 13)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	assert_equal(1, f.changed)
	assert_equal(1, selected)
	assert_equal(0, open)
	assert_equal(0, f.after_submit)
	ui_render_destroy(&fx.r)


# Return with nothing matching picks nothing and leaves the list open.
void test_return_with_no_match_keeps_it_open():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	char** items = fruit()
	int32 selected = 1
	int32 open = 0
	ui_textbox_state query
	ui_textbox_init(&query)
	ui_textbox_state other
	ui_textbox_init(&other)
	search_frame f

	ui_test_click(ctx, 20, 20)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	ui_test_text(ctx, c"zz")
	ui_test_char(ctx, 13)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	assert_equal(0, f.changed)
	assert_equal(1, selected)
	assert_equal(1, open)

	# Picking the already-selected item closes without a change edge.
	ui_test_char(ctx, 8)
	ui_test_char(ctx, 8)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	ui_test_click(ctx, 40, 140)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	assert_equal(0, f.changed)
	assert_equal(1, selected)
	assert_equal(0, open)
	ui_render_destroy(&fx.r)


# A press outside and escape both close without a change, releasing
# the filter's focus; reopening starts from an empty query.
void test_closing_without_a_pick():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	char** items = fruit()
	int32 selected = 0
	int32 open = 0
	ui_textbox_state query
	ui_textbox_init(&query)
	ui_textbox_state other
	ui_textbox_init(&other)
	search_frame f

	ui_test_click(ctx, 20, 20)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	ui_test_text(ctx, c"b")
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	ui_test_click(ctx, 300, 220)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	assert_equal(0, open)
	assert_equal(0, f.changed)
	assert_equal(0, ctx.focus)
	assert_equal(0, ctx.popup_depth)

	ui_test_click(ctx, 20, 20)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	assert_equal(1, open)
	assert_equal(0, query.length)
	ui_test_char(ctx, 27)
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	assert_equal(0, open)
	assert_equal(0, ctx.focus)
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&fx.r)


# The dropdown takes two ids open or closed, and leaves the scope,
# layer and layout depth where it found them.
void test_ids_and_bracket_are_stable():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	char** items = fruit()
	int32 selected = 0
	int32 open = 0
	ui_textbox_state query
	ui_textbox_init(&query)
	ui_textbox_state other
	ui_textbox_init(&other)
	search_frame f

	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	assert_equal(3, f.ids_used)
	open = 1
	run_frame(ctx, items, &selected, &open, &query, &other, &f)
	assert_equal(3, f.ids_used)
	assert_equal(1, ctx.layout_depth)
	assert_equal(0, ctx.scope)
	assert_equal(0, ctx.bracket_depth)
	assert_equal(UI_LAYER_BASE, fx.r.layer)
	ui_render_destroy(&fx.r)
