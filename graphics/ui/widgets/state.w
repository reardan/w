/*
graphics.ui.widgets.state: the immediate-mode context structs — the
per-frame input snapshot and the context every widget threads through
(docs/projects/ui_widgets.md §3). Structs only: W is single-pass and
requires declaration before use, so the types the rest of the widget
tree operates on have to come first.
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render


struct ui_input:
	int32 mouse_x
	int32 mouse_y
	int32 mouse_down       # button 1 currently held
	int32 mouse_pressed    # a button-1 MOUSE_DOWN arrived this frame
	int32 mouse_released   # a button-1 MOUSE_UP arrived this frame
	int32 press_x          # where this frame's press landed
	int32 press_y
	# Wheel notches accumulated this frame, +1 per notch away from the
	# user. Claimed by the scroll region under the pointer and zeroed by
	# it, so one wheel event does not scroll two nested regions.
	int32 scroll_x
	int32 scroll_y
	int32 scroll_at_x      # pointer position when the wheel turned
	int32 scroll_at_y
	int32 mods             # gfx_mod bits on the most recent event


# Where widgets are placed. One of these is the whole window (seeded by
# ui_begin); ui_region_push nests another inside it, which is what lets
# a modal body, a table cell or a scrolled viewport lay out without
# every widget growing a special case.
struct ui_layout:
	ui_rect bounds         # the area this region places widgets in
	float32 cursor_x
	float32 cursor_y
	float32 origin_x
	float32 last_right     # previous widget's right edge (for same_line)
	float32 last_top       # previous widget's top edge
	float32 content_w      # extent placed so far, from bounds' origin
	float32 content_h
	int32 pending_same_line


# Layout regions a frame can nest.
int ui_layout_max_depth():
	return 8


# Popups that can be open at once — a popover inside a modal, a
# dropdown inside that.
int ui_popup_max_depth():
	return 4


struct ui_context:
	ui_renderer* rndr
	ui_theme* theme
	ui_input input
	int32 hot              # widget under the pointer this frame (0 = none)
	int32 active           # widget owning the current press (0 = none)
	int32 focus            # widget owning keyboard input (persistent)
	int32 disabled         # ui_disable scope: widgets render but are inert
	int32 next_id          # per-frame sequential id counter
	# This frame's translated text input, drained by the focused
	# widget; cleared in ui_end like the mouse edges.
	int32[32] chars        # GFX_EVENT_CHAR codes in arrival order
	int32[32] char_mods    # gfx_mod bits held for chars[i]
	int32 char_count
	int32[8] navs          # GFX_EVENT_NAV codes in arrival order
	int32[8] nav_mods      # gfx_mod bits held for navs[i]
	int32 nav_count
	# Layout regions, innermost at layout_depth - 1. ui_begin seeds
	# depth 1 with the window, so the plain vertical stack is the
	# root-region case.
	ui_layout[8] layout_stack
	int32 layout_depth
	# Open popups, innermost last. Persistent across frames like the
	# widget state they belong to: a popup opened last frame has to make
	# widgets issued BEFORE it this frame inert too, which a
	# frame-scoped bracket could not do.
	int32[4] popup_stack
	int32 popup_depth
	# The popup scope currently being issued (0 = base). Only the
	# innermost open popup's scope takes input.
	int32 scope
	# ui_popup_begin/ui_popup_end save the enclosing scope and layer
	# here, so popups can nest.
	int32[4] scope_saved
	int32[4] layer_saved
	int32 bracket_depth
