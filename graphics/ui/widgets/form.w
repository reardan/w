/*
graphics.ui.widgets.form: labelled rows and the validation-message
convention (docs/projects/ui_widgets.md §6, §10). A form is a region
with two columns — labels on the left, fields on the right — and a
submit button that refuses to fire while any field reports an error.

	ui_form_begin(ctx, &form, area, 96.0)
	ui_form_row(ctx, &form, c"Name")
	if (ui_textbox(ctx, ui_form_field_width(ctx, &form), &name)): ui_form_request_submit(&form)
	ui_form_error(ctx, &form, ui_form_required(&name, c"Name is required"))
	if (ui_form_submit(ctx, &form, c"Save")): save()
	ui_form_end(ctx, &form)

The convention is that a field's validity is the caller's to compute
and the form's to report: ui_form_error takes the message for the field
just issued, or 0 when it is valid. That keeps validators plain
functions over the caller's own state — ui_form_required here, an email
check in the Email widget — rather than callbacks the form has to hold.

Errors stay hidden until the first submit attempt, so a blank form does
not open covered in red. After that the form shows every failing field
on every frame, which is when feedback is wanted. Validity is counted
from the first frame regardless: a submit attempt on an invalid form is
refused on the frame it happens, and the messages appear from the next.

The form takes no widget id of its own. Its rows are layout, and the
only interactive part is the submit button, which takes the button's
id; showing or hiding the error rows therefore shifts no ids.
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context
import graphics.ui.widgets.basic
import graphics.ui.widgets.textbox


# Caller-owned form state. show_errors persists across frames; the
# counters are per-frame and reset by ui_form_begin.
struct ui_form_state:
	ui_rect area
	float32 label_w        # width of the label column
	int32 show_errors      # set by the first submit attempt
	int32 invalid          # fields that reported an error this frame
	int32 requested        # a submit asked for by the caller (return key)


void ui_form_init(ui_form_state* st):
	st.area = ui_rect_new(0.0, 0.0, 0.0, 0.0)
	st.label_w = 0.0
	st.show_errors = 0
	st.invalid = 0
	st.requested = 0


# Start a form inside area, with label_w pixels for the label column.
# Widgets issued up to ui_form_end place themselves inside area.
void ui_form_begin(ui_context* ctx, ui_form_state* st, ui_rect area, float32 label_w):
	st.area = area
	st.label_w = label_w
	st.invalid = 0
	ui_region_push(ctx, area)


void ui_form_end(ui_context* ctx, ui_form_state* st):
	st.requested = 0
	ui_region_pop(ctx)


# Left edge of the field column.
float32 ui_form_field_x(ui_context* ctx, ui_form_state* st):
	return st.area.x + st.label_w + cast(float32, ctx.theme.gap)


# Width a field needs to fill the field column.
float32 ui_form_field_width(ui_context* ctx, ui_form_state* st):
	return st.area.w - st.label_w - cast(float32, ctx.theme.gap)


# Start a row: draw label in the label column and leave the cursor so
# the next widget lands in the field column of the same row.
void ui_form_row(ui_context* ctx, ui_form_state* st, char* label):
	int scale = ctx.theme.text_scale
	ui_rect r = ui_layout_next(ctx, st.label_w, cast(float32, ctx.theme.widget_height))
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x, ty, label, scale, ui_text_color(ctx))
	ui_same_line(ctx)


# Report the validity of the field just issued: msg is its error, or 0
# when it is valid. Returns 1 when valid. While errors are showing, an
# invalid field gets an error-colored baseline over its own and the
# message on a row of its own beneath it, in the field column.
int ui_form_error(ui_context* ctx, ui_form_state* st, char* msg):
	if (msg == 0): return 1
	st.invalid = st.invalid + 1
	if (st.show_errors == 0): return 0
	ui_layout* lo = ui_layout_top(ctx)
	float32 gap = cast(float32, ctx.theme.gap)
	# The field was the last widget placed: it ends at last_right, and
	# its bottom is where the cursor now sits, less the row gap.
	float32 fx = ui_form_field_x(ctx, st)
	float32 bottom = lo.cursor_y - gap
	if (lo.last_right > fx + 8.0):
		ui_render_rect(ctx.rndr, ui_rect_new(fx + 4.0, bottom - 2.0, lo.last_right - fx - 8.0, 2.0), ctx.theme.error)
	int scale = ctx.theme.text_scale
	ui_rect r = ui_layout_next(ctx, st.label_w + gap + cast(float32, ui_text_width(msg, scale)), cast(float32, ui_text_height(scale)))
	ui_draw_text(ctx.rndr, fx, r.y, msg, scale, ctx.theme.error)
	return 0


# The stock validator: an empty text field is an error.
char* ui_form_required(ui_textbox_state* tb, char* msg):
	if (tb.length == 0):
		return msg
	return 0


# Ask for a submit from outside the button — typically because a
# field's ui_textbox returned its return-key edge. Resolved by the next
# ui_form_submit issued in this form this frame.
void ui_form_request_submit(ui_form_state* st):
	st.requested = 1


# The submit button, in the field column. Returns 1 on the frame it is
# clicked (or a submit was requested) and every field issued before it
# this frame was valid. Any attempt, valid or not, turns errors on.
int ui_form_submit(ui_context* ctx, ui_form_state* st, char* label):
	# An empty label-column slot, so the button lines up with the fields.
	ui_layout_next(ctx, st.label_w, cast(float32, ctx.theme.widget_height))
	ui_same_line(ctx)
	int attempt = ui_button(ctx, label)
	if (st.requested && (ctx.disabled == 0) && (ui_scope_blocked(ctx) == 0)): attempt = 1
	st.requested = 0
	if (attempt == 0): return 0
	st.show_errors = 1
	if (st.invalid > 0): return 0
	return 1
