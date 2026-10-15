# Native input queue. Grow for paste/IME commits and drain within the UI
# frame budgets; unread events retain their order across subsequent polls.
import lib.lib
import graphics.event


struct gfx_input_queue:
	gfx_event* events
	int count
	int head
	int capacity
	int chars
	int navs


void gfx_input_queue_init(gfx_input_queue* queue):
	queue.events = cast(gfx_event*, 0)
	queue.count = 0
	queue.head = 0
	queue.capacity = 0
	queue.chars = 0
	queue.navs = 0


void gfx_input_queue_begin(gfx_input_queue* queue):
	queue.chars = 0
	queue.navs = 0


void gfx_input_queue_push(gfx_input_queue* queue, int kind, int code, int x, int y, int mods):
	if (queue.count == queue.capacity):
		if (queue.head > 0):
			int remaining = queue.count - queue.head
			for i in range(remaining): queue.events[i] = queue.events[queue.head + i]
			queue.count = remaining
			queue.head = 0
		else:
			int capacity = queue.capacity * 2
			if (capacity < 64): capacity = 64
			queue.events = cast(gfx_event*, realloc(cast(char*, queue.events), queue.capacity * sizeof(gfx_event), capacity * sizeof(gfx_event)))
			queue.capacity = capacity
	gfx_event* event = &queue.events[queue.count]
	event.kind = kind
	event.code = code
	event.x = x
	event.y = y
	event.mods = mods
	queue.count = queue.count + 1


int gfx_input_queue_next(gfx_input_queue* queue, gfx_event* out):
	if (queue.head == queue.count): return 0
	gfx_event* event = &queue.events[queue.head]
	if ((event.kind == GFX_EVENT_CHAR) && (queue.chars >= 32)): return 0
	if ((event.kind == GFX_EVENT_NAV) && (queue.navs >= 8)): return 0
	# Widgets consume CHAR before NAV/click edges. A later focus/caret
	# change must wait until this frame's preceding text was inserted.
	if (queue.chars > 0):
		if ((event.kind == GFX_EVENT_MOUSE_DOWN) || (event.kind == GFX_EVENT_MOUSE_UP) || (event.kind == GFX_EVENT_NAV)): return 0
	# Conversely, earlier navigation must take effect before new text or
	# a click is allowed to alter the focused field/caret.
	if (queue.navs > 0):
		if ((event.kind == GFX_EVENT_CHAR) || (event.kind == GFX_EVENT_MOUSE_DOWN) || (event.kind == GFX_EVENT_MOUSE_UP)): return 0
	out[0] = event[0]
	if (event.kind == GFX_EVENT_CHAR): queue.chars = queue.chars + 1
	if (event.kind == GFX_EVENT_NAV): queue.navs = queue.navs + 1
	queue.head = queue.head + 1
	if (queue.head == queue.count):
		queue.head = 0
		queue.count = 0
	return 1


void gfx_input_queue_free(gfx_input_queue* queue):
	if (queue.events != 0): free(queue.events)
	gfx_input_queue_init(queue)
