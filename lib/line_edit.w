/*
Readline-style line editing with history for interactive prompts.

line_edit_read(prompt, buf, size, initial) reads one line. On a tty it
switches stdin to raw mode (lib/termios.w) for the duration of the call
and supports the usual editing keys:

	left/right, Ctrl-B/F     move by one character
	home/end, Ctrl-A/E       move to the line's ends
	backspace, delete        remove a character
	Ctrl-K / Ctrl-U          kill to end / to start
	Ctrl-W                   kill the word before the cursor
	Ctrl-L                   clear the screen and redraw
	up/down, Ctrl-P/N        browse history
	Ctrl-C                   discard the line (returns -2)
	Ctrl-D                   EOF on an empty line, else delete
	Enter                    accept the line

When stdin is not a tty it prints the prompt and reads a plain line, so
piped scripts behave exactly as without the editor. Returns the line
length (buf is zero-terminated), -1 on end of input, -2 when the line
was discarded with Ctrl-C.

`initial` (may be 0) seeds the buffer with editable text, e.g. the
REPL's auto-indent tabs; it is ignored on non-tty input, which carries
its own text. Tabs display as 4 spaces but stay real tabs in the buffer.

History is in-memory until line_edit_history_load(path) is called: that
loads previous entries from the file and appends every accepted line to
it (best-effort: a missing HOME or unwritable file just disables
persistence). "~/name" paths resolve against $HOME.

Only one line_edit_read runs at a time, so the editing state (cursor,
length, history browsing) lives in module globals.
*/
import lib.termios
import lib.env


char* le_history_entries /* word-sized slots of malloc'd lines */
int le_history_count
int le_history_capacity
char* le_history_path /* 0 until line_edit_history_load succeeds */

# State of the line being edited.
int le_len
int le_pos
int le_browse /* history index while browsing, -1 = the live line */
char* le_stash /* the live line, while browsing history */
int le_prev_rows /* terminal rows the last le_render call occupied */


char* le_history_at(int i):
	return cast(char*, load_word(le_history_entries + i * __word_size__))


# Append to the in-memory history, skipping empty lines and consecutive
# duplicates.
void le_history_add(char* line):
	if (line[0] == 0):
		return;
	if (le_history_count > 0):
		if (strcmp(le_history_at(le_history_count - 1), line) == 0):
			return;
	if (le_history_count >= le_history_capacity):
		int old = le_history_capacity * __word_size__
		if (le_history_capacity == 0):
			le_history_capacity = 64
			le_history_entries = malloc(le_history_capacity * __word_size__)
		else:
			le_history_capacity = le_history_capacity * 2
			le_history_entries = realloc(le_history_entries, old, le_history_capacity * __word_size__)
	save_word(le_history_entries + le_history_count * __word_size__, cast(int, strclone(line)))
	le_history_count = le_history_count + 1


# "~/name" -> "$HOME/name" (malloc'd); everything else is cloned.
char* le_resolve_path(char* path):
	if ((path[0] == '~') && (path[1] == '/')):
		char* home = env_get(c"HOME")
		if (home != 0):
			return strjoin(home, path + 1)
	return strclone(path)


# Load history from path (one entry per line) and append every future
# accepted line to it.
void line_edit_history_load(char* path):
	char* resolved = le_resolve_path(path)
	le_history_path = resolved
	int f = open(resolved, 0, 0)
	if (f < 0):
		return;
	getchar_reset(f)
	char* line = malloc(4096)
	int len = 0
	int c = getchar(f)
	while (c != -1):
		if (c == 10):
			line[len] = 0
			le_history_add(line)
			len = 0
		else if (len < 4095):
			line[len] = c
			len = len + 1
		c = getchar(f)
	if (len > 0):
		line[len] = 0
		le_history_add(line)
	free(line)
	close(f)


# Record an accepted line: in-memory always, appended to the history
# file when one was loaded. O_WRONLY|O_CREAT|O_APPEND = 1089.
void le_history_accept(char* line):
	if (line[0] == 0):
		return;
	int fresh = le_history_count
	le_history_add(line)
	if (le_history_count == fresh):
		return; /* duplicate of the previous entry: not re-persisted */
	if (le_history_path == 0):
		return;
	int f = open(le_history_path, 1089, 420)
	if (f < 0):
		return;
	write(f, line, strlen(line))
	write(f, c"\x0a", 1)
	close(f)


void le_write(char* s):
	write(1, s, strlen(s))


# Buffer text with tabs expanded to 4 spaces (display only).
void le_write_expanded(char* buf, int from, int to):
	int i = from
	while (i < to):
		if (buf[i] == 9):
			le_write(c"    ")
		else:
			put_char(buf[i])
		i = i + 1


# Display columns occupied by buf[from..to).
int le_display_width(char* buf, int from, int to):
	int w = 0
	int i = from
	while (i < to):
		if (buf[i] == 9):
			w = w + 4
		else:
			w = w + 1
		i = i + 1
	return w


# 0-based terminal row the cursor rests on after writing `chars` columns
# of output starting at column 1 of an empty row, given a terminal `cols`
# wide. Terminals defer wrapping until the character *after* the last
# column is written (the cursor rests at the last column, not a phantom
# next row), so this is (chars - 1) / cols, not chars / cols.
int le_row_for_width(int chars, int cols):
	if (chars <= 0):
		return 0
	return (chars - 1) / cols


# 1-based column the cursor rests on under the same model.
int le_col_for_width(int chars, int cols):
	if (chars <= 0):
		return 1
	return (chars - 1) % cols + 1


# Write n to fd as an ANSI parameter followed by suffix, e.g. "\x1b[3A".
void le_write_csi(int n, char* suffix):
	le_write(c"\x1b[")
	char* digits = itoa(n)
	le_write(digits)
	free(digits)
	le_write(suffix)


# Redraw the whole line and park the cursor at le_pos. Tracks how many
# terminal rows the buffer (with the prompt) occupies via le_prev_rows, so
# a buffer that wraps past one row is fully cleared and repainted instead
# of leaving stale wrapped rows on screen (the single-row assumption this
# used to make before multi-line wrap support was added).
void le_render(char* prompt, char* buf):
	int cols = term_get_cols(0)
	if (le_prev_rows > 1):
		le_write_csi(le_prev_rows - 1, c"A")
	put_char(13)
	le_write(c"\x1b[J") /* clear cursor to end of screen: covers wrapped rows below too */
	le_write(prompt)
	le_write_expanded(buf, 0, le_len)

	int prompt_width = strlen(prompt)
	int total_end = prompt_width + le_display_width(buf, 0, le_len)
	int total_cursor = prompt_width + le_display_width(buf, 0, le_pos)
	int end_row = le_row_for_width(total_end, cols)
	int cursor_row = le_row_for_width(total_cursor, cols)
	int cursor_col = le_col_for_width(total_cursor, cols)

	if (end_row > cursor_row):
		le_write_csi(end_row - cursor_row, c"A")
	le_write_csi(cursor_col, c"G")

	le_prev_rows = end_row + 1


# Replace the buffer contents with text; cursor moves to the end.
void le_set_line(char* buf, int size, char* text):
	le_len = 0
	while ((text[le_len] != 0) && (le_len < size - 1)):
		buf[le_len] = text[le_len]
		le_len = le_len + 1
	buf[le_len] = 0
	le_pos = le_len


# Remove the character at index (a no-op past the end).
void le_delete_at(char* buf, int index):
	if ((index < 0) || (index >= le_len)):
		return;
	int i = index
	while (i < le_len - 1):
		buf[i] = buf[i + 1]
		i = i + 1
	le_len = le_len - 1


# Step to the previous history entry; stashes the live line on entry to
# browsing.
void le_browse_prev(char* buf, int size):
	if (le_history_count == 0):
		return;
	if (le_browse < 0):
		buf[le_len] = 0
		if (le_stash != 0):
			free(le_stash)
		le_stash = strclone(buf)
		le_browse = le_history_count
	if (le_browse > 0):
		le_browse = le_browse - 1
		le_set_line(buf, size, le_history_at(le_browse))


# Step to the next history entry; past the newest one, the stashed live
# line comes back.
void le_browse_next(char* buf, int size):
	if (le_browse < 0):
		return;
	le_browse = le_browse + 1
	if (le_browse >= le_history_count):
		le_browse = -1
		if (le_stash != 0):
			le_set_line(buf, size, le_stash)
		else:
			le_set_line(buf, size, c"")
		return;
	le_set_line(buf, size, le_history_at(le_browse))


# Plain line read for non-tty input: prompt, then bytes to the newline.
int le_read_plain(char* prompt, char* buf, int size):
	le_write(prompt)
	int len = 0
	int c = getchar(0)
	if (c == -1):
		return -1
	while ((c != 10) && (c != -1)):
		if (len < size - 1):
			buf[len] = c
			len = len + 1
		c = getchar(0)
	buf[len] = 0
	return len


# CSI sequences after "\x1b[": arrows, home/end, delete.
void le_escape_bracket(char* buf, int size):
	int c2 = getchar(0)
	if (c2 == 'A'):
		le_browse_prev(buf, size)
	else if (c2 == 'B'):
		le_browse_next(buf, size)
	else if (c2 == 'C'):
		if (le_pos < le_len):
			le_pos = le_pos + 1
	else if (c2 == 'D'):
		if (le_pos > 0):
			le_pos = le_pos - 1
	else if (c2 == 'H'):
		le_pos = 0
	else if (c2 == 'F'):
		le_pos = le_len
	else if ((c2 >= '0') && (c2 <= '9')):
		int c3 = getchar(0)
		if (c3 == '~'):
			if (c2 == '1'): /* home */
				le_pos = 0
			else if (c2 == '4'): /* end */
				le_pos = le_len
			else if (c2 == '3'): /* delete */
				le_delete_at(buf, le_pos)


void le_escape(char* buf, int size):
	int c1 = getchar(0)
	if (c1 == '['):
		le_escape_bracket(buf, size)
	else if (c1 == 'O'): /* application-mode home/end */
		int c2 = getchar(0)
		if (c2 == 'H'):
			le_pos = 0
		else if (c2 == 'F'):
			le_pos = le_len
	# a lone escape (or an unknown sequence) is ignored


int line_edit_read(char* prompt, char* buf, int size, char* initial):
	if (term_raw_mode(0) == 0):
		return le_read_plain(prompt, buf, size)

	le_set_line(buf, size, c"")
	if (initial != 0):
		le_set_line(buf, size, initial)
	le_browse = -1
	le_prev_rows = 1
	le_render(prompt, buf)

	while (1):
		int c = getchar(0)
		if (c == -1):
			term_restore()
			put_char(10)
			return -1
		if ((c == 13) || (c == 10)):
			buf[le_len] = 0
			term_restore()
			put_char(10)
			le_history_accept(buf)
			return le_len
		if (c == 3): /* Ctrl-C */
			buf[0] = 0
			term_restore()
			le_write(c"^C")
			put_char(10)
			return -2
		if (c == 4): /* Ctrl-D */
			if (le_len == 0):
				term_restore()
				put_char(10)
				return -1
			le_delete_at(buf, le_pos)
		else if ((c == 8) || (c == 127)): /* backspace */
			if (le_pos > 0):
				le_delete_at(buf, le_pos - 1)
				le_pos = le_pos - 1
		else if (c == 1): /* Ctrl-A */
			le_pos = 0
		else if (c == 5): /* Ctrl-E */
			le_pos = le_len
		else if (c == 2): /* Ctrl-B */
			if (le_pos > 0):
				le_pos = le_pos - 1
		else if (c == 6): /* Ctrl-F */
			if (le_pos < le_len):
				le_pos = le_pos + 1
		else if (c == 11): /* Ctrl-K: kill to end */
			le_len = le_pos
		else if (c == 21): /* Ctrl-U: kill to start */
			int i = 0
			while (le_pos + i < le_len):
				buf[i] = buf[le_pos + i]
				i = i + 1
			le_len = le_len - le_pos
			le_pos = 0
		else if (c == 23): /* Ctrl-W: kill the word before the cursor */
			int start = le_pos
			while (start > 0):
				if (buf[start - 1] != ' '):
					break
				start = start - 1
			while (start > 0):
				if (buf[start - 1] == ' '):
					break
				start = start - 1
			int d = le_pos - start
			if (d > 0):
				int j = le_pos
				while (j < le_len):
					buf[j - d] = buf[j]
					j = j + 1
				le_len = le_len - d
				le_pos = start
		else if (c == 12): /* Ctrl-L: clear screen */
			le_write(c"\x1b[H\x1b[2J")
		else if (c == 16): /* Ctrl-P */
			le_browse_prev(buf, size)
		else if (c == 14): /* Ctrl-N */
			le_browse_next(buf, size)
		else if (c == 27):
			le_escape(buf, size)
		else if (((c >= 32) && (c < 127)) || (c == 9)): /* insert */
			if (le_len < size - 1):
				int k = le_len
				while (k > le_pos):
					buf[k] = buf[k - 1]
					k = k - 1
				buf[le_pos] = c
				le_len = le_len + 1
				le_pos = le_pos + 1
		le_render(prompt, buf)
	return 0
