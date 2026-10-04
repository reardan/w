/*
graphics.ui.widgets.menu: menus — the context menu, the dropdowns a
menu bar opens (graphics.ui.widgets.menubar), nested submenus, check
and radio items, keyboard navigation and shortcuts
(docs/projects/ui_widgets.md §12).

	ui_menu_open_on_right_click(ctx, sidebar, &menu)
	if (ui_menu_begin(ctx, &menu)):
		if (ui_menu_item_key(ctx, &menu, c"&New File", GFX_MOD_CTRL, 'n', 1)): new_file()
		if (ui_menu_item(ctx, &menu, c"&Rename", has_selection)): rename()
		if (ui_menu_begin_sub(ctx, &menu, c"Sort &By", 1)):
			ui_menu_radio(ctx, &menu, c"Name", &sort, 0, 1)
			ui_menu_radio(ctx, &menu, c"Date", &sort, 1, 1)
			ui_menu_end_sub(ctx, &menu)
		ui_menu_check(ctx, &menu, c"Show &Hidden", &show_hidden, 1)
		ui_menu_separator(ctx, &menu)
		if (ui_menu_item(ctx, &menu, c"&Delete", has_selection)): delete()
		ui_menu_end(ctx, &menu)

One ui_menu_state is a whole menu CHAIN: the root menu and whichever
submenus hang open off it, up to ui_menu_max_levels deep. Every level
of a chain takes input at once — the pointer moves freely from a
submenu back to its parent — so the chain registers a single popup id
for all of them instead of one per level (one per level would make
each parent inert the moment its submenu opened).

Each level draws in its own popup bracket. A submenu is issued in the
middle of its parent's walk, and the clip stack intersects, so the
parent's bracket is closed while the submenu draws and re-entered
after it — otherwise the submenu, which sits beside its parent, would
be clipped to the parent's surface.

Items are a walk, so a level's size is whatever the caller issues —
but the surface has to be placed before the walk. So each level sizes
from the PREVIOUS frame's walk (height, width, which items are
selectable) and the first frame of a newly-opened level measures
before it settles. That is invisible in practice: a menu opens at its
top-left corner and only the bottom and right edges move.

The chain reserves a fixed block of widget ids every frame whether it
is open or not, so opening a menu never shifts the ids of widgets
issued after it (which would cost a focused text field its focus).

Labels may mark a mnemonic with '&' ("&Save" underlines S); "&&" is a
literal ampersand. With the menu open, typing a mnemonic chooses its
item; typing any other letter moves the highlight to the next item
starting with it. The keyboard otherwise works as everywhere: Up/Down
(Home/End) move, Right or Return opens a submenu, Left or Escape
closes one level, Return or Space chooses.

Shortcuts (ui_shortcut, and the *_key item forms) match a CHAR event
plus modifier bits. Ctrl+letter arrives as the letter itself on the web
host and as its control code (1..26) from the native backends; both
match.
*/
import lib.lib
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context
import graphics.ui.widgets.overlay
import graphics.ui.widgets.popover


float32 ui_menu_item_height():
	return 26.0


float32 ui_menu_separator_height():
	return 9.0


# The column check and radio marks sit in, reserved on a level only
# when one of its items is checkable.
float32 ui_menu_gutter():
	return 18.0


# Root menu plus nested submenus.
const int ui_menu_max_levels = 4

# Widget ids a chain reserves every frame; items past it share the last.
const int ui_menu_id_block = 256

# Items per level the keyboard can reach (selectability is a bitmask).
const int ui_menu_kb_items = 32

# The modifier bits a shortcut compares.
const int ui_shortcut_mod_mask = 15


enum ui_menu_kind:
	UI_MENU_PLAIN = 0
	UI_MENU_CHECK = 1
	UI_MENU_RADIO = 2
	UI_MENU_SUB = 3


struct ui_menu_state:
	int32 open
	float32 at_x           # where a context menu was pinned, viewport space
	float32 at_y
	float32 w              # minimum width of every level
	int32 walk_index       # items issued so far on the level being walked
	int32 chosen           # index (on its level) of the item chosen this frame, -1 = none
	float32 height         # the root level's previous-frame height
	float32 pen_y          # the pen on the level being walked
	int32 id               # the chain's popup id, base of its id block
	# Placement of the root level: below a rect (a menu bar title) when
	# anchored, otherwise at the pin.
	int32 anchored
	ui_rect anchor
	# Set by a menu bar: a press on the bar is not an outside press.
	int32 bar
	ui_rect bar_rect
	# The widget whose press opened the chain (a bar title); releasing
	# that press over an item chooses it, so press-drag-release works.
	int32 opener
	# Per-frame walk state.
	int32 level            # level being issued
	int32 scanning         # walking closed, matching shortcuts only
	int32 next_item
	int32 moved            # the pointer moved since last frame
	int32 last_mx
	int32 last_my
	# Keyboard.
	int32 kb_level         # level the keyboard acts on
	int32 act_level        # pending keyboard activation, -1 = none
	int32 act_index
	int32 type_level       # pending typeahead letter and its level
	int32 type_char
	int32 type_after       # matches found by this frame's walk
	int32 type_first
	int32 type_mnemonic
	int32 type_mnemonic_count
	# Left/Right the chain could not use itself, for a menu bar to move
	# between its menus with.
	int32 key_left
	int32 key_right
	# Per level. hl is the highlighted item (-1 none, -2 "the first
	# selectable one, once walked"); sub the item whose submenu is open.
	int32[4] hl
	int32[4] sub
	int32[4] index
	int32[4] count         # last frame's walk
	int32[4] selectable
	int32[4] submask
	int32[4] marks
	int32[4] sel_now       # this frame's, becoming the above at level end
	int32[4] sub_now
	int32[4] marks_now
	int32[4] live          # the level drew a surface this frame
	int32[4] live_prev
	float32[4] pen
	float32[4] lw          # measured width, last frame
	float32[4] lw_now
	float32[4] lh          # measured height, last frame
	ui_rect[4] surface
	ui_rect[4] surface_prev
	char[96] scratch       # a label with its '&' markers removed
	char[32] keytext       # a formatted shortcut


# Forget everything about the chain's levels: what is highlighted,
# what is open, what the last walk measured.
void ui_menu_reset_levels(ui_menu_state* st, int from):
	int k = from
	while (k < ui_menu_max_levels):
		st.hl[k] = 0 - 1
		st.sub[k] = 0 - 1
		st.count[k] = 0
		st.selectable[k] = 0
		st.submask[k] = 0
		st.marks[k] = 0
		st.live_prev[k] = 0
		st.lw[k] = 0.0
		st.lh[k] = 0.0
		k = k + 1


void ui_menu_reset(ui_menu_state* st):
	ui_menu_reset_levels(st, 0)
	st.kb_level = 0
	st.act_level = 0 - 1
	st.act_index = 0
	st.type_char = 0
	st.opener = 0


void ui_menu_init(ui_menu_state* st, float32 w):
	st.open = 0
	st.at_x = 0.0
	st.at_y = 0.0
	st.w = w
	st.walk_index = 0
	st.chosen = 0 - 1
	st.height = ui_menu_item_height()
	st.pen_y = 0.0
	st.id = 0
	st.anchored = 0
	st.anchor = ui_rect_new(0.0, 0.0, 0.0, 0.0)
	st.bar = 0
	st.bar_rect = ui_rect_new(0.0, 0.0, 0.0, 0.0)
	st.level = 0
	st.scanning = 0
	st.next_item = 0
	st.moved = 0
	st.last_mx = 0 - 1
	st.last_my = 0 - 1
	st.type_level = 0
	st.key_left = 0
	st.key_right = 0
	ui_menu_reset(st)


# Open the chain pinned at a point: a context menu opened from code,
# or from the keyboard. highlight_first puts the keyboard on the first
# item, as opening from a key should.
void ui_menu_open_at(ui_menu_state* st, float32 x, float32 y, int highlight_first):
	ui_menu_reset(st)
	st.open = 1
	st.at_x = x
	st.at_y = y
	st.anchored = 0
	if (highlight_first): st.hl[0] = 0 - 2


# Close the chain. It unregisters on its next ui_menu_begin.
void ui_menu_close(ui_menu_state* st):
	st.open = 0
	ui_menu_reset(st)


# Pin the menu at the pointer when a right-click lands inside `area`.
# The edge is consumed, so two overlapping areas cannot both open one.
# Returns 1 on the frame the menu opens.
int ui_menu_open_on_right_click(ui_context* ctx, ui_rect area, ui_menu_state* st):
	if (ctx.input.mouse_right_pressed == 0): return 0
	if (ctx.disabled): return 0
	if (ui_scope_blocked(ctx)): return 0
	float32 px = cast(float32, ctx.input.right_x)
	float32 py = cast(float32, ctx.input.right_y)
	if (ui_rect_contains(area, px, py) == 0): return 0
	ctx.input.mouse_right_pressed = 0
	ui_menu_open_at(st, px, py, 0)
	st.walk_index = 0
	st.chosen = 0 - 1
	return 1


# ---- shortcuts ---------------------------------------------------------

int ui_menu_lower(int ch):
	if ((ch >= 'A') && (ch <= 'Z')): return ch + 32
	return ch


# 1 when one CHAR event (code, mods) is the chord mods+key. Letters
# compare case-insensitively (Shift is a modifier bit, not a case), and
# Ctrl+letter also matches its control code, which is how the native
# backends deliver it.
int ui_shortcut_matches(int code, int code_mods, int mods, int key):
	if ((code_mods & ui_shortcut_mod_mask) != (mods & ui_shortcut_mod_mask)): return 0
	int k = ui_menu_lower(key)
	if (ui_menu_lower(code) == k): return 1
	if ((mods & GFX_MOD_CTRL) && (k >= 'a') && (k <= 'z') && (code == k - 96)): return 1
	return 0


# A CHAR that could be a shortcut chord: anything with Ctrl, Alt or
# Super held, or a bare control code. A menu bar only walks its closed
# menus for shortcuts on frames that have one.
int ui_shortcut_candidate(int code, int code_mods):
	if (code_mods & (GFX_MOD_CTRL | GFX_MOD_ALT | GFX_MOD_SUPER)): return 1
	return (code >= 1) && (code <= 26) && (code != 8) && (code != 9) && (code != 13)


int ui_shortcut_pending(ui_context* ctx):
	int i = 0
	while (i < ctx.char_count):
		if (ui_shortcut_candidate(ctx.chars[i], ctx.char_mods[i])): return 1
		i = i + 1
	return 0


# Returns 1 when this frame's input holds the chord mods+key, consuming
# it so nothing else also acts on it. key is a letter or other
# character ('s', '+', ...); mods is GFX_MOD_* bits. Inert inside a
# ui_disable scope, or outside the innermost open popup.
int ui_shortcut(ui_context* ctx, int mods, int key):
	if (ctx.disabled): return 0
	if (ui_scope_blocked(ctx)): return 0
	int i = 0
	while (i < ctx.char_count):
		if (ui_shortcut_matches(ctx.chars[i], ctx.char_mods[i], mods, key)):
			# 0 is no character at all: every consumer skips it.
			ctx.chars[i] = 0
			return 1
		i = i + 1
	return 0


int ui_menu_append(char* out, int n, int cap, char* s):
	int i = 0
	while ((s[i] != 0) && (n < cap - 1)):
		out[n] = s[i]
		n = n + 1
		i = i + 1
	out[n] = 0
	return n


# "Ctrl+Shift+S" for a chord, into out (cap bytes). Returns out.
char* ui_shortcut_format(char* out, int cap, int mods, int key):
	int n = 0
	out[0] = 0
	if (mods & GFX_MOD_CTRL): n = ui_menu_append(out, n, cap, c"Ctrl+")
	if (mods & GFX_MOD_ALT): n = ui_menu_append(out, n, cap, c"Alt+")
	if (mods & GFX_MOD_SHIFT): n = ui_menu_append(out, n, cap, c"Shift+")
	if (mods & GFX_MOD_SUPER): n = ui_menu_append(out, n, cap, c"Super+")
	int k = key
	if ((k >= 'a') && (k <= 'z')): k = k - 32
	if ((k > 32) && (k < 127) && (n < cap - 1)):
		out[n] = k
		n = n + 1
		out[n] = 0
	return out


# ---- labels -------------------------------------------------------------

# Copy label into out without its '&' markers ("&&" keeps one). Returns
# the byte offset of the mnemonic character in out, or -1.
int ui_menu_strip(char* label, char* out, int cap):
	int at = 0 - 1
	int i = 0
	int n = 0
	while ((label[i] != 0) && (n < cap - 1)):
		if ((label[i] == '&') && (label[i + 1] == '&')):
			out[n] = '&'
			n = n + 1
			i = i + 2
		else if ((label[i] == '&') && (label[i + 1] != 0)):
			if (at < 0): at = n
			i = i + 1
		else:
			out[n] = label[i]
			n = n + 1
			i = i + 1
	out[n] = 0
	return at


# The lower-cased mnemonic letter a label marks with '&', or 0.
int ui_menu_mnemonic(char* label):
	int i = 0
	while (label[i] != 0):
		if (label[i] == '&'):
			if (label[i + 1] == '&'): i = i + 1
			else if (label[i + 1] != 0): return ui_menu_lower(label[i + 1] & 255)
		i = i + 1
	return 0


# Draw a label at x,y with its mnemonic (if any) underlined. Uses
# scratch for the stripped text; returns its width.
int ui_menu_draw_label(ui_context* ctx, char* scratch, float32 x, float32 y, char* label, ui_color ink):
	int scale = ctx.theme.text_scale
	int at = ui_menu_strip(label, scratch, 96)
	ui_draw_text(ctx.rndr, x, y, scratch, scale, ink)
	if (at >= 0):
		float32 x0 = x + cast(float32, ui_text_prefix_width(scratch, at, scale))
		int cp = 0
		int next = ui_utf8_next(scratch, at, &cp)
		float32 x1 = x + cast(float32, ui_text_prefix_width(scratch, next, scale))
		float32 base = y + cast(float32, ui_text_height(scale)) - 1.0
		ui_render_rect(ctx.rndr, ui_rect_new(x0, base, x1 - x0, 1.0), ink)
	return ui_text_width(scratch, scale)


int ui_menu_label_width(ui_context* ctx, char* scratch, char* label):
	ui_menu_strip(label, scratch, 96)
	return ui_text_width(scratch, ctx.theme.text_scale)


# ---- keyboard -----------------------------------------------------------

int ui_menu_bit(int mask, int i):
	if ((i < 0) || (i >= ui_menu_kb_items)): return 0
	return (mask >> i) & 1


# The next selectable item from `from` in direction dir (+1/-1),
# wrapping; -1 when the level has none. from = -1 starts outside the
# list, so +1 finds the first and -1 the last.
int ui_menu_step(ui_menu_state* st, int level, int from, int dir):
	int n = st.count[level]
	if (n > ui_menu_kb_items): n = ui_menu_kb_items
	if (n <= 0): return 0 - 1
	int i = from
	if (i < 0):
		if (dir > 0): i = 0 - 1
		else: i = n
	int tries = 0
	while (tries < n):
		i = i + dir
		if (i >= n): i = 0
		if (i < 0): i = n - 1
		if (ui_menu_bit(st.selectable[level], i)): return i
		tries = tries + 1
	return 0 - 1


# Open the submenu of item i on level L, resetting whatever the level
# below remembered about a different submenu.
void ui_menu_open_sub(ui_menu_state* st, int level, int i):
	if (level + 1 >= ui_menu_max_levels): return
	if (st.sub[level] == i): return
	st.sub[level] = i
	ui_menu_reset_levels(st, level + 1)


# Activate the highlighted item on the keyboard's level: open it when
# it is a submenu, else choose it during this frame's walk.
void ui_menu_activate(ui_menu_state* st):
	int level = st.kb_level
	int i = st.hl[level]
	if (i < 0): return
	if (ui_menu_bit(st.submask[level], i)):
		if (level + 1 < ui_menu_max_levels):
			ui_menu_open_sub(st, level, i)
			st.kb_level = level + 1
			st.hl[level + 1] = 0 - 2
		return
	st.act_level = level
	st.act_index = i


# The open chain owns the keyboard: drain the frame's keys into it so a
# focused field behind the menu does not also act on them.
void ui_menu_keys(ui_context* ctx, ui_menu_state* st):
	int i = 0
	while (i < ctx.char_count):
		int ch = ctx.chars[i]
		int mods = ctx.char_mods[i]
		int level = st.kb_level
		if (ch == 27):
			if (level > 0):
				st.kb_level = level - 1
				st.sub[level - 1] = 0 - 1
			else: st.open = 0
		else if ((ch == 13) || (ch == 32)): ui_menu_activate(st)
		else if ((ch > 32) && ((mods & (GFX_MOD_CTRL | GFX_MOD_ALT | GFX_MOD_SUPER)) == 0)):
			st.type_level = level
			st.type_char = ui_menu_lower(ch)
		i = i + 1
	i = 0
	while (i < ctx.nav_count):
		int nav = ctx.navs[i]
		int level = st.kb_level
		int from = st.hl[level]
		if (nav == GFX_NAV_DOWN): st.hl[level] = ui_menu_step(st, level, from, 1)
		else if (nav == GFX_NAV_UP): st.hl[level] = ui_menu_step(st, level, from, 0 - 1)
		else if (nav == GFX_NAV_HOME): st.hl[level] = ui_menu_step(st, level, 0 - 1, 1)
		else if (nav == GFX_NAV_END): st.hl[level] = ui_menu_step(st, level, 0 - 1, 0 - 1)
		else if (nav == GFX_NAV_RIGHT):
			if ((from >= 0) && ui_menu_bit(st.submask[level], from)): ui_menu_activate(st)
			else: st.key_right = 1
		else if (nav == GFX_NAV_LEFT):
			if (level > 0):
				st.kb_level = level - 1
				st.sub[level - 1] = 0 - 1
			else: st.key_left = 1
		i = i + 1
	ctx.char_count = 0
	ctx.nav_count = 0


# ---- the walk -------------------------------------------------------------

# Enter level L's surface: its popup bracket, and (the first time this
# frame) its elevation and fill.
void ui_menu_enter_level(ui_context* ctx, ui_menu_state* st, int level, ui_rect surface, int draw):
	st.surface[level] = surface
	st.live[level] = 1
	ui_popup_begin(ctx, st.id, surface, UI_LAYER_POPUP)
	if (draw):
		ui_draw_shadow(ctx.rndr, surface, ctx.theme.shadow)
		ui_draw_rrect(ctx.rndr, surface, cast(float32, ctx.theme.radius), ctx.theme.surface)


void ui_menu_begin_walk(ui_menu_state* st, int level):
	st.level = level
	st.index[level] = 0
	st.pen[level] = 0.0
	st.sel_now[level] = 0
	st.sub_now[level] = 0
	st.marks_now[level] = 0
	st.lw_now[level] = 0.0
	st.walk_index = 0
	st.pen_y = 0.0
	if (st.type_level == level):
		st.type_after = 0 - 1
		st.type_first = 0 - 1
		st.type_mnemonic = 0 - 1
		st.type_mnemonic_count = 0


# Close out level L's walk: what it measured becomes what the next
# frame places and navigates with, and a pending typeahead resolves.
void ui_menu_finish_walk(ui_context* ctx, ui_menu_state* st, int level):
	st.count[level] = st.index[level]
	st.selectable[level] = st.sel_now[level]
	st.submask[level] = st.sub_now[level]
	st.marks[level] = st.marks_now[level]
	st.lw[level] = st.lw_now[level]
	st.lh[level] = st.pen[level] + cast(float32, ctx.theme.pad) * 2.0
	if ((st.type_char != 0) && (st.type_level == level)):
		if (st.type_mnemonic_count == 1):
			# An explicit mnemonic that only one item has: choose it (or
			# open it) on the next frame, when it is walked again.
			st.hl[level] = st.type_mnemonic
			st.kb_level = level
			if (ui_menu_bit(st.submask[level], st.type_mnemonic)): ui_menu_activate(st)
			else:
				st.act_level = level
				st.act_index = st.type_mnemonic
		else if (st.type_after >= 0): st.hl[level] = st.type_after
		else if (st.type_first >= 0): st.hl[level] = st.type_first
		st.type_char = 0


# Enter a chain whose id block has already been reserved. Returns 1
# while open, having entered the root level's bracket.
int ui_menu_begin_reserved(ui_context* ctx, ui_menu_state* st):
	st.next_item = st.id + 1
	st.chosen = 0 - 1
	st.scanning = 0
	int k = 0
	while (k < ui_menu_max_levels):
		st.live[k] = 0
		k = k + 1
	ui_menu_begin_walk(st, 0)
	if (st.open == 0):
		ui_popup_dismiss(ctx, st.id)
		return 0
	ui_popup_open(ctx, st.id)
	st.moved = (ctx.input.mouse_x != st.last_mx) || (ctx.input.mouse_y != st.last_my)
	if (ui_popup_is_top(ctx, st.id) && (ctx.disabled == 0)): ui_menu_keys(ctx, st)
	if (st.open == 0):
		ui_popup_dismiss(ctx, st.id)
		ui_menu_reset(st)
		return 0

	float32 vw = cast(float32, ctx.rndr.vp_w)
	float32 vh = cast(float32, ctx.rndr.vp_h)
	float32 w = st.w
	if (st.lw[0] > w): w = st.lw[0]
	float32 h = st.height
	if (st.lh[0] > 0.0): h = st.lh[0]
	# A context menu's anchor is a zero-height rect at the pin: the
	# popover's placement then puts the surface just below it, flipping
	# and shifting to stay inside the viewport.
	ui_rect anchor = ui_rect_new(st.at_x, st.at_y, 0.0, 0.0)
	if (st.anchored): anchor = st.anchor
	ui_menu_enter_level(ctx, st, 0, ui_popover_place(anchor, w, h, vw, vh), 1)
	return 1


# Enter the menu. Returns 1 while open — issue items and call
# ui_menu_end. Returns 0 having pushed nothing, in which case
# ui_menu_end must not be called.
int ui_menu_begin(ui_context* ctx, ui_menu_state* st):
	st.id = ctx.next_id
	ctx.next_id = ctx.next_id + ui_menu_id_block
	return ui_menu_begin_reserved(ctx, st)


# Walk a closed chain for its shortcuts only: items draw nothing and
# return 1 only when their chord is in this frame's input. Always pair
# with ui_menu_end.
void ui_menu_begin_scan(ui_menu_state* st):
	st.scanning = 1
	st.level = 0
	st.chosen = 0 - 1


float32 ui_menu_gutter_of(ui_menu_state* st, int level):
	if (st.marks[level]): return ui_menu_gutter()
	return 0.0


# 1 when the pointer is over row on level L and no deeper open level's
# surface covers it there.
int ui_menu_pointer_over(ui_context* ctx, ui_menu_state* st, int level, ui_rect row, float32 px, float32 py):
	if (ui_rect_contains(row, px, py) == 0): return 0
	int k = level + 1
	while (k < ui_menu_max_levels):
		if (st.live_prev[k] && ui_rect_contains(st.surface_prev[k], px, py)): return 0
		k = k + 1
	return 1


# Every item kind shares this: geometry, measuring, hover, click,
# keyboard activation, typeahead, shortcut, and drawing. Returns 1
# when the item is chosen (for a submenu: when it opens).
int ui_menu_entry(ui_context* ctx, ui_menu_state* st, char* label, int kind, int32* value, int option, int mods, int key, int enabled):
	if (st.scanning):
		if (enabled && (kind != UI_MENU_SUB) && (key != 0) && ui_shortcut(ctx, mods, key)):
			if (kind == UI_MENU_CHECK): value[0] = (value[0] == 0)
			else if (kind == UI_MENU_RADIO): value[0] = option
			return 1
		return 0

	int level = st.level
	int index = st.index[level]
	st.index[level] = index + 1
	st.walk_index = index + 1
	int id = st.next_item
	if (st.next_item < st.id + ui_menu_id_block - 1): st.next_item = st.next_item + 1

	float32 pad = cast(float32, ctx.theme.pad)
	int scale = ctx.theme.text_scale
	ui_rect surface = st.surface[level]
	ui_rect row = ui_rect_new(surface.x + pad * 0.5, surface.y + pad + st.pen[level], surface.w - pad, ui_menu_item_height())
	st.pen[level] = st.pen[level] + ui_menu_item_height()
	st.pen_y = st.pen[level]
	float32 gutter = ui_menu_gutter_of(st, level)

	# Measure, for the next frame's surface width.
	int has_key = (key != 0) && (kind != UI_MENU_SUB)
	if (has_key): ui_shortcut_format(&st.keytext[0], 32, mods, key)
	float32 need = pad + gutter + cast(float32, ui_menu_label_width(ctx, &st.scratch[0], label)) + pad
	if (has_key): need = need + 24.0 + cast(float32, ui_text_width(&st.keytext[0], scale))
	if (kind == UI_MENU_SUB): need = need + 18.0
	need = need + pad
	if (need > st.lw_now[level]): st.lw_now[level] = need
	if ((kind == UI_MENU_CHECK) || (kind == UI_MENU_RADIO)): st.marks_now[level] = 1
	if (enabled && (index < ui_menu_kb_items)):
		st.sel_now[level] = st.sel_now[level] | (1 << index)
		if (kind == UI_MENU_SUB): st.sub_now[level] = st.sub_now[level] | (1 << index)
	if ((st.hl[level] == 0 - 2) && enabled): st.hl[level] = index

	int chosen = 0
	int live = st.open && (ctx.disabled == 0) && (ui_scope_blocked(ctx) == 0)
	if (live):
		float32 mx = cast(float32, ctx.input.mouse_x)
		float32 my = cast(float32, ctx.input.mouse_y)
		int over = ui_menu_pointer_over(ctx, st, level, row, mx, my)
		if (over && enabled): ctx.hot = id
		# Hover follows the pointer only when it moves, so it does not
		# undo the keyboard's highlight from under a resting pointer.
		if (over && st.moved):
			st.kb_level = level
			if (enabled):
				st.hl[level] = index
				if (kind == UI_MENU_SUB): ui_menu_open_sub(st, level, index)
				else: st.sub[level] = 0 - 1
			else:
				st.hl[level] = 0 - 1
				st.sub[level] = 0 - 1
		if (enabled && ctx.input.mouse_pressed):
			float32 qx = cast(float32, ctx.input.press_x)
			float32 qy = cast(float32, ctx.input.press_y)
			if (ui_menu_pointer_over(ctx, st, level, row, qx, qy)):
				ctx.active = id
				if (kind == UI_MENU_SUB):
					ui_menu_open_sub(st, level, index)
					st.kb_level = level
		int released = ctx.input.mouse_released && over && enabled
		if (released && ((ctx.active == id) || ((st.opener != 0) && (ctx.active == st.opener)))):
			chosen = 1
		if (enabled && (st.act_level == level) && (st.act_index == index)):
			chosen = 1
			st.act_level = 0 - 1
		if (enabled && (st.type_char != 0) && (st.type_level == level)):
			int explicit = ui_menu_mnemonic(label)
			int letter = explicit
			if (letter == 0):
				ui_menu_strip(label, &st.scratch[0], 96)
				letter = ui_menu_lower(st.scratch[0] & 255)
			if (letter == st.type_char):
				if ((index > st.hl[level]) && (st.type_after < 0)): st.type_after = index
				if (st.type_first < 0): st.type_first = index
				if (explicit != 0):
					if (st.type_mnemonic_count == 0): st.type_mnemonic = index
					st.type_mnemonic_count = st.type_mnemonic_count + 1
	if (chosen):
		if (kind == UI_MENU_SUB):
			ui_menu_open_sub(st, level, index)
			if (level + 1 < ui_menu_max_levels):
				st.kb_level = level + 1
				if (st.hl[level + 1] < 0): st.hl[level + 1] = 0 - 2
			chosen = 0
		else:
			if (kind == UI_MENU_CHECK): value[0] = (value[0] == 0)
			else if (kind == UI_MENU_RADIO): value[0] = option
			st.chosen = index
			# Closing here rather than in ui_menu_end keeps the bracket
			# balanced: the levels were entered this frame and still have
			# to be left through ui_menu_end.
			st.open = 0

	# Draw.
	int lit = enabled && ((st.hl[level] == index) || (st.sub[level] == index))
	if (lit): ui_draw_rrect(ctx.rndr, row, cast(float32, ctx.theme.radius_small), ctx.theme.widget_hot)
	ui_color ink = ctx.theme.text
	ui_color muted = ctx.theme.text_muted
	if (enabled == 0):
		ink = ctx.theme.disabled_text
		muted = ctx.theme.disabled_text
	float32 mark = 14.0
	float32 my2 = row.y + (row.h - mark) * 0.5
	ui_rect mark_rect = ui_rect_new(row.x + pad * 0.5, my2, mark, mark)
	if ((kind == UI_MENU_CHECK) && (value[0] != 0)): ui_draw_check(ctx.rndr, mark_rect, ink)
	if ((kind == UI_MENU_RADIO) && (value[0] == option)): ui_draw_disc(ctx.rndr, ui_rect_inset(mark_rect, 3.0), ink)
	float32 ty = row.y + (row.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_clip_push(ctx.rndr, row)
	ui_menu_draw_label(ctx, &st.scratch[0], row.x + pad + gutter, ty, label, ink)
	if (has_key):
		float32 kw = cast(float32, ui_text_width(&st.keytext[0], scale))
		ui_draw_text(ctx.rndr, row.x + row.w - pad - kw, ty, &st.keytext[0], scale, muted)
	if (kind == UI_MENU_SUB):
		float32 cs = 10.0
		ui_draw_chevron_right(ctx.rndr, ui_rect_new(row.x + row.w - pad - cs, row.y + (row.h - cs) * 0.5, cs, cs), muted)
	ui_clip_pop(ctx.rndr)
	return chosen


# One item. Returns 1 on the frame it is chosen, which also closes the
# menu — a menu never survives its own action.
int ui_menu_item(ui_context* ctx, ui_menu_state* st, char* label, int enabled):
	return ui_menu_entry(ctx, st, label, UI_MENU_PLAIN, cast(int32*, 0), 0, 0, 0, enabled)


# An item with a keyboard shortcut, shown right-aligned ("Ctrl+S").
# Inside a menu bar the chord works while the menu is closed too.
int ui_menu_item_key(ui_context* ctx, ui_menu_state* st, char* label, int mods, int key, int enabled):
	return ui_menu_entry(ctx, st, label, UI_MENU_PLAIN, cast(int32*, 0), 0, mods, key, enabled)


# A checkable item: choosing it flips *value. Returns 1 when it flips.
int ui_menu_check(ui_context* ctx, ui_menu_state* st, char* label, int32* value, int enabled):
	return ui_menu_entry(ctx, st, label, UI_MENU_CHECK, value, 0, 0, 0, enabled)


int ui_menu_check_key(ui_context* ctx, ui_menu_state* st, char* label, int32* value, int mods, int key, int enabled):
	return ui_menu_entry(ctx, st, label, UI_MENU_CHECK, value, 0, mods, key, enabled)


# One of a group of radio items sharing *value: choosing it sets
# *value = option. Returns 1 when chosen.
int ui_menu_radio(ui_context* ctx, ui_menu_state* st, char* label, int32* value, int option, int enabled):
	return ui_menu_entry(ctx, st, label, UI_MENU_RADIO, value, option, 0, 0, enabled)


# A hairline between groups of items. Costs no widget id and is not
# selectable: the keyboard steps over it.
void ui_menu_separator(ui_context* ctx, ui_menu_state* st):
	if (st.scanning): return
	int level = st.level
	float32 pad = cast(float32, ctx.theme.pad)
	ui_rect surface = st.surface[level]
	float32 y = surface.y + pad + st.pen[level] + ui_menu_separator_height() * 0.5
	st.pen[level] = st.pen[level] + ui_menu_separator_height()
	st.pen_y = st.pen[level]
	# It takes an index, so the keyboard's masks line up with the walk.
	st.index[level] = st.index[level] + 1
	ui_render_rect(ctx.rndr, ui_rect_new(surface.x + pad, y, surface.w - pad * 2.0, 1.0), ctx.theme.border)


# Where a w-by-h submenu opens beside `row` of a parent `surface`: to
# its right, or its left when the right runs off the viewport; its
# first item level with the row, shifted up to stay on screen.
ui_rect ui_menu_place_sub(ui_rect surface, ui_rect row, float32 pad, float32 w, float32 h, float32 vw, float32 vh):
	float32 x = surface.x + surface.w
	if ((x + w > vw) && (surface.x - w >= 0.0)): x = surface.x - w
	if (x + w > vw): x = vw - w
	if (x < 0.0): x = 0.0
	float32 y = row.y - pad
	if (y + h > vh): y = vh - h
	if (y < 0.0): y = 0.0
	return ui_rect_new(x, y, w, h)


# A submenu item. Returns 1 while its submenu is open — issue its items
# and call ui_menu_end_sub. Returns 0 having pushed nothing.
int ui_menu_begin_sub(ui_context* ctx, ui_menu_state* st, char* label, int enabled):
	if (st.scanning):
		if (enabled == 0): return 0
		st.level = st.level + 1
		return 1
	int level = st.level
	int index = st.index[level]
	ui_menu_entry(ctx, st, label, UI_MENU_SUB, cast(int32*, 0), 0, 0, 0, enabled)
	if ((enabled == 0) || (st.open == 0)): return 0
	if (st.sub[level] != index): return 0
	if (level + 1 >= ui_menu_max_levels): return 0

	float32 pad = cast(float32, ctx.theme.pad)
	ui_rect surface = st.surface[level]
	ui_rect row = ui_rect_new(surface.x + pad * 0.5, surface.y + pad + st.pen[level] - ui_menu_item_height(), surface.w - pad, ui_menu_item_height())
	float32 w = st.w
	if (st.lw[level + 1] > w): w = st.lw[level + 1]
	float32 h = ui_menu_item_height() + pad * 2.0
	if (st.lh[level + 1] > 0.0): h = st.lh[level + 1]
	ui_rect place = ui_menu_place_sub(surface, row, pad, w, h, cast(float32, ctx.rndr.vp_w), cast(float32, ctx.rndr.vp_h))
	# Leave the parent's bracket (its clip would trim the submenu) and
	# enter the submenu's; ui_menu_end_sub swaps back.
	ui_popup_end(ctx)
	ui_menu_enter_level(ctx, st, level + 1, place, 1)
	ui_menu_begin_walk(st, level + 1)
	return 1


void ui_menu_end_sub(ui_context* ctx, ui_menu_state* st):
	if (st.scanning):
		if (st.level > 0): st.level = st.level - 1
		return
	int level = st.level
	if (level == 0): return
	ui_menu_finish_walk(ctx, st, level)
	ui_popup_end(ctx)
	st.level = level - 1
	ui_menu_enter_level(ctx, st, level - 1, st.surface[level - 1], 0)
	st.walk_index = st.index[level - 1]
	st.pen_y = st.pen[level - 1]


# Leave the menu: record what this frame measured, and close the chain
# on a press that landed outside every level (consumed, so nothing
# behind the menu also sees it).
void ui_menu_end(ui_context* ctx, ui_menu_state* st):
	if (st.scanning):
		st.scanning = 0
		st.level = 0
		return
	ui_menu_finish_walk(ctx, st, 0)
	ui_popup_end(ctx)
	if (st.open && ctx.input.mouse_pressed):
		float32 px = cast(float32, ctx.input.press_x)
		float32 py = cast(float32, ctx.input.press_y)
		int inside = 0
		int k = 0
		while (k < ui_menu_max_levels):
			if (st.live[k] && ui_rect_contains(st.surface[k], px, py)): inside = 1
			k = k + 1
		if (st.bar && ui_rect_contains(st.bar_rect, px, py)): inside = 1
		if (inside == 0):
			st.open = 0
			ctx.input.mouse_pressed = 0
	int j = 0
	while (j < ui_menu_max_levels):
		st.live_prev[j] = st.live[j]
		st.surface_prev[j] = st.surface[j]
		j = j + 1
	# The keyboard cannot sit on a level that is no longer showing (one
	# a mnemonic opened during this frame's walk shows next frame).
	while ((st.kb_level > 0) && (st.live[st.kb_level] == 0) && (st.sub[st.kb_level - 1] < 0)): st.kb_level = st.kb_level - 1
	st.last_mx = ctx.input.mouse_x
	st.last_my = ctx.input.mouse_y
	st.height = st.lh[0]
	st.level = 0
	if (st.open == 0):
		ui_popup_dismiss(ctx, st.id)
		ui_menu_reset(st)
