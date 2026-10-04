/*
graphics.ui.widgets.menubar: a window's menu bar — a strip of titles,
each opening a dropdown menu chain (graphics.ui.widgets.menu;
docs/projects/ui_widgets.md §12).

	ui_menubar_begin(ctx, &bar, ui_rect_new(0.0, 0.0, vw, 28.0))
	if (ui_menubar_menu(ctx, &bar, c"&File")):
		if (ui_menu_item_key(ctx, &bar.menu, c"&Save", GFX_MOD_CTRL, 's', dirty)): save()
		if (ui_menu_begin_sub(ctx, &bar.menu, c"Open &Recent", 1)):
			...
			ui_menu_end_sub(ctx, &bar.menu)
		ui_menubar_menu_end(ctx, &bar)
	if (ui_menubar_menu(ctx, &bar, c"&View")):
		ui_menu_check(ctx, &bar.menu, c"&Word Wrap", &wrap, 1)
		ui_menubar_menu_end(ctx, &bar)
	ui_menubar_end(ctx, &bar)

Every title shares the bar's one ui_menu_state, since only one of its
menus is ever open. ui_menubar_menu returns 1 while that title's menu
is open, and ALSO on a frame whose input holds a possible shortcut
chord while the bar is closed: the menu's items are then walked
without drawing, so a chord such as Ctrl+S reaches the item that
declares it even though nobody can see the menu. Either way, a 1 must
be paired with ui_menubar_menu_end.

Pressing a title opens its menu (on the press, as every desktop does,
so press-drag-release onto an item chooses it); pressing it again
closes it. While a menu is open, hovering another title switches to
it, and so do Left and Right. Alt plus a title's '&' mnemonic opens it
from the keyboard with the first item highlighted.

Issue the bar first in the frame. It reserves its ids up front, and
while one of its menus is open the menu owns the keyboard — a bar
issued after a focused editor would find the editor had already taken
the keys.
*/
import lib.lib
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.context
import graphics.ui.widgets.overlay
import graphics.ui.widgets.menu


# Titles a bar can hold.
const int ui_menubar_max_titles = 16


struct ui_menubar_state:
	ui_menu_state menu     # the open dropdown, shared by every title
	int32 open_index       # title whose menu is open, -1 = none
	int32 pending          # title to open next frame, -1 = none
	int32 pending_kb       # ... with the first item highlighted
	int32 walk             # titles issued so far this frame
	int32 count            # titles issued last frame
	int32 scan             # this frame walks closed menus for shortcuts
	int32 title_id         # base of the titles' ids
	float32 pen_x
	ui_rect rect
	int32[16] mnemonic     # each title's '&' letter, last frame


void ui_menubar_init(ui_menubar_state* bar):
	ui_menu_init(&bar.menu, 180.0)
	bar.menu.bar = 1
	bar.menu.anchored = 1
	bar.open_index = 0 - 1
	bar.pending = 0 - 1
	bar.pending_kb = 0
	bar.walk = 0
	bar.count = 0
	bar.scan = 0
	bar.title_id = 0
	bar.pen_x = 0.0
	bar.rect = ui_rect_new(0.0, 0.0, 0.0, 0.0)
	int i = 0
	while (i < ui_menubar_max_titles):
		bar.mnemonic[i] = 0
		i = i + 1


float32 ui_menubar_title_pad():
	return 10.0


# Start the bar in `rect`: draw the strip, reserve its ids, and take an
# Alt+mnemonic chord that opens one of its menus.
void ui_menubar_begin(ui_context* ctx, ui_menubar_state* bar, ui_rect rect):
	bar.rect = rect
	bar.menu.bar_rect = rect
	bar.walk = 0
	bar.pen_x = rect.x + 4.0
	bar.title_id = ctx.next_id
	ctx.next_id = ctx.next_id + ui_menubar_max_titles
	bar.menu.id = ctx.next_id
	ctx.next_id = ctx.next_id + ui_menu_id_block
	if (bar.menu.open == 0): bar.open_index = 0 - 1

	ui_render_rect(ctx.rndr, rect, ctx.theme.surface)
	ui_render_rect(ctx.rndr, ui_rect_new(rect.x, rect.y + rect.h - 1.0, rect.w, 1.0), ctx.theme.border)

	bar.scan = 0
	if ((ctx.disabled != 0) || ui_scope_blocked(ctx)): return
	if (bar.menu.open): return
	int i = 0
	while (i < ctx.char_count):
		int ch = ctx.chars[i]
		int mods = ctx.char_mods[i] & ui_shortcut_mod_mask
		if (mods == GFX_MOD_ALT):
			int t = 0
			while (t < bar.count):
				if ((bar.mnemonic[t] != 0) && (bar.mnemonic[t] == ui_menu_lower(ch))):
					bar.pending = t
					bar.pending_kb = 1
					ctx.chars[i] = 0
				t = t + 1
		i = i + 1
	bar.scan = ui_shortcut_pending(ctx)


# Point the shared menu at title i, fresh.
void ui_menubar_switch(ui_menubar_state* bar, int i, int highlight_first):
	ui_menu_reset(&bar.menu)
	bar.menu.open = 1
	bar.open_index = i
	if (highlight_first): bar.menu.hl[0] = 0 - 2


# One title. Returns 1 while its menu is open (or is being walked for
# shortcuts) — issue its items on &bar.menu and call
# ui_menubar_menu_end.
int ui_menubar_menu(ui_context* ctx, ui_menubar_state* bar, char* label):
	int i = bar.walk
	bar.walk = bar.walk + 1
	if (i < ui_menubar_max_titles): bar.mnemonic[i] = ui_menu_mnemonic(label)
	int id = bar.title_id + i
	if (i >= ui_menubar_max_titles): id = bar.title_id + ui_menubar_max_titles - 1

	float32 pad = ui_menubar_title_pad()
	int scale = ctx.theme.text_scale
	float32 tw = cast(float32, ui_menu_label_width(ctx, &bar.menu.scratch[0], label))
	ui_rect title = ui_rect_new(bar.pen_x, bar.rect.y + 2.0, tw + pad * 2.0, bar.rect.h - 4.0)
	bar.pen_x = bar.pen_x + title.w

	# While a menu is open the titles belong to its scope: they are how
	# the pointer moves between menus, so they must not go inert with
	# the rest of the page.
	int saved = ctx.scope
	if (bar.menu.open): ctx.scope = bar.menu.id
	int live = (ctx.disabled == 0) && (ui_scope_blocked(ctx) == 0)
	ctx.scope = saved
	if (live):
		float32 mx = cast(float32, ctx.input.mouse_x)
		float32 my = cast(float32, ctx.input.mouse_y)
		int over = ui_rect_contains(title, mx, my)
		if (over): ctx.hot = id
		if (ctx.input.mouse_pressed && ui_rect_contains(title, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
			ctx.active = id
			# Consumed: a press on the bar is not a press on whatever
			# focused field is behind it.
			ctx.input.mouse_pressed = 0
			if (bar.open_index == i):
				bar.menu.open = 0
				bar.pending = 0 - 1
			else:
				bar.pending = i
				bar.pending_kb = 0
		else if (over && (bar.open_index >= 0) && (bar.open_index != i)):
			bar.pending = i
			bar.pending_kb = 0

	int is_open = (bar.open_index == i) && bar.menu.open
	if (is_open): ui_draw_rrect(ctx.rndr, title, cast(float32, ctx.theme.radius_small), ctx.theme.widget_active)
	else if (ctx.hot == id): ui_draw_rrect(ctx.rndr, title, cast(float32, ctx.theme.radius_small), ctx.theme.widget_hot)
	ui_color ink = ctx.theme.text
	if (ctx.disabled): ink = ctx.theme.disabled_text
	float32 ty = title.y + (title.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_menu_draw_label(ctx, &bar.menu.scratch[0], title.x + pad, ty, label, ink)

	if (is_open):
		bar.menu.anchor = title
		bar.menu.anchored = 1
		return ui_menu_begin_reserved(ctx, &bar.menu)
	if (bar.scan && (bar.open_index < 0)):
		ui_menu_begin_scan(&bar.menu)
		return 1
	return 0


void ui_menubar_menu_end(ui_context* ctx, ui_menubar_state* bar):
	ui_menu_end(ctx, &bar.menu)


# Finish the bar: settle which menu is open for the next frame —
# a title pressed or hovered, Left/Right from inside the menu, or the
# menu closing itself.
void ui_menubar_end(ui_context* ctx, ui_menubar_state* bar):
	bar.count = bar.walk
	if (bar.count > ui_menubar_max_titles): bar.count = ui_menubar_max_titles
	if (bar.menu.open == 0):
		bar.open_index = 0 - 1
		# Nothing walked the chain this frame (it closed in its own begin,
		# or no title is open), so release its popup here.
		ui_popup_dismiss(ctx, bar.menu.id)
	if ((bar.open_index >= 0) && (bar.count > 0)):
		if (bar.menu.key_right): bar.pending = (bar.open_index + 1) % bar.count
		if (bar.menu.key_left): bar.pending = (bar.open_index + bar.count - 1) % bar.count
		if (bar.menu.key_right || bar.menu.key_left): bar.pending_kb = 1
	bar.menu.key_left = 0
	bar.menu.key_right = 0
	if ((bar.pending >= 0) && (bar.pending < bar.count)):
		int opener = bar.menu.opener
		int same_press = (bar.pending_kb == 0) && (ctx.active != 0) && (ctx.active >= bar.title_id) && (ctx.active < bar.title_id + ui_menubar_max_titles)
		ui_menubar_switch(bar, bar.pending, bar.pending_kb)
		# A title opened by the press still held keeps press-drag-release
		# working; one opened by hover inherits the original press.
		if (same_press): bar.menu.opener = ctx.active
		else: bar.menu.opener = opener
	bar.pending = 0 - 1
	bar.pending_kb = 0
