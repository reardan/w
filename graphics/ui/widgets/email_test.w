# Headless unit tests for the email field: the shape validator on its
# own, its Form-convention wrapper, the touched state that gates the
# inline error, and the field inside a Form
# (docs/projects/ui_widgets.md §6, §10). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_email_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets
import graphics.ui.testing


# One frame holding just the email field at the first row (8, 8, 200,
# 32). Returns its submit edge.
int email_frame(ui_context* ctx, ui_textbox_state* st):
	ui_begin(ctx, 320, 240)
	int submitted = ui_email(ctx, 200.0, st)
	ui_end(ctx)
	return submitted


# Base-layer vertices one frame of ui_email emits, less those a plain
# ui_textbox over the same state emits: the inline error's geometry.
int error_verts(ui_renderer* r, ui_context* ctx, ui_textbox_state* st):
	ui_begin(ctx, 320, 240)
	ui_textbox(ctx, 200.0, st)
	int plain = r.layer_vert_count[UI_LAYER_BASE]
	ui_end(ctx)
	ui_begin(ctx, 320, 240)
	ui_email(ctx, 200.0, st)
	int with_email = r.layer_vert_count[UI_LAYER_BASE]
	ui_end(ctx)
	return with_email - plain


void test_valid_addresses():
	asserts(c"simple", ui_email_valid(c"a@b.co"))
	asserts(c"dotted local part", ui_email_valid(c"first.last@example.com"))
	asserts(c"plus tag and subdomain", ui_email_valid(c"x+tag@mail.sub.example.org"))
	asserts(c"digits and hyphens", ui_email_valid(c"user-1@my-host.io"))
	asserts(c"utf-8 bytes pass", ui_email_valid(c"j\xc3\xbcrgen@m\xc3\xbcnchen.de"))


void test_invalid_addresses():
	assert_equal(0, ui_email_valid(c""))
	assert_equal(0, ui_email_valid(c"plainaddress"))
	assert_equal(0, ui_email_valid(c"@example.com"))
	assert_equal(0, ui_email_valid(c"user@"))
	assert_equal(0, ui_email_valid(c"user@localhost"))
	assert_equal(0, ui_email_valid(c"user@.example.com"))
	assert_equal(0, ui_email_valid(c"user@example.com."))
	assert_equal(0, ui_email_valid(c"user@example..com"))
	assert_equal(0, ui_email_valid(c"user@@example.com"))
	assert_equal(0, ui_email_valid(c"a@b@example.com"))
	assert_equal(0, ui_email_valid(c"first last@example.com"))
	assert_equal(0, ui_email_valid(c"user@example.com "))
	assert_equal(0, ui_email_valid(c"user@exa\tmple.com"))
	assert_equal(0, ui_email_valid(c"user@exa\x7fmple.com"))


# Form's convention: the message when invalid, 0 when valid — and empty
# is valid, so the check composes with ui_form_required.
void test_check_follows_the_form_convention():
	ui_textbox_state tb
	ui_textbox_init(&tb)
	char* msg = c"Not an email address"
	asserts(c"empty is valid", ui_email_check(&tb, msg) == 0)
	asserts(c"but required still refuses it", ui_form_required(&tb, msg) == msg)
	ui_textbox_set(&tb, c"nope")
	asserts(c"invalid returns the message", ui_email_check(&tb, msg) == msg)
	ui_textbox_set(&tb, c"ada@example.com")
	asserts(c"valid returns 0", ui_email_check(&tb, msg) == 0)


# A prefilled bad value is not the user's mistake: no inline error
# until they have edited the field and left it.
void test_error_waits_for_edit_and_blur():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"nope")

	email_frame(ctx, &st)
	assert_equal(0, st.edited)
	assert_equal(0, ui_email_showing_error(&st))
	assert_equal(0, error_verts(&fx.r, ctx, &st))

	# Focus and type: edited, but still focused, so no error yet.
	ui_test_click(ctx, 100, 20)
	email_frame(ctx, &st)
	asserts(c"focused", ctx.focus != 0)
	ui_test_text(ctx, c"x")
	email_frame(ctx, &st)
	assert_equal(1, st.edited)
	assert_equal(0, ui_email_showing_error(&st))

	# A press elsewhere drops focus: now touched, and invalid shows.
	ui_test_click(ctx, 300, 200)
	email_frame(ctx, &st)
	assert_equal(0, ctx.focus)
	assert_equal(2, st.edited)
	assert_equal(1, ui_email_showing_error(&st))
	asserts(c"the error baseline drew", error_verts(&fx.r, ctx, &st) > 0)
	ui_render_destroy(&fx.r)


# Once touched the error is live: it clears as soon as the address is
# fixed, without another blur.
void test_error_clears_live_when_fixed():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)

	ui_test_click(ctx, 100, 20)
	email_frame(ctx, &st)
	ui_test_text(ctx, c"ada")
	email_frame(ctx, &st)
	# Escape also leaves the field, and that counts as a blur.
	ui_test_char(ctx, 27)
	email_frame(ctx, &st)
	assert_equal(0, ctx.focus)
	assert_equal(1, ui_email_showing_error(&st))

	ui_test_click(ctx, 190, 20)
	email_frame(ctx, &st)
	ui_test_text(ctx, c"@example.com")
	email_frame(ctx, &st)
	asserts(c"still focused", ctx.focus != 0)
	asserts(c"typed", strcmp(&st.text[0], c"ada@example.com") == 0)
	assert_equal(0, ui_email_showing_error(&st))
	assert_equal(0, error_verts(&fx.r, ctx, &st))
	ui_render_destroy(&fx.r)


# Clearing a touched field is not an email error: blank is Form's
# required rule to judge.
void test_a_cleared_field_shows_no_error():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)

	ui_test_click(ctx, 100, 20)
	email_frame(ctx, &st)
	ui_test_text(ctx, c"q")
	ui_test_char(ctx, 8)
	email_frame(ctx, &st)
	ui_test_click(ctx, 300, 200)
	email_frame(ctx, &st)
	assert_equal(2, st.edited)
	assert_equal(0, st.length)
	assert_equal(0, ui_email_showing_error(&st))
	ui_render_destroy(&fx.r)


# Return is the textbox's submit edge, passed straight through, valid
# or not — refusing it is the form's job.
void test_return_is_the_submit_edge():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)

	ui_test_click(ctx, 100, 20)
	email_frame(ctx, &st)
	ui_test_text(ctx, c"bad")
	ui_test_char(ctx, 13)
	assert_equal(1, email_frame(ctx, &st))
	assert_equal(0, email_frame(ctx, &st))
	ui_render_destroy(&fx.r)


# A disabled email field is inert and draws no error.
void test_disabled_field_draws_no_error():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"bad")
	st.edited = 2

	ui_begin(ctx, 320, 240)
	ui_disable(ctx, 1)
	ui_textbox(ctx, 200.0, &st)
	int plain = fx.r.layer_vert_count[UI_LAYER_BASE]
	ui_end(ctx)
	ui_begin(ctx, 320, 240)
	ui_email(ctx, 200.0, &st)
	int with_email = fx.r.layer_vert_count[UI_LAYER_BASE]
	ui_disable(ctx, 0)
	ui_end(ctx)
	assert_equal(plain, with_email)
	ui_render_destroy(&fx.r)


# What one frame of the test form did.
struct form_frame:
	int32 submitted
	int32 email_valid


# A required Email row, then Save. Area at (10, 10) with a 96px label
# column: the field spans x 114..310 on the row y 10..42, and Save sits
# on the next row (y 50..82) until an error row pushes it down.
void form_frame_run(ui_context* ctx, ui_form_state* form, ui_textbox_state* email, int required, form_frame* out):
	ui_begin(ctx, 320, 240)
	ui_form_begin(ctx, form, ui_rect_new(10.0, 10.0, 300.0, 220.0), 96.0)
	ui_form_row(ctx, form, c"Email")
	if (ui_email(ctx, ui_form_field_width(ctx, form), email)):
		ui_form_request_submit(form)
	char* err = ui_email_check(email, c"Not an email address")
	if (required):
		char* missing = ui_form_required(email, c"Email is required")
		if (missing != 0):
			err = missing
	out.email_valid = ui_form_error(ctx, form, err)
	out.submitted = ui_form_submit(ctx, form, c"Save")
	ui_form_end(ctx, form)
	ui_end(ctx)


# An optional email field: blank submits, a bad address is refused, a
# good one goes through.
void test_inside_a_form():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_form_state form
	ui_form_init(&form)
	ui_textbox_state email
	ui_textbox_init(&email)
	form_frame f

	form_frame_run(ctx, &form, &email, 0, &f)
	assert_equal(1, f.email_valid)
	ui_test_click(ctx, 130, 66)
	form_frame_run(ctx, &form, &email, 0, &f)
	assert_equal(1, f.submitted)

	# Type a bad address and press return in the field: refused.
	ui_test_click(ctx, 130, 26)
	form_frame_run(ctx, &form, &email, 0, &f)
	ui_test_text(ctx, c"ada@")
	ui_test_char(ctx, 13)
	form_frame_run(ctx, &form, &email, 0, &f)
	assert_equal(0, f.submitted)
	assert_equal(0, f.email_valid)
	assert_equal(1, form.invalid)

	# Finish the address; return now submits.
	ui_test_text(ctx, c"example.com")
	ui_test_char(ctx, 13)
	form_frame_run(ctx, &form, &email, 0, &f)
	assert_equal(1, f.email_valid)
	assert_equal(1, f.submitted)
	ui_render_destroy(&fx.r)


# Composed with ui_form_required, blank is refused too.
void test_required_email_in_a_form():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_form_state form
	ui_form_init(&form)
	ui_textbox_state email
	ui_textbox_init(&email)
	form_frame f

	form_frame_run(ctx, &form, &email, 1, &f)
	assert_equal(0, f.email_valid)
	ui_test_click(ctx, 130, 66)
	form_frame_run(ctx, &form, &email, 1, &f)
	assert_equal(0, f.submitted)
	assert_equal(1, form.show_errors)

	ui_textbox_set(&email, c"ada@example.com")
	form_frame_run(ctx, &form, &email, 1, &f)
	assert_equal(1, f.email_valid)
	assert_equal(0, form.invalid)
	ui_render_destroy(&fx.r)
