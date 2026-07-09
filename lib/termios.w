/*
Terminal control: TCGETS/TCSETS wrappers over sys_ioctl, raw mode for
line editors, and a tty test.

The kernel struct termios (asm-generic/termbits.h, identical on i386 and
x86-64) is four int32 flag words, a one-byte line discipline and a
19-byte control-character array: 36 bytes. The struct below pads it to
40 with int32 fields; c_line and c_cc are reached through byte offsets.

term_raw_mode() saves the original settings the first time it succeeds;
term_restore() puts them back. Callers must restore before exiting, or
the shell inherits a terminal with echo and canonical mode off.

term_get_cols() returns the terminal's column count for line editors that
need to know when a line will wrap (lib/line_edit.w).
*/
import lib.lib
import lib.env


struct termios:
	int32 c_iflag
	int32 c_oflag
	int32 c_cflag
	int32 c_lflag
	int32 cc_word0 /* c_line + c_cc[0..2] */
	int32 cc_word1 /* c_cc[3..6], includes VTIME (byte 22) and VMIN (byte 23) */
	int32 cc_word2
	int32 cc_word3
	int32 cc_word4
	int32 cc_word5


int term_tcgets():
	return 0x5401


int term_tcsets():
	return 0x5402


int term_get(int fd, termios* t):
	return sys_ioctl(fd, term_tcgets(), cast(int, t))


int term_set(int fd, termios* t):
	return sys_ioctl(fd, term_tcsets(), cast(int, t))


# 1 when fd is a terminal: TCGETS only succeeds on ttys.
int term_isatty(int fd):
	termios t
	return term_get(fd, &t) == 0


# The saved cooked-mode settings of the fd raw mode was entered on.
termios* term_saved_state
int term_saved_fd


# Clear the mask bits of v (v & ~mask, without a bitwise-not operator).
int term_clear_bits(int v, int mask):
	return v - (v & mask)


# Switch fd into raw mode: no echo, no canonical line buffering, no
# signal or flow-control characters; read() returns after every byte.
# Output processing (ONLCR) is left on so '\x0a' still prints normally.
# Returns 1 on success (original settings saved), 0 when fd is not a tty.
int term_raw_mode(int fd):
	if (term_saved_state == 0):
		term_saved_state = cast(termios*, malloc(40))
	if (term_get(fd, term_saved_state) != 0):
		return 0
	term_saved_fd = fd
	termios raw
	term_get(fd, &raw)
	# iflag: BRKINT | ICRNL | INPCK | ISTRIP | IXON off (Enter arrives as
	# '\x0d'; Ctrl-S/Q pass through to the editor)
	raw.c_iflag = term_clear_bits(raw.c_iflag, 0x532)
	# lflag: ISIG | ICANON | ECHO | IEXTEN off
	raw.c_lflag = term_clear_bits(raw.c_lflag, 0x800b)
	# cflag: 8-bit characters
	raw.c_cflag = raw.c_cflag | 0x30
	# c_cc[VTIME]=0, c_cc[VMIN]=1: block until one byte is available
	char* bytes = cast(char*, &raw)
	bytes[22] = 0
	bytes[23] = 1
	return term_set(fd, &raw) == 0


void term_restore():
	if (term_saved_state == 0):
		return;
	term_set(term_saved_fd, term_saved_state)


int term_tiocgwinsz():
	return 0x5413


# Terminal column count for line editors that need to know when a line
# will wrap. $COLUMNS wins when set (the readline/bash convention, and a
# deterministic way to test wrapping without a real pty resize); otherwise
# the kernel's struct winsize (4 uint16 words: rows, cols, xpixels,
# ypixels) is read via TIOCGWINSZ, cols at byte offset 2-3, little-endian.
# Falls back to 80 when neither source is available (e.g. win64's
# sys_ioctl stub, which always fails).
int term_get_cols(int fd):
	char* env_cols = env_get(c"COLUMNS")
	if (env_cols != 0):
		int from_env = atoi(env_cols)
		if (from_env > 0):
			return from_env
	char* winsize = malloc(8)
	int cols = 0
	if (sys_ioctl(fd, term_tiocgwinsz(), cast(int, winsize)) == 0):
		cols = (winsize[2] & 255) | ((winsize[3] & 255) << 8)
	free(winsize)
	if (cols <= 0):
		return 80
	return cols
