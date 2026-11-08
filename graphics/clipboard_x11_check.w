# wbuild: binary=graphics_clipboard_x11_check arch=x64 tag=tests
# wbuild: target=graphics_clipboard_x11_test dep=graphics_clipboard_x11_check
# wbuild: step="xvfb-run -a bin/graphics_clipboard_x11_check"
# Real X11 round trips of the clipboard seam (docs/projects/ui_clipboard.md,
# issue #850), run under Xvfb by the opt-in graphics_clipboard_x11_test:
#
#   - two windows on separate display connections (two X clients, so every
#     transfer goes through the server: SelectionRequest, ChangeProperty,
#     SelectionNotify), in both directions, with non-ASCII text and CR LF;
#   - INCR in both directions, with the chunk size lowered so a 200 KB
#     transfer takes a few hundred chunks;
#   - ownership moving: copying in one window clears the other's claim;
#   - another application: xclip reads what a W window copied (also over
#     INCR) and serves text a W window pastes;
#   - PRIMARY (issue #910): between the two windows, to and from xclip, and
#     losing it when the other window selects;
#   - rich copies: xclip lists text/html and image/png among the TARGETS
#     and reads both back byte for byte, while a W paste still gets text;
#   - click counting: xdotool's single, double and triple clicks arrive as
#     MOUSE_DOWN events with click counts 1, 2 and 3.
#
# Prints "N/N passed"; any missing piece (no display, no GLX, no xclip,
# no xdotool) is a failure, never a skip.
import lib.lib
import lib.process
import lib.file
import lib.str
import graphics.window
import graphics.x11
import graphics.event
import structures.string

int failures
int checks


void check(int ok, char* what):
	checks = checks + 1
	if (ok): return
	failures = failures + 1
	print_error(c"FAIL: ")
	print_error(what)
	print_error(c"\n")


void check_text(char* want, char* got, char* what):
	if (got == 0):
		check(0, what)
		return
	int same = strcmp(want, got) == 0
	if (same == 0):
		print_error(c"  want: ")
		print_error(want)
		print_error(c"\n  got:  ")
		print_error(got)
		print_error(c"\n")
	check(same, what)


# Poll every window until `reader`'s PRIMARY paste arrives.
char* pump_primary(gfx_window* a, gfx_window* b, gfx_window* reader):
	int deadline = process_monotonic_ms() + 5000
	while (process_monotonic_ms() < deadline):
		gfx_window_poll(a)
		gfx_window_poll(b)
		char* text = gfx_primary_take(reader)
		if (text != 0): return text
		process_sleep_ms(2)
	return 0


char* paste_primary(gfx_window* a, gfx_window* b, gfx_window* reader):
	gfx_primary_request(reader)
	return pump_primary(a, b, reader)


# Poll every window until `reader`'s paste arrives (or five seconds pass).
char* pump(gfx_window* a, gfx_window* b, gfx_window* reader):
	int deadline = process_monotonic_ms() + 5000
	while (process_monotonic_ms() < deadline):
		gfx_window_poll(a)
		gfx_window_poll(b)
		char* text = gfx_clipboard_take(reader)
		if (text != 0): return text
		process_sleep_ms(2)
	return 0


char* paste(gfx_window* a, gfx_window* b, gfx_window* reader):
	gfx_clipboard_request(reader)
	return pump(a, b, reader)


char** sh(char* command):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/sh")
	strv_set(argv, 1, c"-c")
	strv_set(argv, 2, command)
	return argv


# Run a shell command to completion while the windows keep serving
# selection requests (a blocking wait would deadlock against xclip).
int run_serving(gfx_window* a, gfx_window* b, char* command):
	process* p = process_spawn(c"/bin/sh", sh(command), 0)
	if (p == 0): return 0 - 1
	int deadline = process_monotonic_ms() + 10000
	int status = process_status_running
	while ((status == process_status_running) && (process_monotonic_ms() < deadline)):
		gfx_window_poll(a)
		gfx_window_poll(b)
		status = process_try_wait(p)
		process_sleep_ms(2)
	process_free(p)
	return status


char* big_text(int size):
	char* text = cast(char*, malloc(size + 1))
	for i in range(size):
		text[i] = 'a' + (i % 26)
		if (i % 61 == 60): text[i] = 10
	text[size] = 0
	return text


int main(int argc, char** argv):
	gfx_window* a = gfx_window_open(c"clipboard A", 64, 64)
	gfx_window* b = gfx_window_open(c"clipboard B", 64, 64)
	if ((a == 0) || (b == 0)):
		print_error(c"FAIL: no X11/GLX display (run under xvfb-run -a)\n")
		return 1
	pump(a, b, a)

	# A copies, B pastes: the full selection protocol between two clients.
	check(gfx_clipboard_set(a, c"Grüße, 世界 ✓\r\nline two"), c"A owns CLIPBOARD")
	char* text = paste(a, b, b)
	check_text(c"Grüße, 世界 ✓\nline two", text, c"B pastes A's text (UTF-8, CR LF -> LF)")
	if (text != 0): free(text)

	# B copies: A's claim is cleared and A now pastes from B.
	check(gfx_clipboard_set(b, c"from B"), c"B owns CLIPBOARD")
	pump(a, b, a)
	check(a.clip.owned == 0, c"A saw SelectionClear")
	text = paste(a, b, a)
	check_text(c"from B", text, c"A pastes B's text")
	if (text != 0): free(text)

	# The owner pastes its own text without a server round trip.
	gfx_clipboard_request(b)
	text = gfx_clipboard_take(b)
	check_text(c"from B", text, c"B pastes its own text immediately")
	if (text != 0): free(text)

	# INCR both ways: 200 KB in 1 KB chunks.
	gfx_x11_clipboard_chunk = 1024
	char* big = big_text(200000)
	gfx_clipboard_set(a, big)
	text = paste(a, b, b)
	check((text != 0) && (strcmp(text, big) == 0), c"B pastes 200 KB from A over INCR")
	if (text != 0): free(text)
	gfx_clipboard_set(b, big)
	text = paste(a, b, a)
	check((text != 0) && (strcmp(text, big) == 0), c"A pastes 200 KB from B over INCR")
	if (text != 0): free(text)

	# Another application: xclip reads our selection, small and over INCR,
	# then serves text we paste.
	char* out = c"bin/graphics_clipboard_x11_check.out"
	gfx_x11_clipboard_chunk = 0
	gfx_clipboard_set(a, c"to xclip: café")
	check(run_serving(a, b, c"xclip -selection clipboard -o > bin/graphics_clipboard_x11_check.out") == 0, c"xclip -o ran")
	check_text(c"to xclip: café", file_read_text(out), c"xclip reads A's text")
	gfx_x11_clipboard_chunk = 4096
	gfx_clipboard_set(a, big)
	check(run_serving(a, b, c"xclip -selection clipboard -o > bin/graphics_clipboard_x11_check.out") == 0, c"xclip -o (INCR) ran")
	char* read_back = file_read_text(out)
	check((read_back != 0) && (strcmp(read_back, big) == 0), c"xclip reads 200 KB from A over INCR")
	gfx_x11_clipboard_chunk = 0
	check(run_serving(a, b, c"printf 'from xclip: ñ' | xclip -selection clipboard -i -l 1") == 0, c"xclip -i ran")
	pump(a, b, a)
	text = paste(a, b, a)
	check_text(c"from xclip: ñ", text, c"A pastes xclip's text")
	if (text != 0): free(text)
	unlink(out)

	# PRIMARY: the selection, separate from CLIPBOARD.
	gfx_clipboard_set(a, c"copied in A")
	check(gfx_primary_set(a, c"selected in A"), c"A owns PRIMARY")
	check(gfx_primary_set(a, c"selected more in A"), c"A updates PRIMARY while it owns it")
	text = paste_primary(a, b, b)
	check_text(c"selected more in A", text, c"B pastes A's PRIMARY")
	if (text != 0): free(text)
	text = paste(a, b, b)
	check_text(c"copied in A", text, c"CLIPBOARD is untouched by PRIMARY")
	if (text != 0): free(text)
	check(run_serving(a, b, c"xclip -selection primary -o > bin/graphics_clipboard_x11_check.out") == 0, c"xclip -selection primary -o ran")
	check_text(c"selected more in A", file_read_text(out), c"xclip reads A's PRIMARY")
	check(run_serving(a, b, c"printf 'primary from xclip' | xclip -selection primary -i -l 1") == 0, c"xclip -selection primary -i ran")
	pump(a, b, a)
	check(a.primary_claimed == 0, c"A saw SelectionClear for PRIMARY")
	text = paste_primary(a, b, a)
	check_text(c"primary from xclip", text, c"A pastes xclip's PRIMARY")
	if (text != 0): free(text)
	gfx_primary_set(b, c"B selected")
	pump(a, b, a)
	text = paste_primary(a, b, a)
	check_text(c"B selected", text, c"A pastes B's PRIMARY")
	if (text != 0): free(text)

	# Rich copy: text/html and image/png beside the text.
	char[8] png
	png[0] = 137
	png[1] = 'P'
	png[2] = 'N'
	png[3] = 'G'
	png[4] = 13
	png[5] = 10
	png[6] = 0
	png[7] = 200
	file_write_text(c"bin/graphics_clipboard_x11_check.png", c"")
	int fd = open(c"bin/graphics_clipboard_x11_check.png", 577, 420)
	write(fd, &png[0], 8)
	close(fd)
	check(gfx_clipboard_set_rich(a, c"flowchart LR", c"<b>flowchart</b>", &png[0], 8), c"A owns CLIPBOARD with rich flavors")
	check(run_serving(a, b, c"xclip -selection clipboard -t TARGETS -o > bin/graphics_clipboard_x11_check.out") == 0, c"xclip TARGETS ran")
	char* targets = file_read_text(out)
	check((targets != 0) && (index_of(targets, c"text/html") >= 0) && (index_of(targets, c"image/png") >= 0) && (index_of(targets, c"UTF8_STRING") >= 0), c"TARGETS lists text/html and image/png")
	check(run_serving(a, b, c"xclip -selection clipboard -t text/html -o > bin/graphics_clipboard_x11_check.out") == 0, c"xclip text/html ran")
	check_text(c"<b>flowchart</b>", file_read_text(out), c"xclip reads the HTML flavor")
	check(run_serving(a, b, c"xclip -selection clipboard -t image/png -o | cmp -s - bin/graphics_clipboard_x11_check.png") == 0, c"xclip reads the PNG flavor byte for byte")
	text = paste(a, b, b)
	check_text(c"flowchart LR", text, c"B pastes the rich copy's text")
	if (text != 0): free(text)
	# A plain copy afterwards offers text alone.
	gfx_clipboard_set(a, c"plain again")
	check(run_serving(a, b, c"xclip -selection clipboard -t TARGETS -o > bin/graphics_clipboard_x11_check.out") == 0, c"xclip TARGETS ran again")
	targets = file_read_text(out)
	check((targets != 0) && (index_of(targets, c"image/png") < 0), c"a plain copy drops the rich flavors")
	unlink(c"bin/graphics_clipboard_x11_check.png")
	unlink(out)

	# Click counts from real button events: B is the top window at 10,10.
	gfx_event e
	while (gfx_window_next_event(b, &e)): 0
	char* clicks = c"xdotool mousemove 10 10 click 1 sleep 0.8 click --repeat 3 --delay 120 1 sleep 0.8 click 1"
	check(run_serving(a, b, clicks) == 0, c"xdotool clicks ran")
	pump(a, b, a)
	string_builder* seen = string_new()
	while (gfx_window_next_event(b, &e)):
		if ((e.kind == GFX_EVENT_MOUSE_DOWN) && (e.code == 1)): string_append_int(seen, gfx_event_clicks(e.mods))
	check_text(c"11231", seen.data, c"MOUSE_DOWN click counts 1, 1 2 3, 1")

	gfx_window_destroy(a)
	gfx_window_destroy(b)
	print(itoa(checks - failures))
	print(c"/")
	print(itoa(checks))
	print(c" passed\n")
	if (failures != 0): return 1
	return 0
