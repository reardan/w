/*
graphics.clipboard_store: the backend-neutral half of the clipboard seam
(docs/projects/ui_clipboard.md). Every window backend appends one
gfx_clipboard_store to its gfx_window and implements

	int  gfx_clipboard_set(gfx_window* win, char* text)
	void gfx_clipboard_request(gfx_window* win)
	char* gfx_clipboard_take(gfx_window* win)

on top of it: set is synchronous, request starts a read that may finish
on a later poll (X11 and the browser are asynchronous), and take returns
the arrived text once (malloc'd, NUL-terminated UTF-8 with LF line
ends; the caller frees it) and 0 while it is still on its way. A failed
or empty read arrives as "", so a caller waiting on take always stops.

A null window means "no platform": every backend then round-trips
through gfx_clipboard_local, an in-process store, which is what headless
tests and the windowless x86 stub get.

Pure: no platform imports, so it compiles for every target.
*/
import lib.lib
import lib.mem


enum gfx_clipboard_state:
	GFX_CLIPBOARD_IDLE = 0
	# a read is in flight (X11: waiting for SelectionNotify)
	GFX_CLIPBOARD_REQUESTED = 1
	# X11 INCR: chunks arrive as PropertyNotify events
	GFX_CLIPBOARD_INCR = 2
	# incoming holds the text; take hands it over
	GFX_CLIPBOARD_ARRIVED = 3


struct gfx_clipboard_store:
	# The text this process published (X11 serves requests from it for
	# as long as it owns CLIPBOARD; elsewhere it is a cache).
	char* owned
	int32 owned_length
	# Text being received or ready to take.
	char* incoming
	int32 incoming_length
	int32 incoming_capacity
	int32 state
	int32 last_cr
	# Backend scratch: the target a pending X11 read asked for.
	int target


gfx_clipboard_store gfx_clipboard_local


void gfx_clipboard_store_init(gfx_clipboard_store* s):
	s.owned = 0
	s.owned_length = 0
	s.incoming = 0
	s.incoming_length = 0
	s.incoming_capacity = 0
	s.state = GFX_CLIPBOARD_IDLE
	s.last_cr = 0
	s.target = 0


void gfx_clipboard_store_free(gfx_clipboard_store* s):
	if (s.owned != 0): free(s.owned)
	if (s.incoming != 0): free(s.incoming)
	gfx_clipboard_store_init(s)


# Publish a copy of text[0..length) as this process's clipboard text.
void gfx_clipboard_store_own(gfx_clipboard_store* s, char* text, int length):
	if (s.owned != 0): free(s.owned)
	s.owned = cast(char*, malloc(length + 1))
	mem_copy[char](s.owned, text, length)
	s.owned[length] = 0
	s.owned_length = length


# Start receiving: drop any text not yet taken.
void gfx_clipboard_store_begin(gfx_clipboard_store* s, int state):
	s.incoming_length = 0
	s.last_cr = 0
	s.state = state


# Append received bytes. CR LF and lone CR become LF and NUL bytes are
# dropped, so every backend hands widgets the same line ends whatever
# the source application wrote (Windows CF_UNICODETEXT is CR LF).
void gfx_clipboard_store_append(gfx_clipboard_store* s, char* data, int length):
	if (s.incoming_length + length + 1 > s.incoming_capacity):
		int next = s.incoming_capacity
		if (next < 64): next = 64
		while (next < s.incoming_length + length + 1): next = next * 2
		char* grown = cast(char*, malloc(next))
		if (s.incoming != 0):
			mem_copy[char](grown, s.incoming, s.incoming_length)
			free(s.incoming)
		s.incoming = grown
		s.incoming_capacity = next
	for i in range(length):
		int c = data[i] & 255
		if (c == 0): continue
		# CR becomes LF; an LF right after it (even in the next chunk) is
		# the pair's second half.
		if ((c == 10) && s.last_cr):
			s.last_cr = 0
			continue
		s.last_cr = 0
		if (c == 13):
			c = 10
			s.last_cr = 1
		s.incoming[s.incoming_length] = c
		s.incoming_length = s.incoming_length + 1
	s.incoming[s.incoming_length] = 0


# The read finished: take() now succeeds once.
void gfx_clipboard_store_arrive(gfx_clipboard_store* s):
	if (s.incoming == 0): gfx_clipboard_store_append(s, c"", 0)
	s.state = GFX_CLIPBOARD_ARRIVED


# Finish a read with one complete payload.
void gfx_clipboard_store_deliver(gfx_clipboard_store* s, char* data, int length):
	gfx_clipboard_store_begin(s, GFX_CLIPBOARD_REQUESTED)
	gfx_clipboard_store_append(s, data, length)
	gfx_clipboard_store_arrive(s)


# The arrived text (caller frees), or 0 while a read is pending or none
# was made.
char* gfx_clipboard_store_take(gfx_clipboard_store* s):
	if (s.state != GFX_CLIPBOARD_ARRIVED): return 0
	s.state = GFX_CLIPBOARD_IDLE
	char* out = cast(char*, malloc(s.incoming_length + 1))
	mem_copy[char](out, s.incoming, s.incoming_length)
	out[s.incoming_length] = 0
	s.incoming_length = 0
	return out


# The in-process clipboard behind a null window.
int gfx_clipboard_local_set(char* text):
	gfx_clipboard_store_own(&gfx_clipboard_local, text, strlen(text))
	return 1


void gfx_clipboard_local_request():
	gfx_clipboard_store* s = &gfx_clipboard_local
	gfx_clipboard_store_deliver(s, s.owned, s.owned_length)


char* gfx_clipboard_local_take():
	return gfx_clipboard_store_take(&gfx_clipboard_local)
