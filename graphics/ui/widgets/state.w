/*
graphics.ui.widgets.state: the immediate-mode context structs — the
per-frame input snapshot and the context every widget threads through
(docs/projects/ui_widgets.md §3). Structs only: W is single-pass and
requires declaration before use, so the types the rest of the widget
tree operates on have to come first.
*/
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


struct ui_context:
	ui_renderer* rndr
	ui_theme* theme
	ui_input input
	int32 hot              # widget under the pointer this frame (0 = none)
	int32 active           # widget owning the current press (0 = none)
	int32 focus            # widget owning keyboard input (persistent)
	int32 modal            # open popup owning ALL input (a dropdown)
	int32 disabled         # ui_disable scope: widgets render but are inert
	int32 next_id          # per-frame sequential id counter
	# This frame's translated text input, drained by the focused
	# widget; cleared in ui_end like the mouse edges.
	int32[32] chars        # GFX_EVENT_CHAR codes in arrival order
	int32 char_count
	int32[8] navs          # GFX_EVENT_NAV codes in arrival order
	int32 nav_count
	float32 cursor_x
	float32 cursor_y
	float32 origin_x
	float32 last_right     # previous widget's right edge (for same_line)
	float32 last_top       # previous widget's top edge
	int32 pending_same_line
