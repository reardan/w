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
	Ctrl-R                   incremental reverse history search: type to
	                         refine the query, Ctrl-R again for an older
	                         match, Enter accepts, Esc/Ctrl-C cancels
	Tab                      complete the identifier before the cursor
	                         through le_complete_hook, or insert a
	                         literal tab when there is nothing to
	                         complete
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

Bracketed paste (ESC[?2004h/l) is enabled for the duration of each read.
A terminal that supports it wraps a paste in ESC[200~/ESC[201~; while
that is open, pasted bytes are inserted into the buffer verbatim
(including tabs, so pasted source indentation is not re-auto-indented on
top of), and an embedded newline ends just that one line for the caller
exactly like a typed Enter -- it never triggers Ctrl-C-style discarding
or any other special handling. Because a paste can span more than one
line_edit_read call, line_edit_in_paste() reports whether the paste
begun in an earlier call is still open (the end marker has not arrived
yet); callers that assemble multi-line entries out of several reads
(repl.w) use it to suspend both their own auto-indent seeding and any
"a blank line ends the entry" rule for the remainder of the paste.

le_complete_hook, when nonzero, is called as hook(prefix, out, capacity)
to complete the identifier immediately before the cursor: prefix is that
identifier's text, out a buffer of capacity word-sized slots the hook
fills with malloc'd candidate names (line_edit.w takes ownership and
frees them), returning how many it wrote (0 is a normal "no match"
result). A single candidate completes outright; several candidates
complete their shared prefix and are listed in columns below the line.
This stays a plain callback -- never a direct symbol-table dependency --
so line_edit.w has no notion of the REPL or its compiler state; repl.w
wires the hook to a function that walks the live symbol table.

Only one line_edit_read runs at a time, so the editing state (cursor,
length, history browsing, search and paste state) lives in module
globals.
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

# Bracketed paste (ESC[?2004h/l, ESC[200~/201~): see le_paste_consume.
int le_paste_active /* 1 while a paste is open, possibly across calls */
int le_seed_len /* length of the auto-indent seed this call started with */

# Optional identifier-completion hook (Tab): see le_try_complete.
int le_complete_hook

# Incremental reverse history search (Ctrl-R): see le_search_step.
int le_search_active
char* le_search_query
int le_search_qlen
int le_search_match /* history index of the current match, -1 = none */
char* le_search_pre_buf /* the live line, snapshotted when search begins */


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


# Render the incremental reverse-search prompt in place of the ordinary
# line: "(reverse-i-search)'query': matched-history-line". Kept as one
# plain, unwrapped row (the minimal readline-style behavior the feature
# asks for) rather than sharing le_render's multi-row wrap tracking.
void le_render_search():
	put_char(13)
	le_write(c"\x1b[J")
	le_write(c"(reverse-i-search)'")
	le_write_expanded(le_search_query, 0, le_search_qlen)
	le_write(c"': ")
	if ((le_search_match >= 0) && (le_search_match < le_history_count)):
		char* m = le_history_at(le_search_match)
		le_write_expanded(m, 0, strlen(m))
	le_prev_rows = 1


# Redraw the whole line and park the cursor at le_pos. Tracks how many
# terminal rows the buffer (with the prompt) occupies via le_prev_rows, so
# a buffer that wraps past one row is fully cleared and repainted instead
# of leaving stale wrapped rows on screen (the single-row assumption this
# used to make before multi-line wrap support was added).
void le_render(char* prompt, char* buf):
	if (le_search_active):
		le_render_search()
		return;
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


# Insert one byte at the cursor, shifting the tail right and respecting
# the buffer's size limit. Shared by ordinary keystrokes, pasted bytes
# and Tab-completion's inserted characters.
void le_insert_char(char* buf, int size, int ch):
	if (le_len >= size - 1):
		return;
	int k = le_len
	while (k > le_pos):
		buf[k] = buf[k - 1]
		k = k - 1
	buf[le_pos] = ch
	le_len = le_len + 1
	le_pos = le_pos + 1


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


# ---------------------------------------------------------------------------
# Tab completion (le_complete_hook). The pure pieces (identifier-boundary
# scanning and common-prefix computation) are factored out so a test can
# exercise them directly without a tty.

int le_is_ident_char(int c):
	return (('a' <= c) && (c <= 'z')) || (('A' <= c) && (c <= 'Z')) || (('0' <= c) && (c <= '9')) || (c == '_')


# Start index of the identifier ending at buf[0..pos) (scanning backward
# from pos while buf[i-1] is an identifier character). Pure and
# independent of any editor state.
int le_ident_start(char* buf, int pos):
	int start = pos
	while ((start > 0) && le_is_ident_char(buf[start - 1])):
		start = start - 1
	return start


# Length of the longest common prefix shared by every one of the `count`
# strings whose pointers are packed as word-sized slots in `out`. 0 when
# count is 0. Pure (no editor state).
int le_candidates_common_len(char* out, int count):
	if (count <= 0):
		return 0
	char* first = cast(char*, load_word(out))
	int common = strlen(first)
	int k = 1
	while (k < count):
		char* cand = cast(char*, load_word(out + k * __word_size__))
		int j = 0
		while ((j < common) && (cand[j] == first[j])):
			j = j + 1
		common = j
		k = k + 1
	return common


int le_complete_capacity():
	return 64


# Print candidates in simple columns below the current line; the caller's
# next le_render redraws the (possibly extended) line at the new cursor
# row this leaves us on.
void le_list_candidates(char* out, int count):
	int width = 0
	int i = 0
	while (i < count):
		int n = strlen(cast(char*, load_word(out + i * __word_size__)))
		if (n > width):
			width = n
		i = i + 1
	width = width + 2
	int cols = term_get_cols(0) / width
	if (cols < 1):
		cols = 1
	put_char(10)
	i = 0
	while (i < count):
		char* name = cast(char*, load_word(out + i * __word_size__))
		le_write(name)
		int pad = width - strlen(name)
		int p = 0
		while (p < pad):
			put_char(' ')
			p = p + 1
		i = i + 1
		if ((i % cols) == 0):
			put_char(10)
	if ((count % cols) != 0):
		put_char(10)
	le_prev_rows = 1 /* the listing scrolled past the line; render it fresh below */


# Complete the identifier immediately before the cursor via
# le_complete_hook. A single candidate is inserted outright; several
# candidates insert their common prefix (when it extends past what is
# already typed) and are listed in columns. A no-op (returns 0) when no
# hook is installed, the cursor is not just after an identifier
# character, or the hook finds nothing.
int le_try_complete(char* buf, int size):
	if (le_complete_hook == 0):
		return 0
	if (le_pos == 0):
		return 0
	if (le_is_ident_char(buf[le_pos - 1]) == 0):
		return 0
	int start = le_ident_start(buf, le_pos)
	int prefix_len = le_pos - start
	char* prefix = malloc(prefix_len + 1)
	int i = 0
	while (i < prefix_len):
		prefix[i] = buf[start + i]
		i = i + 1
	prefix[prefix_len] = 0

	int capacity = le_complete_capacity()
	char* out = malloc(capacity * __word_size__)
	int count = le_complete_hook(prefix, out, capacity)

	if (count <= 0):
		free(prefix)
		free(out)
		return 0

	int common = le_candidates_common_len(out, count)
	if (common > prefix_len):
		char* first = cast(char*, load_word(out))
		int extra = common - prefix_len
		int n = 0
		while (n < extra):
			le_insert_char(buf, size, first[prefix_len + n])
			n = n + 1

	if (count > 1):
		le_list_candidates(out, count)

	int c = 0
	while (c < count):
		free(cast(char*, load_word(out + c * __word_size__)))
		c = c + 1
	free(out)
	free(prefix)
	return 1


# ---------------------------------------------------------------------------
# Bracketed paste (ESC[?2004h/l, ESC[200~/ESC[201~).

void le_paste_mode_on():
	le_write(c"\x1b[?2004h")


void le_paste_mode_off():
	le_write(c"\x1b[?2004l")


# Match the literal bytes "[201~" right after an ESC already consumed by
# the caller. Real terminals always frame a paste exactly this way, so no
# pushback is attempted for a mismatch: a stray escape mid-paste (not
# itself expected from a compliant terminal) is simply dropped.
int le_paste_match_end():
	if (getchar(0) != '['):
		return 0
	if (getchar(0) != '2'):
		return 0
	if (getchar(0) != '0'):
		return 0
	if (getchar(0) != '1'):
		return 0
	return getchar(0) == '~'


# Consume a bracketed-paste block, already past "\x1b[200~" (or resuming
# one still open from an earlier line_edit_read call): insert its bytes
# into buf literally, including tabs, until "\x1b[201~" ends it. An
# embedded newline is itself a line boundary -- pasted text is very often
# several physical lines of source -- so it returns 1 exactly like a
# typed Enter, while le_paste_active stays set: the caller checks
# line_edit_in_paste() to know more of this same paste is still coming
# and should not be re-auto-indented or treated as ending a multi-line
# entry early. Returns 0 once "\x1b[201~" is reached with nothing pending
# to accept.
int le_paste_consume(char* buf, int size):
	# An auto-indent seed nobody has typed past yet would double up with
	# the pasted text's own leading tabs -- drop it.
	if ((le_seed_len > 0) && (le_len == le_seed_len) && (le_pos == le_len)):
		le_len = 0
		le_pos = 0
	le_paste_active = 1
	while (1):
		int c = getchar(0)
		if (c == -1):
			le_paste_active = 0
			return 0
		if (c == 27):
			if (le_paste_match_end()):
				le_paste_active = 0
				return 0
			continue /* not the end marker: drop the lone ESC and keep going */
		if ((c == 13) || (c == 10)):
			return 1
		le_insert_char(buf, size, c)
	return 0


# 1 while a bracketed paste is still open across a call boundary: an
# earlier line_edit_read call returned because the pasted text itself
# contained a newline, and the terminal has not yet sent the "\x1b[201~"
# end marker.
int line_edit_in_paste():
	return le_paste_active


# ---------------------------------------------------------------------------
# Incremental reverse history search (Ctrl-R).

# 1 when needle occurs anywhere in haystack (including haystack itself
# when needle is empty). Pure; no substring helper exists in lib/lib.w.
int le_str_contains(char* haystack, char* needle):
	if (needle[0] == 0):
		return 1
	int i = 0
	while (haystack[i]):
		int j = 0
		while ((needle[j] != 0) && (haystack[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			return 1
		i = i + 1
	return 0


void le_search_end_state():
	le_search_active = 0
	if (le_search_pre_buf != 0):
		free(le_search_pre_buf)
		le_search_pre_buf = 0


# Find a match for le_search_query at or before le_search_match (inclusive
# of the current position, so a query that still matches the current
# match keeps it instead of always jumping to the newest entry). -1 when
# nothing matches.
void le_search_refine():
	int i = le_search_match
	if (i > le_history_count):
		i = le_history_count
	while (i >= 0):
		if ((i < le_history_count) && le_str_contains(le_history_at(i), le_search_query)):
			le_search_match = i
			return;
		i = i - 1
	le_search_match = -1


# Ctrl-R again: move strictly to an older match.
void le_search_older():
	if (le_search_match < 0):
		return;
	le_search_match = le_search_match - 1
	le_search_refine()


# Backspace during search: shrink the query and restart from the newest
# entry (a shorter query can match more recent entries again).
void le_search_backspace():
	if (le_search_qlen > 0):
		le_search_qlen = le_search_qlen - 1
		le_search_query[le_search_qlen] = 0
	le_search_match = le_history_count
	le_search_refine()


void le_search_cancel(char* buf, int size):
	le_set_line(buf, size, le_search_pre_buf)
	le_search_end_state()


void le_search_begin(char* buf):
	if (le_search_query == 0):
		le_search_query = malloc(256)
	le_search_qlen = 0
	le_search_query[0] = 0
	le_search_pre_buf = strclone(buf)
	le_search_active = 1
	le_search_match = le_history_count
	le_search_refine()


# Handle one keystroke while an incremental search is in progress.
# Returns 1 when Enter accepted a match: the caller finishes the line
# exactly like an ordinary typed Enter. Any key with no search-specific
# meaning ends the search (the current match, if any, becomes the live
# buffer) and is pushed back onto stdin so the ordinary dispatch loop
# processes it fresh on its next read.
int le_search_step(char* buf, int size, int c):
	if (c == 18): /* Ctrl-R again: older match */
		le_search_older()
		return 0
	if ((c == 3) || (c == 27)): /* Ctrl-C / Esc: cancel */
		le_search_cancel(buf, size)
		return 0
	if ((c == 13) || (c == 10)): /* Enter: accept the match */
		if (le_search_match >= 0):
			le_set_line(buf, size, le_history_at(le_search_match))
			le_search_end_state()
			return 1
		le_search_cancel(buf, size)
		return 0
	if ((c == 8) || (c == 127)): /* backspace: shrink the query */
		le_search_backspace()
		return 0
	if ((c >= 32) && (c < 127)): /* printable: extend the query */
		if (le_search_qlen < 255):
			le_search_query[le_search_qlen] = c
			le_search_qlen = le_search_qlen + 1
			le_search_query[le_search_qlen] = 0
			le_search_refine()
		return 0
	# Any other key ends the search and is re-delivered to the normal
	# dispatch loop: the byte is still sitting in getchar's own buffer
	# (this is the byte we just read from it), so stepping its read
	# position back one un-reads it with no real seek() involved.
	if (le_search_match >= 0):
		le_set_line(buf, size, le_history_at(le_search_match))
	le_search_end_state()
	if (getchar_pos[0] > 0):
		getchar_pos[0] = getchar_pos[0] - 1
	return 0


# ---------------------------------------------------------------------------
# CSI escape sequences.

# CSI sequences after "\x1b[": arrows, home/end, delete, bracketed paste
# markers. Returns 1 when a pasted embedded newline means the caller
# should finish the line immediately, like Enter; 0 otherwise.
int le_escape_bracket(char* buf, int size):
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
		int n = c2 - '0'
		int c3 = getchar(0)
		while ((c3 >= '0') && (c3 <= '9')):
			n = n * 10 + (c3 - '0')
			c3 = getchar(0)
		if (c3 == '~'):
			if (n == 1): /* home */
				le_pos = 0
			else if (n == 4): /* end */
				le_pos = le_len
			else if (n == 3): /* delete */
				le_delete_at(buf, le_pos)
			else if (n == 200): /* bracketed paste start */
				return le_paste_consume(buf, size)
			else if (n == 201): /* a stray end marker: the paste that
					opened it already returned on an embedded newline in
					an earlier call, so there is nothing left to insert */
				le_paste_active = 0
	return 0


int le_escape(char* buf, int size):
	int c1 = getchar(0)
	if (c1 == '['):
		return le_escape_bracket(buf, size)
	else if (c1 == 'O'): /* application-mode home/end */
		int c2 = getchar(0)
		if (c2 == 'H'):
			le_pos = 0
		else if (c2 == 'F'):
			le_pos = le_len
	# a lone escape (or an unknown sequence) is ignored
	return 0


# Shared tail for every "the line is done" exit: turn bracketed paste
# back off, restore cooked mode, echo the newline and record history.
int le_finish_line(char* buf):
	buf[le_len] = 0
	le_paste_mode_off()
	term_restore()
	put_char(10)
	le_history_accept(buf)
	return le_len


int line_edit_read(char* prompt, char* buf, int size, char* initial):
	if (term_raw_mode(0) == 0):
		return le_read_plain(prompt, buf, size)

	le_set_line(buf, size, c"")
	le_seed_len = 0
	if (initial != 0):
		le_set_line(buf, size, initial)
		le_seed_len = le_len
	le_browse = -1
	le_prev_rows = 1
	le_search_end_state()
	le_paste_mode_on()

	if (le_paste_active):
		# A paste begun in an earlier call on this same entry is still
		# open (the terminal has not sent the end marker yet): resume
		# consuming it before anything else so a pasted tab or an
		# embedded blank line is handled the same way it would be if the
		# whole paste had arrived inside one call.
		if (le_paste_consume(buf, size)):
			return le_finish_line(buf)

	le_render(prompt, buf)

	while (1):
		int c = getchar(0)
		if (c == -1):
			le_paste_mode_off()
			term_restore()
			put_char(10)
			return -1
		if (le_search_active):
			if (le_search_step(buf, size, c)):
				return le_finish_line(buf)
			le_render(prompt, buf)
			continue
		if ((c == 13) || (c == 10)):
			return le_finish_line(buf)
		if (c == 3): /* Ctrl-C */
			buf[0] = 0
			le_paste_mode_off()
			term_restore()
			le_write(c"^C")
			put_char(10)
			return -2
		if (c == 4): /* Ctrl-D */
			if (le_len == 0):
				le_paste_mode_off()
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
		else if (c == 18): /* Ctrl-R: incremental reverse history search */
			le_search_begin(buf)
		else if (c == 27):
			if (le_escape(buf, size)):
				return le_finish_line(buf)
		else if (c == 9): /* Tab: complete, or insert if nothing matches */
			if (le_try_complete(buf, size) == 0):
				le_insert_char(buf, size, c)
		else if ((c >= 32) && (c < 127)): /* insert */
			le_insert_char(buf, size, c)
		le_render(prompt, buf)
	return 0
