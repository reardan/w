/*
graphics.event: the per-frame input event queue shared by every window
backend (docs/projects/ui_framework.md §7). The polling fields on
gfx_window keep last-known state, which collapses a press+release (or
two key presses) that land in the same poll cycle; widgets that care
about edges drain gfx_window_next_event instead.

Each backend owns a fixed ring — a flat int32 array of
gfx_event_ring_ints() slots plus head/tail indices appended to its own
gfx_window struct (the struct layouts are already per-backend) — and
implements the uniform accessor:

	int gfx_window_next_event(gfx_window* win, gfx_event* out)

returning 1 while events remain. The wasm backend keeps its 7-int32
snapshot struct byte-frozen (the JS host writes it by offset) and
drains a host-side queue through one import instead; the JS hosts
mirror the gfx_event_kind numbers below (tools/web/index.html,
tools/web/webgl_env.mjs).

The helpers here are pure ring plumbing over caller-owned storage, so
every backend shares push/pop logic through plain pointers.
*/


enum gfx_event_kind:
	GFX_EVENT_NONE = 0
	# code = the backend-native keycode: a raw X keycode on X11, a HID
	# scancode on macOS, JS e.keyCode on the web. Not portable across
	# backends; portable text arrives as GFX_EVENT_CHAR.
	GFX_EVENT_KEY_DOWN = 1
	GFX_EVENT_KEY_UP = 2
	# code = ASCII 32..126, or 8 (backspace), 9 (tab), 13 (return),
	# 27 (escape)
	GFX_EVENT_CHAR = 3
	# code = button 1 (left), 2 (middle), 3 (right); x,y = pointer
	# position at event time
	GFX_EVENT_MOUSE_DOWN = 4
	GFX_EVENT_MOUSE_UP = 5
	# code = +1 (wheel away from the user / scroll up) or -1 (toward /
	# down), one event per notch; x,y = pointer position. X11 buttons
	# 4/5 and the JS wheel listener both land here; wheel buttons never
	# appear as MOUSE_DOWN/MOUSE_UP.
	GFX_EVENT_SCROLL = 6
	# code = a gfx_nav_code: caret/selection movement keys, which have
	# no ASCII form so GFX_EVENT_CHAR cannot carry them. Translated
	# per-backend (X11 keysyms, JS e.key) into portable codes, unlike
	# the raw keycodes on KEY_DOWN/KEY_UP.
	GFX_EVENT_NAV = 7


enum gfx_nav_code:
	GFX_NAV_LEFT = 1
	GFX_NAV_RIGHT = 2
	GFX_NAV_HOME = 3
	GFX_NAV_END = 4


struct gfx_event:
	int32 kind
	int32 code
	int32 x
	int32 y


# Events the ring can hold minus one (tail == head means empty).
int gfx_event_ring_capacity():
	return 64


# int32 slots a backend's ring array needs: capacity events x 4 fields.
int gfx_event_ring_ints():
	return 256


# Append one event. A full ring drops the newest event rather than
# overwrite unread ones: 63 pending events in a single frame already
# means the consumer is not draining.
void gfx_event_ring_push(int32* ring, int32* head, int32* tail, int kind, int code, int x, int y):
	int slot = tail[0]
	int next = (slot + 1) & 63
	if (next == head[0]):
		return
	ring[slot * 4] = kind
	ring[slot * 4 + 1] = code
	ring[slot * 4 + 2] = x
	ring[slot * 4 + 3] = y
	tail[0] = next


# Pop the oldest event into out. Returns 1 when out was filled, 0 when
# the ring is empty.
int gfx_event_ring_next(int32* ring, int32* head, int32* tail, gfx_event* out):
	int slot = head[0]
	if (slot == tail[0]):
		return 0
	out.kind = ring[slot * 4]
	out.code = ring[slot * 4 + 1]
	out.x = ring[slot * 4 + 2]
	out.y = ring[slot * 4 + 3]
	head[0] = (slot + 1) & 63
	return 1
