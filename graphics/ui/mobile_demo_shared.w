# A responsive form shared by the browser driver and headless mobile tests.
# 48px controls and a scrolling page keep fields usable in a narrow viewport.
import graphics.ui.widgets


struct ui_mobile_demo_state:
	ui_theme theme
	ui_scroll_state page
	ui_textbox_state name
	ui_textbox_state email
	ui_textarea_state notes
	int32 updates
	int32 saved


void ui_mobile_demo_init(ui_mobile_demo_state* st):
	ui_theme_light(&st.theme)
	st.theme.widget_height = 48
	st.theme.gap = 12
	st.theme.pad = 12
	ui_scroll_init(&st.page)
	ui_textbox_init(&st.name)
	ui_textbox_init(&st.email)
	ui_textarea_init(&st.notes)
	st.updates = 0
	st.saved = 0


void ui_mobile_demo_body(ui_context* ctx, ui_mobile_demo_state* st):
	ui_rect bounds = ui_layout_top(ctx).bounds
	# Wide windows center the same readable form; phones use all the width.
	if (bounds.w > 560.0):
		bounds.x = bounds.x + (bounds.w - 560.0) * 0.5
		bounds.w = 560.0
	ui_scroll_begin(ctx, bounds, &st.page)
	float32 width = bounds.w - 12.0
	if (width < 48.0): width = 48.0
	ui_title(ctx, c"Your details")
	ui_label(ctx, c"Name")
	ui_textbox(ctx, width, &st.name)
	ui_label(ctx, c"Email")
	ui_textbox(ctx, width, &st.email)
	ui_label(ctx, c"Notes")
	ui_rect notes = ui_layout_next(ctx, width, 180.0)
	ui_textarea(ctx, notes, &st.notes)
	ui_checkbox(ctx, c"Send updates", &st.updates)
	if (ui_button(ctx, c"Save details")):
		st.saved = st.saved + 1
		print(c"mobile form saved\n")
	if (st.saved): ui_label(ctx, c"Form submitted")
	else: ui_label(ctx, c"Swipe to scroll")
	ui_scroll_end(ctx, &st.page)
