const int gfx_event_ring_ints = 320
/*
graphics.event: the per-frame input event queue shared by every window
backend (docs/projects/ui_framework.md §7). The polling fields on
gfx_window keep last-known state, which collapses a press+release (or
two key presses) that land in the same poll cycle; widgets that care
about edges drain gfx_window_next_event instead.

Each backend owns a fixed ring — a flat int32 array of
gfx_event_ring_ints slots plus head/tail indices appended to its own
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
	# code = a Unicode codepoint of typed text, or 8 (backspace),
	# 9 (tab), 13 (return), 27 (escape). How much of Unicode arrives
	# depends on the backend: Cocoa Unicode key text, X11 XIM Unicode, Win32
	# UTF-16 decoded scalars, the web
	# Unicode through the browser text-input bridge. With Ctrl held, a letter arrives as its control code
	# 1..26 from the native backends (Ctrl+S is 19) and as the letter
	# itself from the web host; Cocoa also queues Command chords' letter
	# with GFX_MOD_SUPER. Widgets that insert text skip CHARs carrying
	# Ctrl or Super (ui_char_is_typing); menus match them as shortcuts.
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
	# Logical pixel scroll delta, positive down; x,y locate the viewport.
	GFX_EVENT_SCROLL_PIXELS = 8
	# Pointer capture lost, gesture became scrolling, or host lost focus.
	# Cancels the press without manufacturing a release/click.
	GFX_EVENT_POINTER_CANCEL = 9
	# Preedit snapshot stream: BEGIN clears, TEXT appends a Unicode scalar,
	# END clears on cancellation/commit. Preedit is never committed text;
	# commits still arrive through CHAR. x carries the stable focus ID
	# (zero means current focus); y on BEGIN is the selection start in
	# scalar units. A new BEGIN replaces the previous snapshot.
	GFX_EVENT_PREEDIT_BEGIN = 10
	GFX_EVENT_PREEDIT_TEXT = 11
	GFX_EVENT_PREEDIT_END = 12


enum gfx_nav_code:
	GFX_NAV_LEFT = 1
	GFX_NAV_RIGHT = 2
	GFX_NAV_HOME = 3
	GFX_NAV_END = 4
	GFX_NAV_UP = 5
	GFX_NAV_DOWN = 6
	GFX_NAV_PAGE_UP = 7
	GFX_NAV_PAGE_DOWN = 8
	GFX_NAV_DELETE = 9


# Modifier keys held when an event was produced, or-ed into gfx_event.mods.
# Backend-independent: X11 translates its own state mask, the JS hosts
# their shiftKey/ctrlKey/altKey/metaKey booleans. Bit values are part of
# the JS-host contract (tools/web/index.html mirrors them).
enum gfx_mod:
	GFX_MOD_SHIFT = 1
	GFX_MOD_CTRL = 2
	GFX_MOD_ALT = 4
	GFX_MOD_SUPER = 8


struct gfx_event:
	int32 kind
	int32 code
	int32 x
	int32 y
	int32 mods


# Presses in a row. A MOUSE_DOWN carries its click count (1 single, 2
# double, 3 triple, up to 15) in mods bits 8..11, above the gfx_mod
# keys: the backend counts, because the platform knows its own
# double-click time (Win32 GetDoubleClickTime, Cocoa clickCount) and the
# UI layer reads no clock. 0 there, from a backend or test that does not
# count, reads as a single click.
const int gfx_mod_keys = 255
const int gfx_clicks_shift = 8


int gfx_event_clicks(int mods):
	int clicks = (mods >> gfx_clicks_shift) & 15
	if (clicks == 0): return 1
	return clicks


int gfx_mods_with_clicks(int mods, int clicks):
	if (clicks < 1): clicks = 1
	if (clicks > 15): clicks = 15
	return (mods & gfx_mod_keys) | (clicks << gfx_clicks_shift)


# Multi-click detection for backends whose events carry only a
# timestamp (X11 server milliseconds, Win32 GetMessageTime): a press of
# the same button within interval_ms of the previous one, and within
# slop pixels of it, continues the run.
struct gfx_click_tracker:
	int time
	int32 x
	int32 y
	int32 button
	int32 count


const int gfx_click_interval_ms = 500
const int gfx_click_slop = 4


void gfx_click_tracker_init(gfx_click_tracker* t):
	t.time = 0
	t.x = 0
	t.y = 0
	t.button = 0
	t.count = 0


# Record a press at time_ms and return its click count.
int gfx_click_tracker_press(gfx_click_tracker* t, int button, int time_ms, int x, int y, int interval_ms, int slop):
	int dt = time_ms - t.time
	int dx = x - t.x
	int dy = y - t.y
	if (dx < 0): dx = 0 - dx
	if (dy < 0): dy = 0 - dy
	if ((t.count > 0) && (button == t.button) && (dt >= 0) && (dt <= interval_ms) && (dx <= slop) && (dy <= slop)): t.count = t.count + 1
	else: t.count = 1
	t.time = time_ms
	t.x = x
	t.y = y
	t.button = button
	return t.count


# Events the ring can hold minus one (tail == head means empty).
const int gfx_event_ring_capacity = 64


# int32 slots a backend's ring array needs: capacity events x 5 fields.


# Append one event. A full ring drops the newest event rather than
# overwrite unread ones: 63 pending events in a single frame already
# means the consumer is not draining.
void gfx_event_ring_push(int32* ring, int32* head, int32* tail, int kind, int code, int x, int y, int mods):
	int slot = tail[0]
	int next = (slot + 1) & 63
	if (next == head[0]): return
	ring[slot * 5] = kind
	ring[slot * 5 + 1] = code
	ring[slot * 5 + 2] = x
	ring[slot * 5 + 3] = y
	ring[slot * 5 + 4] = mods
	tail[0] = next


# Pop the oldest event into out. Returns 1 when out was filled, 0 when
# the ring is empty.
int gfx_event_ring_next(int32* ring, int32* head, int32* tail, gfx_event* out):
	int slot = head[0]
	if (slot == tail[0]): return 0
	out.kind = ring[slot * 5]
	out.code = ring[slot * 5 + 1]
	out.x = ring[slot * 5 + 2]
	out.y = ring[slot * 5 + 3]
	out.mods = ring[slot * 5 + 4]
	head[0] = (slot + 1) & 63
	return 1
