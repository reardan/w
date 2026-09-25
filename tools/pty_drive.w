# wbuild: target=repl_pty_test tag=tests dep=wv2 data=tests/repl_pty_ctrl_r.pty data=tools/pty_drive.w
# wbuild: step="bin/wv2 tools/pty_drive.w -o bin/pty_drive"
# wbuild: step="bin/wv2 repl.w -o bin/repl_pty"
# wbuild: step="bin/pty_drive --timeout 60 --fresh-home bin/repl_pty_home tests/repl_pty_ctrl_r.pty -- ./bin/repl_pty" expect_stdout="pty script OK"
/*
pty_drive: run a command under a real pty and drive it from a small
expect/send script. It replaced tools/pty_test.py (issue #323: no shell
or Python scripts in the repo) with the same interface, script
semantics, output and exit codes.

Usage:
  bin/pty_drive [--timeout SECONDS] [--fresh-home DIR] SCRIPT [--] CMD [ARG...]

--timeout (default 30; decimals allowed, millisecond resolution) bounds
each script step and the final drain/exit wait separately. --fresh-home
DIR removes DIR recursively, recreates it and sets HOME to its absolute
path in the command's environment, so a program that writes dotfiles
(the REPL's ~/.w_history) runs against a scratch home. The options may
come in either order, before SCRIPT. CMD without a '/' is searched on
PATH, like execvp.

Script format (one directive per line; blank lines and lines whose first
column is '#' are ignored):

  expect TEXT   wait until TEXT appears in the command's pty output,
                consuming through it; fails after the timeout
  send TEXT     write TEXT to the command's pty input

TEXT is everything after the first space (trailing spaces are kept, so
"expect w> " waits for the prompt's trailing space too) and decodes the
escapes \n \r \t \e \0 \\ and \xHH, so control bytes -- e.g. \x12 for
Ctrl-R, \r for a raw-mode Enter -- can be scripted. Lines end at \n,
\r\n or a lone \r (Python's universal newlines, which the original
harness read the script with).

Why this exists (docs/projects/ai_tooling_next_steps.md, "script -qc
cannot script a canonical-mode keystroke"): script(1) delivers piped
stdin to the pty in one burst while the slave is still in its default
canonical mode, whose line discipline consumes special characters like
Ctrl-R (VREPRINT) on the spot -- the program never sees the byte, and no
later switch to raw mode un-consumes it. Here every send happens only
after an expected marker has appeared -- e.g. a prompt that is rendered
only after term_raw_mode() has already run -- so keystrokes arrive when
the program is actually in the mode the script assumes.

After the last directive the harness drains output to EOF and waits for
the child, which must exit 0. On success it prints "pty script OK" and
exits 0; on any failure it prints a diagnostic (script line, marker and
the unconsumed output tail, both shown as Python bytes reprs) to stderr,
kills the child and exits 1. Usage and script errors also exit 1.

The pty itself comes from lib/pty.w (x86 and x86-64 Linux).
*/
import lib.lib
import lib.env
import lib.poll
import lib.pty
import lib.time
import lib.shell_commands


/* Growable byte buffer (the pty output and decoded TEXT may hold NULs). */

struct pd_buf:
	char* data
	int length
	int capacity


pd_buf* pd_buf_new():
	pd_buf* b = new pd_buf()
	b.capacity = 64
	b.data = malloc(b.capacity)
	b.length = 0
	return b


void pd_buf_push(pd_buf* b, int c):
	if (b.length + 1 >= b.capacity):
		int bigger = b.capacity * 2
		b.data = realloc(b.data, b.capacity, bigger)
		b.capacity = bigger
	b.data[b.length] = c
	b.length = b.length + 1
	b.data[b.length] = 0


void pd_buf_append(pd_buf* b, char* s, int n):
	int i = 0
	while (i < n):
		pd_buf_push(b, s[i])
		i = i + 1


void pd_buf_cstr(pd_buf* b, char* s):
	pd_buf_append(b, s, strlen(s))


# Index of needle in b at or after start, or -1.
int pd_buf_find(pd_buf* b, pd_buf* needle, int start):
	int i = start
	while (i + needle.length <= b.length):
		int j = 0
		while ((j < needle.length) && (b.data[i + j] == needle.data[j])):
			j = j + 1
		if (j == needle.length):
			return i
		i = i + 1
	return -1


void pd_write_all(int fd, char* s, int n):
	int off = 0
	while (off < n):
		int w = write(fd, s + off, n - off)
		if (w <= 0):
			return
		off = off + w


void pd_err_buf(pd_buf* b):
	pd_write_all(2, b.data, b.length)


char* pd_hex_digits():
	return c"0123456789abcdef"


# Appends Python's repr() of s[0..n): bytes_mode 1 renders a bytes object
# (b'...', every byte >= 0x7f escaped), 0 a str (non-ASCII bytes kept as
# they are, since the script is UTF-8 text).
void pd_repr(pd_buf* out, char* s, int n, int bytes_mode):
	int has_single = 0
	int has_double = 0
	int i = 0
	while (i < n):
		if (s[i] == 39):
			has_single = 1
		if (s[i] == 34):
			has_double = 1
		i = i + 1
	int quote = 39
	if (has_single && (has_double == 0)):
		quote = 34
	if (bytes_mode):
		pd_buf_push(out, 'b')
	pd_buf_push(out, quote)
	i = 0
	while (i < n):
		int c = s[i] & 255
		if ((c == 92) || (c == quote)):
			pd_buf_push(out, 92)
			pd_buf_push(out, c)
		else:
			if (c == 10):
				pd_buf_cstr(out, c"\\n")
			else:
				if (c == 13):
					pd_buf_cstr(out, c"\\r")
				else:
					if (c == 9):
						pd_buf_cstr(out, c"\\t")
					else:
						if ((c < 32) || (c == 127) || (bytes_mode && (c > 127))):
							pd_buf_cstr(out, c"\\x")
							char* hex_digits = pd_hex_digits()
							pd_buf_push(out, hex_digits[c >> 4])
							pd_buf_push(out, hex_digits[c & 15])
						else:
							pd_buf_push(out, c)
		i = i + 1
	pd_buf_push(out, quote)


# Python's %g of a millisecond count given in seconds: "60", "0.25".
void pd_format_seconds(pd_buf* out, int ms):
	pd_buf_cstr(out, itoa(ms / 1000))
	int frac = ms % 1000
	if (frac != 0):
		pd_buf_push(out, '.')
		int digit = 100
		while (frac != 0):
			pd_buf_push(out, '0' + frac / digit)
			frac = frac % digit
			digit = digit / 10


/* Script parsing. */

int pd_hex_value(int c):
	if ((c >= '0') && (c <= '9')):
		return c - '0'
	if ((c >= 'a') && (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')):
		return c - 'A' + 10
	return -1


int pd_is_space(int c):
	return (c == 32) || ((c >= 9) && (c <= 13))


# Python's int(two_chars, 16) as the original decoder used it: optional
# surrounding whitespace and sign around 1-2 hex digits. Returns the byte
# value, or -1 where Python raised ValueError (bad text, or a negative
# value that bytearray.append rejects) -- the escape then stays literal.
int pd_parse_hex2(char* s):
	int start = 0
	int end = 2
	while ((start < end) && pd_is_space(s[start])):
		start = start + 1
	while ((end > start) && pd_is_space(s[end - 1])):
		end = end - 1
	int negative = 0
	if ((start < end) && ((s[start] == '+') || (s[start] == '-'))):
		negative = s[start] == '-'
		start = start + 1
	if (start == end):
		return -1
	int value = 0
	while (start < end):
		int d = pd_hex_value(s[start])
		if (d < 0):
			return -1
		value = value * 16 + d
		start = start + 1
	if (negative && (value != 0)):
		return -1
	return value


# Decodes the escape syntax of text[0..n) into bytes.
pd_buf* pd_decode(char* text, int n):
	pd_buf* out = pd_buf_new()
	int i = 0
	while (i < n):
		int ch = text[i] & 255
		if ((ch == 92) && (i + 1 < n)):
			int next = text[i + 1]
			int simple = -1
			if (next == 'n'):
				simple = 10
			if (next == 'r'):
				simple = 13
			if (next == 't'):
				simple = 9
			if (next == 'e'):
				simple = 27
			if (next == '0'):
				simple = 0
			if (next == 92):
				simple = 92
			if (simple >= 0):
				pd_buf_push(out, simple)
				i = i + 2
				continue
			if ((next == 'x') && (i + 3 < n)):
				int value = pd_parse_hex2(text + i + 2)
				if (value >= 0):
					pd_buf_push(out, value)
					i = i + 4
					continue
		pd_buf_push(out, ch)
		i = i + 1
	return out


struct pd_step:
	int is_send
	pd_buf* data
	int lineno


int pd_line_starts(char* line, int n, char* prefix):
	int k = strlen(prefix)
	if (n < k):
		return 0
	int i = 0
	while (i < k):
		if (line[i] != prefix[i]):
			return 0
		i = i + 1
	return 1


pd_buf* pd_read_file(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0):
		return 0
	pd_buf* b = pd_buf_new()
	char* chunk = malloc(65536)
	int n = read(fd, chunk, 65536)
	while (n > 0):
		pd_buf_append(b, chunk, n)
		n = read(fd, chunk, 65536)
	free(chunk)
	close(fd)
	if (n < 0):
		return 0
	return b


list[pd_step*] pd_parse_script(char* path):
	pd_buf* text = pd_read_file(path)
	if (text == 0):
		pd_buf* msg = pd_buf_new()
		pd_buf_cstr(msg, c"pty_drive: cannot read script ")
		pd_buf_cstr(msg, path)
		pd_buf_push(msg, 10)
		pd_err_buf(msg)
		exit(1)
	list[pd_step*] steps = new list[pd_step*]
	int lineno = 0
	int pos = 0
	while (pos < text.length):
		lineno = lineno + 1
		char* line = text.data + pos
		int n = 0
		while ((pos + n < text.length) && (line[n] != 10) && (line[n] != 13)):
			n = n + 1
		pos = pos + n
		if (pos < text.length):
			if ((text.data[pos] == 13) && (pos + 1 < text.length) && (text.data[pos + 1] == 10)):
				pos = pos + 1
			pos = pos + 1
		if ((n == 0) || (line[0] == '#')):
			continue
		if (pd_line_starts(line, n, c"expect ")):
			pd_step* e = new pd_step()
			e.is_send = 0
			e.data = pd_decode(line + 7, n - 7)
			e.lineno = lineno
			steps.push(e)
			continue
		if (pd_line_starts(line, n, c"send ")):
			pd_step* s = new pd_step()
			s.is_send = 1
			s.data = pd_decode(line + 5, n - 5)
			s.lineno = lineno
			steps.push(s)
			continue
		pd_buf* msg = pd_buf_new()
		pd_buf_cstr(msg, path)
		pd_buf_push(msg, ':')
		pd_buf_cstr(msg, itoa(lineno))
		pd_buf_cstr(msg, c": unknown directive: ")
		pd_repr(msg, line, n, 0)
		pd_buf_push(msg, 10)
		pd_err_buf(msg)
		exit(1)
	return steps


/* The child under the pty. */

int pd_pid
int pd_fd
pd_buf* pd_received    # everything read from the master so far
int pd_consumed        # expects match only past this offset
int pd_eof


# Execs argv[0] like execvp: directly when it contains '/', otherwise
# through each PATH entry (default ":/bin:/usr/bin", an empty entry
# meaning the current directory). Returns only on failure, with the
# errno of the last attempt that failed for a reason other than ENOENT
# (else ENOENT).
int pd_execvp(char** argv, char** envp):
	char* file = argv[0]
	int i = 0
	while (file[i] != 0):
		if (file[i] == '/'):
			return execve(file, argv, envp)
		i = i + 1
	char* path = env_get(c"PATH")
	if (path == 0):
		path = c":/bin:/usr/bin"
	int result = 0 - 2
	int start = 0
	int done = 0
	while (done == 0):
		int end = start
		while ((path[end] != 0) && (path[end] != ':')):
			end = end + 1
		pd_buf* candidate = pd_buf_new()
		if (end > start):
			pd_buf_append(candidate, path + start, end - start)
			pd_buf_push(candidate, '/')
		pd_buf_cstr(candidate, file)
		int err = execve(candidate.data, argv, envp)
		if (err != (0 - 2)):
			result = err
		if (path[end] == 0):
			done = 1
		start = end + 1
	return result


void pd_spawn(char** argv, char** envp):
	int master = -1
	int slave = -1
	int err = pty_open(&master, &slave)
	if (err != 0):
		pd_buf* msg = pd_buf_new()
		pd_buf_cstr(msg, c"pty_drive: cannot open a pty: errno ")
		pd_buf_cstr(msg, itoa(0 - err))
		pd_buf_push(msg, 10)
		pd_err_buf(msg)
		exit(1)
	int pid = fork()
	if (pid < 0):
		pd_buf* fmsg = pd_buf_new()
		pd_buf_cstr(fmsg, c"pty_drive: fork failed: errno ")
		pd_buf_cstr(fmsg, itoa(0 - pid))
		pd_buf_push(fmsg, 10)
		pd_err_buf(fmsg)
		exit(1)
	if (pid == 0):
		close(master)
		if (pty_login_tty(slave) != 0):
			exit(127)
		int exec_err = pd_execvp(argv, envp)
		pd_buf* emsg = pd_buf_new()
		pd_buf_cstr(emsg, c"exec ")
		pd_buf_cstr(emsg, argv[0])
		pd_buf_cstr(emsg, c" failed: errno ")
		pd_buf_cstr(emsg, itoa(0 - exec_err))
		pd_buf_push(emsg, 10)
		pd_err_buf(emsg)
		exit(127)
	close(slave)
	pd_pid = pid
	pd_fd = master
	pd_received = pd_buf_new()
	pd_consumed = 0
	pd_eof = 0


# Reads whatever arrives within ms milliseconds; sets pd_eof at EOF (a
# read error, EIO once the slave side is closed, counts as EOF).
void pd_pump(int ms):
	if (pd_eof):
		return
	if (ms < 0):
		ms = 0
	int ready = poll_single(pd_fd, poll_in(), ms)
	if (ready <= 0):
		return
	char* chunk = malloc(65536)
	int n = read(pd_fd, chunk, 65536)
	if (n <= 0):
		pd_eof = 1
	else:
		pd_buf_append(pd_received, chunk, n)
	free(chunk)


# The last 500 unconsumed bytes, as a Python bytes repr.
void pd_tail(pd_buf* out):
	int start = pd_consumed
	if (pd_received.length - start > 500):
		start = pd_received.length - 500
	pd_repr(out, pd_received.data + start, pd_received.length - start, 1)


void pd_kill():
	kill(pd_pid, 9)
	int status = 0
	wait4(pd_pid, &status, 0, 0)


# Prints "pty_drive: <msg>" and the output tail, kills the child, exits 1.
void pd_fail(pd_buf* message):
	pd_buf* out = pd_buf_new()
	pd_buf_cstr(out, c"pty_drive: ")
	pd_buf_append(out, message.data, message.length)
	pd_buf_cstr(out, c"\npty_drive: unconsumed output tail: ")
	pd_tail(out)
	pd_buf_push(out, 10)
	pd_err_buf(out)
	pd_kill()
	exit(1)


pd_buf* pd_step_message(char* script_path, int lineno, char* what):
	pd_buf* m = pd_buf_new()
	pd_buf_cstr(m, script_path)
	pd_buf_push(m, ':')
	pd_buf_cstr(m, itoa(lineno))
	pd_buf_cstr(m, c": ")
	pd_buf_cstr(m, what)
	return m


void pd_fail_exit_timeout(int timeout_ms):
	pd_buf* m = pd_buf_new()
	pd_buf_cstr(m, c"timeout (")
	pd_format_seconds(m, timeout_ms)
	pd_buf_cstr(m, c"s) waiting for the command to exit")
	pd_fail(m)


int pd_run(char* script_path, char** argv, char** envp, int timeout_ms):
	list[pd_step*] steps = pd_parse_script(script_path)
	pd_spawn(argv, envp)
	int k = 0
	while (k < steps.length):
		pd_step* step = steps[k]
		k = k + 1
		int deadline = time_monotonic_ms() + timeout_ms
		if (step.is_send):
			int off = 0
			while (off < step.data.length):
				int w = write(pd_fd, step.data.data + off, step.data.length - off)
				if (w < 0):
					pd_buf* sm = pd_step_message(script_path, step.lineno, c"send failed: errno ")
					pd_buf_cstr(sm, itoa(0 - w))
					pd_fail(sm)
				off = off + w
			continue
		while (pd_buf_find(pd_received, step.data, pd_consumed) < 0):
			int remaining = deadline - time_monotonic_ms()
			if (pd_eof):
				pd_buf* em = pd_step_message(script_path, step.lineno, c"EOF before expected ")
				pd_repr(em, step.data.data, step.data.length, 1)
				pd_fail(em)
			if (remaining <= 0):
				pd_buf* tm = pd_step_message(script_path, step.lineno, c"timeout (")
				pd_format_seconds(tm, timeout_ms)
				pd_buf_cstr(tm, c"s) waiting for ")
				pd_repr(tm, step.data.data, step.data.length, 1)
				pd_fail(tm)
			if (remaining > 250):
				remaining = 250
			pd_pump(remaining)
		pd_consumed = pd_buf_find(pd_received, step.data, pd_consumed) + step.data.length

	# Script done: drain to EOF, then the child must exit 0.
	int final_deadline = time_monotonic_ms() + timeout_ms
	while (pd_eof == 0):
		if (time_monotonic_ms() >= final_deadline):
			pd_fail_exit_timeout(timeout_ms)
		pd_pump(250)
	# Pre-zeroed: the kernel writes a 32-bit status into a word.
	int status = 0
	int reaped = 0
	while (reaped == 0):
		int r = wait4(pd_pid, &status, 1, 0)
		if (r < 0):
			# Like the original: a failed wait counts as a clean exit.
			status = 0
			reaped = 1
		else:
			if (r != 0):
				reaped = 1
			else:
				if (time_monotonic_ms() >= final_deadline):
					pd_fail_exit_timeout(timeout_ms)
				sleep_ms(50)
	close(pd_fd)
	int sig = status & 127
	int code = (status >> 8) & 255
	if ((sig == 0) && (code == 0)):
		pd_write_all(1, c"pty script OK\n", 14)
		return 0
	pd_buf* out = pd_buf_new()
	if ((sig != 0) && (sig != 127)):
		pd_buf_cstr(out, c"pty_drive: command killed by signal ")
		pd_buf_cstr(out, itoa(sig))
	else:
		pd_buf_cstr(out, c"pty_drive: command exited ")
		pd_buf_cstr(out, itoa(code))
	pd_buf_cstr(out, c"\npty_drive: unconsumed output tail: ")
	pd_tail(out)
	pd_buf_push(out, 10)
	pd_err_buf(out)
	return 1


/* Command line. */

void pd_die(char* message):
	pd_buf* m = pd_buf_new()
	pd_buf_cstr(m, message)
	pd_buf_push(m, 10)
	pd_err_buf(m)
	exit(1)


# "SECONDS[.fraction]" -> milliseconds (fraction truncated to ms), or -1.
int pd_parse_timeout(char* s):
	int i = 0
	int seconds = 0
	int digits = 0
	while ((s[i] >= '0') && (s[i] <= '9')):
		seconds = seconds * 10 + (s[i] - '0')
		i = i + 1
		digits = digits + 1
	int ms = 0
	if (s[i] == '.'):
		i = i + 1
		int scale = 100
		while ((s[i] >= '0') && (s[i] <= '9')):
			ms = ms + (s[i] - '0') * scale
			scale = scale / 10
			i = i + 1
			digits = digits + 1
	if ((digits == 0) || (s[i] != 0)):
		return -1
	return seconds * 1000 + ms


# rm -rf dir && mkdir -p dir; returns HOME's value (absolute dir).
char* pd_fresh_home(char* dir):
	shell_commands_rm_one(dir, 1, 1)
	if (shell_commands_mkdir_one(dir, 1) != 0):
		pd_die(c"pty_drive: --fresh-home: cannot create the directory")
	if (dir[0] == '/'):
		return dir
	char* cwd = malloc(4096)
	if (getcwd(cwd, 4096) < 0):
		pd_die(c"pty_drive: --fresh-home: getcwd failed")
	char* with_slash = strjoin(cwd, c"/")
	return strjoin(with_slash, dir)


# NULL-terminated copy of av[from..to).
char** pd_strv_from(char** av, int from, int to):
	char* vector = malloc((to - from + 1) * __word_size__)
	int k = 0
	while (from + k < to):
		save_word(vector + k * __word_size__, cast(int, av[from + k]))
		k = k + 1
	save_word(vector + k * __word_size__, 0)
	return cast(char**, vector)


int main(int argc, int argv):
	char** av = cast(char**, argv)
	int i = 1
	int timeout_ms = 30000
	char* fresh_home = 0
	int options = 1
	while (options && (i < argc)):
		options = 0
		if (strcmp(av[i], c"--timeout") == 0):
			if (i + 1 >= argc):
				pd_die(c"pty_drive: --timeout needs a value")
			timeout_ms = pd_parse_timeout(av[i + 1])
			if (timeout_ms < 0):
				pd_die(c"pty_drive: --timeout needs a number of seconds")
			i = i + 2
			options = 1
		else:
			if (strcmp(av[i], c"--fresh-home") == 0):
				if (i + 1 >= argc):
					pd_die(c"pty_drive: --fresh-home needs a directory")
				fresh_home = av[i + 1]
				i = i + 2
				options = 1
	if ((i < argc) && (strcmp(av[i], c"--") == 0)):
		i = i + 1
	if (argc - i < 2):
		pd_die(c"bin/pty_drive [--timeout SECONDS] [--fresh-home DIR] SCRIPT [--] CMD [ARG...]")
	char* script_path = av[i]
	i = i + 1
	if (strcmp(av[i], c"--") == 0):
		i = i + 1
	if (i >= argc):
		pd_die(c"pty_drive: no command given")
	char** child_argv = pd_strv_from(av, i, argc)
	char** envp = env_current()
	if (fresh_home != 0):
		envp = env_copy_with(envp, c"HOME", pd_fresh_home(fresh_home))
	return pd_run(script_path, child_argv, envp, timeout_ms)
