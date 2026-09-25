# Headless unit tests for the form: two-column rows, errors hidden
# until the first submit attempt, submit refused while a field is
# invalid, and the return-key submit (docs/projects/ui_widgets.md §10).
# No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_form_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets


void setup(ui_renderer* r, ui_theme* theme, ui_context* ctx):
	ui_render_init_headless(r)
	ui_theme_light(theme)
	ui_context_init(ctx, r, theme)


void feed_click(ui_context* ctx, int x, int y):
	gfx_event press
	press.kind = GFX_EVENT_MOUSE_DOWN
	press.code = 1
	press.x = x
	press.y = y
	press.mods = 0
	ui_feed_event(ctx, &press)
	gfx_event release
	release.kind = GFX_EVENT_MOUSE_UP
	release.code = 1
	release.x = x
	release.y = y
	release.mods = 0
	ui_feed_event(ctx, &release)


void feed_char(ui_context* ctx, int code):
	gfx_event e
	e.kind = GFX_EVENT_CHAR
	e.code = code
	e.x = 0
	e.y = 0
	e.mods = 0
	ui_feed_event(ctx, &e)


# What one frame of the test form did, for the assertions.
struct form_frame:
	int32 submitted
	int32 name_valid
	float32 submit_top     # y of the submit button's row
	int32 ids_used


# One frame: a required Name field, then Save. The form area sits at
# (10, 10) with a 96px label column, so the field column starts at
# 10 + 96 + gap(8) = 114 and the first row spans y 10..42.
void run_frame(ui_context* ctx, ui_form_state* form, ui_textbox_state* name, form_frame* out):
	ui_begin(ctx, 320, 240)
	ui_form_begin(ctx, form, ui_rect_new(10.0, 10.0, 300.0, 220.0), 96.0)
	ui_form_row(ctx, form, c"Name")
	if (ui_textbox(ctx, ui_form_field_width(ctx, form), name)):
		ui_form_request_submit(form)
	out.name_valid = ui_form_error(ctx, form, ui_form_required(name, c"Name is required"))
	out.submitted = ui_form_submit(ctx, form, c"Save")
	out.submit_top = ui_layout_top(ctx).last_top
	ui_form_end(ctx, form)
	out.ids_used = ctx.next_id
	ui_end(ctx)


# The label takes the label column and the field lands beside it,
# filling the rest of the form's width.
void test_rows_are_two_columns():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_form_state form
	ui_form_init(&form)
	ui_textbox_state name
	ui_textbox_init(&name)
	form_frame f

	run_frame(&ctx, &form, &name, &f)
	asserts(c"field column starts after the labels", ui_form_field_x(&ctx, &form) == 114.0)
	asserts(c"field fills the rest of the width", ui_form_field_width(&ctx, &form) == 196.0)
	# One row of 32px plus the gap: the submit row is the second.
	asserts(c"submit sits on the second row", f.submit_top == 50.0)

	# A click in the field column focuses the field.
	feed_click(&ctx, 130, 26)
	run_frame(&ctx, &form, &name, &f)
	feed_char(&ctx, 'A')
	run_frame(&ctx, &form, &name, &f)
	assert_equal(1, name.length)
	ui_render_destroy(&r)


# A blank form opens clean: the field is invalid from the first frame,
# but nothing says so until the user tries to submit.
void test_errors_wait_for_the_first_attempt():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_form_state form
	ui_form_init(&form)
	ui_textbox_state name
	ui_textbox_init(&name)
	form_frame f

	run_frame(&ctx, &form, &name, &f)
	assert_equal(0, f.name_valid)
	assert_equal(1, form.invalid)
	assert_equal(0, form.show_errors)
	asserts(c"no error row yet", f.submit_top == 50.0)

	# Save is refused, and the refusal turns errors on.
	feed_click(&ctx, 130, 66)
	run_frame(&ctx, &form, &name, &f)
	assert_equal(0, f.submitted)
	assert_equal(1, form.show_errors)

	# From the next frame the message takes a row under the field,
	# pushing Save down.
	run_frame(&ctx, &form, &name, &f)
	asserts(c"the error row pushed submit down", f.submit_top > 50.0)
	ui_render_destroy(&r)


# Fixing the field clears its error and lets the submit through.
void test_submit_fires_once_the_form_is_valid():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_form_state form
	ui_form_init(&form)
	ui_textbox_state name
	ui_textbox_init(&name)
	form_frame f

	run_frame(&ctx, &form, &name, &f)
	feed_click(&ctx, 130, 66)
	run_frame(&ctx, &form, &name, &f)
	assert_equal(0, f.submitted)

	ui_textbox_set(&name, c"Ada")
	run_frame(&ctx, &form, &name, &f)
	assert_equal(1, f.name_valid)
	assert_equal(0, form.invalid)
	asserts(c"the error row is gone", f.submit_top == 50.0)

	feed_click(&ctx, 130, 66)
	run_frame(&ctx, &form, &name, &f)
	assert_equal(1, f.submitted)
	# The edge is one frame, like every other interactive widget.
	run_frame(&ctx, &form, &name, &f)
	assert_equal(0, f.submitted)
	ui_render_destroy(&r)


# Return in a field submits the form through ui_form_request_submit,
# under the same validity rule as the button.
void test_return_in_a_field_submits():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_form_state form
	ui_form_init(&form)
	ui_textbox_state name
	ui_textbox_init(&name)
	form_frame f

	feed_click(&ctx, 130, 26)
	run_frame(&ctx, &form, &name, &f)
	feed_char(&ctx, 13)
	run_frame(&ctx, &form, &name, &f)
	assert_equal(0, f.submitted)
	assert_equal(1, form.show_errors)

	feed_char(&ctx, 'B')
	feed_char(&ctx, 13)
	run_frame(&ctx, &form, &name, &f)
	assert_equal(1, f.submitted)
	assert_equal(0, form.requested)
	ui_render_destroy(&r)


# Showing the error rows is layout only: no widget ids move, so focus
# held by a field after the form survives errors appearing.
void test_error_rows_take_no_ids():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_form_state form
	ui_form_init(&form)
	ui_textbox_state name
	ui_textbox_init(&name)
	form_frame f

	run_frame(&ctx, &form, &name, &f)
	int before = f.ids_used
	form.show_errors = 1
	run_frame(&ctx, &form, &name, &f)
	assert_equal(before, f.ids_used)
	ui_render_destroy(&r)


# The error baseline and message draw in the theme's error token.
void test_every_theme_has_an_error_color():
	ui_theme theme
	ui_theme_light(&theme)
	asserts(c"light error is red", theme.error.r > theme.error.g)
	ui_theme_dark(&theme)
	asserts(c"dark error is red", theme.error.r > theme.error.g)
	ui_theme_ocean(&theme)
	asserts(c"ocean error is red", theme.error.r > theme.error.g)
