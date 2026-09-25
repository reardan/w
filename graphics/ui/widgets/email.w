/*
graphics.ui.widgets.email: a text field that knows what an email
address looks like (docs/projects/ui_widgets.md §6, §10). It is a
ui_textbox plus a validator on Form's convention, not a new editing
surface:

	ui_form_row(ctx, &form, c"Email")
	ui_email(ctx, ui_form_field_width(ctx, &form), &email)
	ui_form_error(ctx, &form, ui_email_check(&email, c"Not an email address"))

ui_email_check is the validator: it returns the message when the text
is not email-shaped and 0 when it is, exactly like ui_form_required, so
the form counts it and shows the message after a submit attempt. An
empty field is valid here — whether the field may be blank is
ui_form_required's question, and composing the two answers both.

The widget adds the inline state a form cannot give: once the user has
typed into the field and moved on (the textbox's `edited` reaching 2),
an invalid address turns the field's baseline to the error token, with
no submit needed. It stays live after that, so the baseline clears the
moment the address is fixed. The message itself is Form's to draw; a
standalone field shows the baseline only.

The shape rule is deliberately pragmatic rather than RFC 5322: one @,
a non-empty local part, a domain with a dot that is not at either end
and no empty labels, and no whitespace or control bytes anywhere.
Bytes above 0x7f pass, so internationalised addresses are not refused.
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context
import graphics.ui.widgets.textbox


# 1 when the NUL-terminated s is email-shaped, by the rule above. The
# empty string is not; ui_email_check makes that case valid.
int ui_email_valid(char* s):
	int at = 0 - 1
	int i = 0
	while (s[i] != 0):
		int c = s[i] & 255
		if (c <= 32):
			return 0
		if (c == 127):
			return 0
		if (c == '@'):
			if (at >= 0):
				return 0
			at = i
		i = i + 1
	int n = i
	if (at < 1):
		return 0
	int dom = at + 1
	if (dom >= n):
		return 0
	if ((s[dom] == '.') || (s[n - 1] == '.')):
		return 0
	int dots = 0
	i = dom
	while (i < n):
		if (s[i] == '.'):
			dots = dots + 1
			if (s[i + 1] == '.'):
				return 0
		i = i + 1
	if (dots == 0):
		return 0
	return 1


# The validator, on Form's convention: msg when the field holds text
# that is not an email address, 0 when it holds one or nothing.
char* ui_email_check(ui_textbox_state* tb, char* msg):
	if (tb.length == 0):
		return 0
	if (ui_email_valid(&tb.text[0])):
		return 0
	return msg


# 1 when ui_email draws its inline error for this state: the field has
# been edited and left, and what it holds is not an address.
int ui_email_showing_error(ui_textbox_state* tb):
	if (tb.edited != 2):
		return 0
	if (ui_email_check(tb, c"invalid") == 0):
		return 0
	return 1


# A textbox for an email address. Returns the textbox's submit edge
# (return typed while focused). Once edited and left with an invalid
# address, its baseline draws in the error token.
int ui_email(ui_context* ctx, float32 w, ui_textbox_state* st):
	int submitted = ui_textbox(ctx, w, st)
	if (ui_email_showing_error(st) && (ctx.disabled == 0)):
		# The textbox was the last widget placed: last_top and
		# last_right bound it, so the error baseline lands exactly over
		# its own.
		ui_layout* lo = ui_layout_top(ctx)
		float32 h = cast(float32, ctx.theme.widget_height)
		float32 x = lo.last_right - w
		ui_render_rect(ctx.rndr, ui_rect_new(x + 4.0, lo.last_top + h - 2.0, w - 8.0, 2.0), ctx.theme.error)
	return submitted
