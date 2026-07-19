/*
Interactive REPL: the command-line front end.

The session and eval engine live in repl/core.w: each entry (possibly
spanning several lines, Python-style) is staged to a per-session temp
file and compiled into an executable mmap buffer as a fresh anonymous
function that is called immediately. Declarations persist for the whole
session, and both compile errors and runtime faults roll the failed
entry back instead of exiting. repl/scan.w is the continuation scanner
that decides when an entry needs more lines.

This file owns the I/O policy around that engine: argument parsing, the
banner, the prompt loop with auto-indent (raw-mode editing and
persistent history via lib/line_edit.w), the :commands, and echo
printing. When an entry is a single bare expression, the engine reports
its value and compile-time type, and repl_echo() here formats and
prints it (char* as a string, floats through the float formatters,
struct values as JSON, other pointers as hex).

Run a file first with "repl file.w [args...]": it is compiled into the
same buffer, its main() runs (unless --no_main), and the prompt attaches
with every function and global from the file still live.

A 'debugger' statement in an entry (or in code an entry calls) traps
into wdbg's command loop (debugger/wdbg.w): the debugger works on the
same in-process buffer model the REPL runs on, so breakpoints, stepping
and inspection all apply to code compiled at the prompt. 'c' resumes the
entry and returns to the prompt.

Commands: :quit exits, :help prints a summary.

Scripted/agent mode (issue #276 P3): when stdin is not a tty, or --quiet
or --json is passed, the banner and the w>/.. prompts move to stderr so
a piped consumer's stdout carries only program output and echoes. -e
"entry" evaluates one entry (repeatable, in order) after startup and
exits, without a prompt loop. --json emits one NDJSON object per entry
on stdout instead of the plain echo.

'!' is a reader-level shell escape, recognized before any entry reaches
the compiler: "!cmd args" runs cmd through lib/shell.w with this
process's own stdio (see repl_handle_bang); "!cd" and "!export NAME=VAL"
are intercepted builtins that change this process's own cwd/environment.

":sh" toggles shell mode (issue #335, docs/projects/repl_shell_mode.md):
the prompt changes, and a bare line is parsed as a shell command instead
of W -- translated to a native lib/shell_commands.w call when
repl/shell_translate.w's recognition test passes, else farmed out to
lib/shell.w's sh_interactive exactly like "!cmd" is in W mode. "!" still
works in shell mode, but with its meaning flipped: it runs exactly one
line as W, then returns to shell-mode dispatch. "cd"/"export" are
intercepted the same way "!cd"/"!export" already are.

Interactive editing (issue #276 P2, lib/line_edit.w): Tab completes the
identifier before the cursor from the live symbol table
(repl_complete_names, wired to line_edit.w's le_complete_hook below);
Ctrl-R is an incremental reverse history search; a terminal-driven
bracketed paste is inserted atomically -- repl_prompt_line and
repl_read_entry check line_edit_in_paste() to suspend auto-indent seeding
and the blank-line-ends-the-entry rule for as long as a paste is still
open, so pasted blank lines and indentation survive intact.
*/
import repl.core
import repl.scan
import repl.shell_translate
import compiler.compiler
import structures.string
import structures.json
import lib.args
import lib.line_edit
import lib.format
import lib.path
import lib.time
import lib.shell
import lib.__arch__.repl_echo_float64
import debugger.wdbg


# ---------------------------------------------------------------------------
# Reading entries from stdin.

string_builder* repl_line
string_builder* repl_entry

# 1 when stdin is a terminal. Auto-indent only makes sense interactively:
# piped scripts carry their own explicit tabs.
int repl_interactive

# Tabs the next continuation line starts with (echoed after the prompt
# and stored into the entry, so what you see is what compiles).
int repl_auto_indent


# Scratch buffer for the line editor.
char* repl_read_buffer

# 1 when --json was passed: entries (from -e and from the prompt loop)
# report through repl_json_echo_hook and repl_eval_json instead of the
# plain repl_echo printer, and repl_interactive is forced off (see main).
int repl_json_mode

# The most recent entry's formatted echo, filled in by repl_json_echo_hook
# for repl_eval_json to pick up; 0 means "no echoable value" (matches
# repl_format_echo's return convention).
char* repl_json_echo_captured


# 1 when ":sh" has toggled shell mode on: the prompt changes ("sh> "),
# and a bare line (not starting with '!') is parsed as a shell command
# instead of W (issue #335, docs/projects/repl_shell_mode.md Sec 4).
int repl_shell_mode

# 1 once "import lib.shell_commands as shell_commands" has been
# eval'd into the live session, so a later ":sh" toggle does not
# re-import. Cleared by ":reset", which rolls the import back too.
int repl_shell_commands_imported


# Plain, unbuffered-prompt line read used in scripted/agent mode
# (repl_interactive == 0) instead of the raw-mode line editor: mirrors
# lib/line_edit.w's le_read_plain exactly, except the prompt goes to
# stderr (print_error) rather than stdout, so a piped consumer's stdout
# carries only program output and echoes (issue #276 P3 / D5). Bypassing
# line_edit_read entirely (rather than passing it an empty prompt) also
# means --quiet/--json force this same plain path even when stdin is
# genuinely a tty (e.g. a pty-wrapped agent harness): raw mode and its
# ANSI rendering only make sense for a human at a real prompt.
int repl_read_plain(char* prompt, char* buf, int size):
	print_error(prompt)
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


# Read one line into repl_line: the line editor (raw-mode editing and
# history) on a real interactive tty, repl_read_plain otherwise. indent
# > 0 seeds that many editable tabs (interactive only; repl_read_plain
# ignores it, like line_edit_read's own non-tty fallback does). Returns
# the length, -1 on end of input, -2 when the line was discarded with
# Ctrl-C.
int repl_prompt_line(char* prompt, int indent):
	string_clear(repl_line)
	if (repl_read_buffer == 0):
		repl_read_buffer = malloc(4096)
	int n = 0
	if (repl_interactive == 0):
		n = repl_read_plain(prompt, repl_read_buffer, 4096)
		if (n < 0):
			return n
		string_append(repl_line, repl_read_buffer)
		return n
	# A bracketed paste begun on an earlier physical line of this same
	# entry is still open (line_edit_read has not seen its end marker
	# yet): the pasted text supplies its own indentation, so seeding an
	# auto-indent prefix on top of it would double it up (issue #276 P2).
	if (line_edit_in_paste()):
		indent = 0
	char* initial = 0
	if (indent > 0):
		initial = malloc(indent + 1)
		for int t in range(indent):
			initial[t] = 9
		initial[indent] = 0
	defer free(initial)
	n = line_edit_read(prompt, repl_read_buffer, 4096, initial)
	if (n < 0):
		return n
	string_append(repl_line, repl_read_buffer)
	return n


int repl_count_leading_tabs(char* s):
	int n = 0
	while (s[n] == 9):
		n = n + 1
	return n


# 1 when the line's first token is exactly word (after leading whitespace).
int repl_first_token_is(char* s, char* word):
	int i = 0
	while ((s[i] == 9) || (s[i] == ' ')):
		i = i + 1
	int j = 0
	while (word[j]):
		if (s[i + j] != word[j]):
			return 0
		j = j + 1
	char c = s[i + j]
	if ((('a' <= c) && (c <= 'z')) || (('A' <= c) && (c <= 'Z')) ||
			(('0' <= c) && (c <= '9')) || (c == '_')):
		return 0
	return 1


# Update repl_auto_indent from the line just scanned. line_indent is the
# indent the line actually got (auto tabs plus any the user typed).
# A ':' opens a deeper level; a line that leaves its block (return,
# break, continue, pass) comes back out one level, like Python's IDLE.
void repl_update_indent(char* typed, int line_indent):
	if (repl_scan_last_char == ':'):
		repl_auto_indent = line_indent + 1
	else if (repl_scan_last_char == 0):
		pass /* blank or comment-only line: keep the current level */
	else if (repl_first_token_is(typed, c"return") | repl_first_token_is(typed, c"break") |
			repl_first_token_is(typed, c"continue") | repl_first_token_is(typed, c"pass")):
		repl_auto_indent = line_indent - 1
		if (repl_auto_indent < 0):
			repl_auto_indent = 0
	else:
		repl_auto_indent = line_indent


# 1 when the line contains nothing but tabs (or is empty): the user
# pressed Enter without typing past the auto-indent.
int repl_line_only_tabs():
	return repl_count_leading_tabs(repl_line.data) == repl_line.length


# Read one entry (possibly several lines) into repl_entry; returns 0 on
# end of input at the primary prompt. Continuation rules, Python-style:
# a line whose last significant character is ':' opens a block that ends
# at the next blank line; unbalanced brackets, an open block comment or
# an open string literal keep the entry going regardless of blank lines.
# On a terminal, continuation lines start seeded with editable
# auto-indent tabs; a blank line dedents one level, and a blank line at
# column 0 ends the entry. Ctrl-C discards the whole entry.
int repl_read_entry():
	string_clear(repl_entry)
	repl_scan_reset()
	repl_auto_indent = 0
	char* prompt = c"w> "
	if (repl_shell_mode):
		prompt = c"sh> "
	int r = repl_prompt_line(prompt, 0)
	if (r == -1):
		return 0
	if (r == -2):
		return 1 /* discarded: the empty entry is a no-op */
	if (repl_line.data[0] == '!'):
		# '!' escape: always a single line, taken verbatim, so shell syntax
		# (unbalanced quotes, parens in a command line) never confuses the
		# W-syntax continuation scanner below. In W mode this is
		# repl_handle_bang's shell escape; in shell mode main()'s dispatch
		# flips its meaning to "run this one line as W instead" (Sec 4) --
		# either way it is exactly one line, never scanned.
		string_append(repl_entry, repl_line.data)
		return 1
	if (repl_shell_mode):
		# Shell mode never spans multiple lines in v1 (design doc Sec 4):
		# shell syntax must never reach the W bracket/string/comment
		# continuation scanner below, for the same reason the '!' escape's
		# line is taken verbatim above.
		string_append(repl_entry, repl_line.data)
		return 1
	string_append(repl_entry, repl_line.data)
	repl_scan_line(repl_line.data)
	int block_mode = (repl_scan_last_char == ':')
	int open_state = repl_scan_open()
	repl_update_indent(repl_line.data, repl_count_leading_tabs(repl_line.data))
	while (block_mode | open_state):
		# Auto-indent applies to block bodies, not bracket/string/comment
		# continuations, and only when a person is typing
		int indent = 0
		if (repl_interactive & block_mode & (open_state == 0)):
			indent = repl_auto_indent
		r = repl_prompt_line(c".. ", indent)
		if (r == -1):
			return 1 /* end of input finishes the entry */
		if (r == -2):
			string_clear(repl_entry)
			return 1 /* Ctrl-C discards the entry */
		# A blank (or tabs-only) line inside a still-open bracketed paste
		# is pasted content, not the user asking to dedent or end the
		# entry -- suspend this rule for as long as the paste is open
		# (issue #276 P2), and simply fall through to appending the line
		# like any other.
		if ((line_edit_in_paste() == 0) & (block_mode & repl_line_only_tabs() & (open_state == 0))):
			int tabs = repl_count_leading_tabs(repl_line.data)
			if (tabs == 0):
				return 1 /* a blank line at column 0 ends the entry */
			repl_auto_indent = tabs - 1
			continue /* a tabs-only line dedents to one level above it */
		string_append_char(repl_entry, 10)
		string_append(repl_entry, repl_line.data)
		repl_scan_line(repl_line.data)
		if (repl_scan_last_char == ':'):
			block_mode = 1
		repl_update_indent(repl_line.data, repl_count_leading_tabs(repl_line.data))
		open_state = repl_scan_open()
	return 1


# ---------------------------------------------------------------------------
# Echoing expression results.

# Print an echoed expression value, formatted by its compile-time type.
void repl_echo(int value, int type):
	if (type <= 0): /* no result, or void */
		return;
	if (type == float32_value_type):
		float* p = cast(float*, &value)
		println(ftoa(*p))
		return;
	if ((word_size == 8) && (type == float64_value_type)):
		println(repl_float64_to_string(value))
		return;
	if (type_is_string(type)):
		write(1, cast(char*, load_word(cast(char*, value))), load_word(value + word_size))
		put_char(10)
		return;
	int pointers = type_get_pointer_level(type)
	if ((pointers == 1) & (strcmp(type_get_name(type), c"char") == 0)):
		if (value == 0):
			println(c"(null)")
		else:
			println(str_from_cstr(cast(char*, value)))
		return;
	if (type_num_args(type) > 0):
		char* rendered = repl_echo_json(type, value)
		if (rendered != 0):
			println(rendered)
		else:
			println(hex(value))
		return;
	if ((pointers > 0) || (type == 4)):
		println(hex(value))
		return;
	println(itoa(value))


# ---------------------------------------------------------------------------
# Colon commands beyond :quit/:help: :symbols, :type, :time, :load, :reset,
# :save. Each is dispatched from a literal ":name" prefix in main()'s loop;
# repl_command_arg trims the text after the command word.

# 1 when entry's command word is exactly cmd (e.g. ":type"): cmd must be
# followed by whitespace or the end of the string, so ":typewriter" does
# not match ":type".
int repl_command_is(char* entry, char* cmd):
	if (starts_with(entry, cmd) == 0):
		return 0
	char c = entry[strlen(cmd)]
	return (c == 0) | (c == ' ') | (c == 9)


# The text after a ':command' word, leading whitespace trimmed (empty
# when none was given). Only meaningful when repl_command_is(entry, cmd)
# holds; the result points inside entry, so it is only valid until
# repl_entry is next cleared.
char* repl_command_arg(char* entry, char* cmd):
	char* rest = entry + strlen(cmd)
	while ((rest[0] == ' ') || (rest[0] == 9)):
		rest = rest + 1
	return rest


# Trims trailing spaces/tabs from s in place.
void repl_rtrim(char* s):
	int n = strlen(s)
	while ((n > 0) && ((s[n - 1] == ' ') || (s[n - 1] == 9))):
		n = n - 1
		s[n] = 0


# A compile-time type as :type prints it: value pseudo-types (the echo
# path's "eax already holds the value" convention) collapse to their
# ordinary source name, and one '*' prints per pointer level.
char* repl_type_name(int type):
	if (type == -1):
		return strclone(c"(no value)")
	if (type == 0):
		return strclone(c"void")
	if (type == 3): /* "constant": an untyped literal/address/call result */
		return strclone(c"int")
	if (type == float32_value_type):
		return strclone(c"float32")
	if (type == float64_value_type):
		return strclone(c"float64")
	if (type == var_value_type):
		return strclone(c"var")
	if (type_is_string(type)):
		return strclone(c"string")
	char* base = strclone(type_get_name(type))
	int pointers = type_get_pointer_level(type)
	int i = 0
	while (i < pointers):
		char* starred = strjoin(base, c"*")
		free(base)
		base = starred
		i = i + 1
	return base


# :type expr -- compiles expr like a normal entry (its declarations
# persist) but does not run it, so a call or assignment in expr has no
# side effect; only its compile-time type prints. Sets repl_no_run
# (repl/core.w) around the eval rather than a second eval path.
void repl_cmd_type(char* expr):
	if (expr[0] == 0):
		println(c"usage: :type <expression>")
		return;
	repl_no_run = 1
	repl_result r = repl_eval(expr)
	repl_no_run = 0
	if (r.status == 1):
		char* tn = repl_type_name(r.echo_type)
		println(tn)
		free(tn)


# :time expr -- evaluates expr exactly like a normal entry (it echoes as
# usual) and prints the wall-clock time it took.
void repl_cmd_time(char* expr):
	if (expr[0] == 0):
		println(c"usage: :time <expression>")
		return;
	int started = time_monotonic_ms()
	repl_eval(expr)
	int elapsed = time_monotonic_ms() - started
	printf1(c"elapsed: %dms\n", elapsed)


# :load file -- compiles file into the session buffer and runs its
# main() (unless it has none), exactly like starting "repl file.w" does:
# every function and global it defines is then live for later entries. A
# compile error in the file exits the REPL, matching that startup path --
# there is no per-entry checkpoint around a file load to roll back to.
void repl_cmd_load(char* path):
	repl_rtrim(path)
	if (path[0] == 0):
		println(c"usage: :load <file>")
		return;
	if (path_exists(path) == 0):
		printf1(c"no such file: %s\n", cast(int, path))
		return;
	char* argv_holder = malloc(__word_size__)
	save_word(argv_holder, cast(int, path))
	int ran = repl_load_file(path, 1, 1, cast(int, argv_holder))
	free(argv_holder)
	if (ran == 0):
		println(c"(loaded file defines no main; its definitions are available)")


# :save file -- concatenates every entry staged so far (repl/core.w keeps
# one file per entry so generic instantiation can re-parse it later)
# into file: a transcript of the session in typed order.
void repl_cmd_save(char* path):
	repl_rtrim(path)
	if (path[0] == 0):
		println(c"usage: :save <file>")
		return;
	if ((repl_staging_dir == 0) || (repl_staged_count == 0)):
		println(c"no entries to save yet")
		return;
	int out = create_file(path, 511)
	if (out < 0):
		printf1(c"could not create file: %s\n", cast(int, path))
		return;
	char* buffer = malloc(65536)
	int i = 0
	while (i < repl_staged_count):
		char* entry_path = repl_entry_path(repl_staging_dir, i)
		int in_fd = open(entry_path, 0, 511)
		if (in_fd >= 0):
			int n = read(in_fd, buffer, 65536)
			while (n > 0):
				write(out, buffer, n)
				n = read(in_fd, buffer, 65536)
			close(in_fd)
		free(entry_path)
		i = i + 1
	free(buffer)
	close(out)
	printf2(c"saved %d entries to %s\n", repl_staged_count, cast(int, path))


# ---------------------------------------------------------------------------
# '!' shell escape (issue #276 P3, research Q4/Q5). Recognized by
# repl_read_entry before any W-syntax scanning runs, so this always sees
# one whole line, verbatim, after the leading '!'.

# "NAME=VALUE" -> setenv(NAME, VALUE) in lib/shell.w's session override,
# so later !cmd / sh() / run_argv() calls see it (the real process
# environment is untouched, like lib/shell.w's setenv always).
void repl_handle_export(char* arg):
	repl_rtrim(arg)
	if (arg[0] == 0):
		println(c"usage: !export NAME=VALUE")
		return;
	int i = 0
	while ((arg[i] != 0) && (arg[i] != '=')):
		i = i + 1
	if (arg[i] != '='):
		println(c"usage: !export NAME=VALUE")
		return;
	char* name = malloc(i + 1)
	int k = 0
	while (k < i):
		name[k] = arg[k]
		k = k + 1
	name[i] = 0
	setenv(name, arg + i + 1)
	free(name)


# "cd DIR" (arg is the text after the "cd" word, not yet trimmed): chdir
# to DIR, or to $HOME when arg is empty, exactly like a real shell's
# builtin cd. Shared by "!cd" (repl_handle_bang) and shell mode's own
# bare "cd" line (repl_dispatch_shell_line) -- both must change this
# process itself, so neither can go through sh_interactive's child.
void repl_do_cd(char* arg):
	char* path = arg
	repl_rtrim(path)
	if (path[0] == 0):
		path = getenv(c"HOME")
		if (path == 0):
			println(c"cd: HOME not set")
			return;
	if (cd(path) != 0):
		printf1(c"cd: %s: no such file or directory\n", cast(int, path))


# rest is the text after the leading '!', not yet trimmed. A bare '!'
# (nothing, or only whitespace, after the mark) is a no-op -- it never
# reaches the compiler either way, since repl_read_entry's '!' check
# already routed it here instead of into the normal entry pipeline.
# "!cd" and "!export" are intercepted builtins that must change this
# process itself (chdir/the session env override), so they cannot go
# through sh_interactive's child process; anything else runs through
# lib/shell.w's sh_interactive with this process's own stdio, so a
# command's output lands wherever the repl's own stdout/stderr currently
# point (a real terminal, or a piped consumer's captured streams).
void repl_handle_bang(char* rest):
	char* cmd = repl_command_arg(rest, c"")
	repl_rtrim(cmd)
	if (cmd[0] == 0):
		return;
	if (repl_command_is(cmd, c"cd")):
		repl_do_cd(repl_command_arg(cmd, c"cd"))
		return;
	if (repl_command_is(cmd, c"export")):
		repl_handle_export(repl_command_arg(cmd, c"export"))
		return;
	sh_interactive(cmd)


# ---------------------------------------------------------------------------
# ":sh" (issue #335, docs/projects/repl_shell_mode.md Sec 4): toggles
# shell mode and, on first entry in a session, synthesizes-and-evals the
# session import that makes lib/shell_commands.w's bare names (ls, cat,
# pwd, ...) resolve for repl/shell_translate.w's generated calls -- the
# same mechanism ":load" already uses to run a file's declarations into
# the live session. The actual line-by-line dispatch once shell mode is
# on is repl_dispatch_shell_line, defined below after repl_eval_json.

void repl_cmd_sh():
	repl_shell_mode = repl_shell_mode == 0
	if (repl_shell_mode):
		if (repl_shell_commands_imported == 0):
			repl_eval(c"import lib.shell_commands as shell_commands")
			repl_shell_commands_imported = 1
		println(c"shell mode on (:sh to leave, ! runs one line of W)")
	else:
		println(c"shell mode off")


# ---------------------------------------------------------------------------
# Scripted/agent mode (issue #276 P3): -e one-shot entries and --json
# NDJSON output. Both are driven from main(); repl_echo_hook is set to
# repl_json_echo_hook instead of repl_echo whenever repl_json_mode is on,
# for -e entries and prompt-loop entries alike.

# Render value/type the same way repl_echo prints it, for --json's "echo"
# field. Returns 0 for "no result" (type <= 0), matching repl_echo's
# silent skip -- callers report that as a JSON null. Deliberately a
# separate function rather than a repl_echo refactor: repl_echo's
# type_is_string case writes the string descriptor's exact bytes straight
# to fd 1 (an embedded NUL would not survive a NUL-terminated char* round
# trip), and duplicating that one case here is simpler than reworking
# repl_echo, which repl_test pins closely, to serve two callers.
char* repl_format_echo(int value, int type):
	if (type <= 0):
		return 0
	if (type == float32_value_type):
		float* p = cast(float*, &value)
		return ftoa(*p)
	if ((word_size == 8) && (type == float64_value_type)):
		return repl_float64_to_string(value)
	if (type_is_string(type)):
		string_builder* b = string_new()
		string_append_bytes(b, cast(char*, load_word(cast(char*, value))), load_word(value + word_size))
		# Take b.data directly (like string_builder_to_string/
		# __w_template_finish do) and free only the wrapper struct --
		# NOT string_free(b) followed by free(b): that combination on the
		# same string_builder corrupts the heap here (see the
		# ai_tooling_next_steps.md entry logged with this change).
		char* s = b.data
		free(b)
		return s
	int pointers = type_get_pointer_level(type)
	if ((pointers == 1) & (strcmp(type_get_name(type), c"char") == 0)):
		if (value == 0):
			return strclone(c"(null)")
		return strclone(cast(char*, value))
	if (type_num_args(type) > 0):
		char* rendered = repl_echo_json(type, value)
		if (rendered != 0):
			return rendered
		return hex(value)
	if ((pointers > 0) || (type == 4)):
		return hex(value)
	return itoa(value)


# --json's echo hook: captures the formatted echo into repl_json_echo_captured
# instead of printing it, so repl_eval_json can fold it into the entry's
# NDJSON record. Runs inside repl_eval's fault window exactly like
# repl_echo does, so a bad echo (e.g. a garbage char*) still rolls the
# entry back instead of crashing the session.
void repl_json_echo_hook(int value, int type):
	repl_json_echo_captured = repl_format_echo(value, type)


# Read back a capture file written by repl_eval_json in full, as a
# malloc'd NUL-terminated string ("" when the file is empty or missing).
# Embedded NULs in the entry's own output are not preserved -- the same
# caveat repl_format_echo documents for the string-type echo case.
char* repl_json_read_capture(char* path):
	string_builder* b = string_new()
	int f = open(path, 0, 0)
	if (f >= 0):
		char* buf = malloc(4096)
		int n = read(f, buf, 4096)
		while (n > 0):
			string_append_bytes(b, buf, n)
			n = read(f, buf, 4096)
		free(buf)
		close(f)
	# Same ownership-transfer idiom as repl_format_echo's string case
	# above, and for the same reason: string_free(b) then free(b) on the
	# same builder corrupts the heap in this context.
	char* result = b.data
	free(b)
	return result


# Evaluate one entry and print a single NDJSON record to stdout:
# {"entry": ..., "output": ..., "echo": ..., "error": ...}.
#
# "output" is the entry's own captured stdout: fd 1 is redirected to a
# scratch file (via a saved dup on a scratch fd) for the exact span of
# the repl_eval call and restored right after, so this works whether the
# entry compiled, ran, faulted or rolled back. It is omitted -- per the
# design doc's "if not cheaply capturable, omit and document" escape
# hatch -- only when the redirect itself could not be set up (e.g. no
# writable /tmp); in that rare case the entry's prints go straight to the
# real stdout as they normally would, interleaved with the NDJSON lines.
#
# "echo" is null when the entry produced no echoable value (or failed).
# "error" is null on success, else a short category ("compile error" /
# "runtime fault") -- the diagnostic text itself already went to stderr
# through the normal channels (error()'s reporting / repl_fault), exactly
# like the plain front end. Returns 1 on success, 0 otherwise.
int repl_eval_json(char* entry_text):
	repl_json_echo_captured = 0

	int saved_stdout = 90 /* an fd well above what a repl session otherwise opens */
	int have_saved = (dup2(1, saved_stdout) >= 0)
	char* cap_path = 0
	int captured = 0
	if (have_saved):
		cap_path = cstr(f"/tmp/w_repl_json_{getpid()}.out")
		int cap = create_file(cap_path, 511)
		if (cap >= 0):
			dup2(cap, 1)
			close(cap)
			captured = 1

	repl_result r = repl_eval(entry_text)

	char* output = 0
	if (captured):
		dup2(saved_stdout, 1)
		output = repl_json_read_capture(cap_path)
		unlink(cap_path)
	if (have_saved):
		close(saved_stdout)
	free(cap_path)

	json_value* rec = json_object()
	json_object_set(rec, c"entry", json_string(entry_text))
	if (output != 0):
		json_object_set(rec, c"output", json_string(output))
		free(output)
	if (repl_json_echo_captured != 0):
		json_object_set(rec, c"echo", json_string(repl_json_echo_captured))
		free(repl_json_echo_captured)
		repl_json_echo_captured = 0
	else:
		json_object_set(rec, c"echo", json_null())
	if (r.status == 1):
		json_object_set(rec, c"error", json_null())
	else if (r.status == 2):
		json_object_set(rec, c"error", json_string(c"runtime fault"))
	else:
		json_object_set(rec, c"error", json_string(c"compile error"))
	char* line = json_stringify(rec)
	json_free(rec)
	println(line)
	free(line)
	return r.status == 1


# ---------------------------------------------------------------------------
# Shell mode dispatch (":sh", issue #335, docs/projects/repl_shell_mode.md
# Sec 4/7). Dispatch one shell-mode line (never starting with '!' -- main()
# has already peeled that case off and run it as W instead): "cd"/"export"
# are intercepted exactly like the '!' escape does; else a native
# lib/shell_commands.w call when repl/shell_translate.w's recognition test
# passes; else the whole line, verbatim, to sh_interactive -- the same
# "farm out to native" fallback the '!' escape already uses. Defined after
# repl_eval_json, which it calls under --json.
void repl_dispatch_shell_line(char* line):
	if (line[0] == 0):
		return;
	if (repl_command_is(line, c"cd")):
		repl_do_cd(repl_command_arg(line, c"cd"))
		return;
	if (repl_command_is(line, c"export")):
		repl_handle_export(repl_command_arg(line, c"export"))
		return;
	char* translated = shell_translate_line(line)
	if (translated != 0):
		if (repl_json_mode):
			repl_eval_json(translated)
		else:
			repl_eval(translated)
		free(translated)
		return;
	sh_interactive(line)


# Every "-e"/"--e" occurrence's value, in argv order (repl_run_e_mode
# evaluates each in turn). "-e=text" and "-e text" (the following token,
# unless it is itself a flag) both work, matching lib/args.w's usual flag
# conventions; unlike args_value() this collects every occurrence instead
# of only the first, so repeated -e flags all take effect.
list[char*] repl_collect_e_entries():
	list[char*] entries = new list[char*]
	int i = 1
	while (i < args_count()):
		char* body = args_flag_body(args_get(i))
		if (body != 0):
			if ((body[0] == 'e') && ((body[1] == 0) || (body[1] == '='))):
				char* value = 0
				if (body[1] == '='):
					value = body + 2
				else:
					char* next = args_get(i + 1)
					if (next != 0):
						if (args_flag_body(next) == 0):
							value = next
							i = i + 1
				if (value != 0):
					entries.push(value)
		i = i + 1
	return entries


# -e "entry" (repeatable): evaluate each entry in order, as if typed at
# the prompt, then exit -- no prompt loop. Exit status is 0 when every
# entry compiled and ran cleanly, 1 if any of them failed to compile or
# faulted. repl_echo_hook must already be set by the caller (repl_echo
# for plain output, repl_json_echo_hook under --json); this only drives
# repl_eval/repl_eval_json and tallies failures. Always exits; never
# returns.
void repl_run_e_mode(list[char*] entries, int json_mode):
	int had_error = 0
	int i = 0
	while (i < entries.length):
		if (json_mode):
			if (repl_eval_json(entries[i]) == 0):
				had_error = 1
		else:
			repl_result r = repl_eval(entries[i])
			if (r.status != 1):
				had_error = 1
		i = i + 1
	repl_cleanup()
	if (had_error):
		exit(1)
	exit(0)


void repl_print_help():
	println(c"entries compile and run immediately; definitions persist:")
	println(c"  int x = 5           a variable that later entries can use")
	println(c"  x := 5              a variable with the type inferred from its value")
	println(c"  int f(int a):       a function (finish the block, then a blank line)")
	println(c"  struct p: / import  structs and modules work too")
	println(c"a line ending in ':' opens a block and indents automatically;")
	println(c"return/break/continue/pass dedent; a blank line dedents one level")
	println(c"and ends the entry at column 0")
	println(c"a single bare expression echoes its value")
	println(c"commands:")
	println(c"  :quit               exit the repl")
	println(c"  :help               show this text")
	println(c"  :symbols            dump the live symbol table (to stderr)")
	println(c"  :type expr          print expr's compile-time type without running it")
	println(c"  :time expr          run expr and print its wall-clock time")
	println(c"  :load file          compile file and run its main(), like 'repl file.w'")
	println(c"  :reset              undo every entry (and :load) since startup")
	println(c"  :save file          save every entry typed so far to file")
	println(c"  :sh                 toggle shell mode: bare lines parse as shell commands")
	println(c"  !cmd                run cmd through the shell, stdio inherited")
	println(c"  !cd dir             change the repl's own working directory")
	println(c"  !export NAME=VALUE  set an env var for later ! / sh() calls")
	println(c"editing: Tab completes an identifier from the symbol table;")
	println(c"Ctrl-R is an incremental reverse history search; a terminal's")
	println(c"bracketed paste is inserted as one atomic block")
	println(c"flags: -e entry evaluates one entry and exits (repeatable);")
	println(c"--json emits one JSON object per entry on stdout instead of the")
	println(c"plain echo; --quiet routes the banner and prompts to stderr like")
	println(c"a piped session even when stdin is a tty")


int main(int argc, int argv):
	args_init(argc, argv)
	repl_init()

	# 'debugger' statements trap into wdbg's command loop instead of
	# dying on an unhandled SIGTRAP: the debugger state initializes here
	# and the trap handler installs through the same shim machinery the
	# fault handlers use. Faults keep the REPL's own recovery handlers
	# (repl_init installed them above); only SIGTRAP routes to wdbg.
	bp_init()
	dbg_memory_init()
	dbg_rearm_bp = -1
	dbg_disas_read_fn = cast(int, dbg_disas_read_local)
	dbg_disas_symbols = 1
	int trap_handler = cast(int, wdbg_trap_entry)
	if (__word_size__ == 8):
		trap_handler = cast(int, wdbg_trap)
	repl_fault_install(5, trap_handler, 1073741824) /* SIGTRAP, SA_NODEFER */

	# Optional target file: compile it into the same buffer and run its
	# main(), then attach the prompt with all of its symbols live.
	char* target = 0
	int i = 1
	while (i < args_count()):
		if (ends_with(args_get(i), c".w")):
			if (target == 0):
				target = args_get(i)
		i = i + 1
	if (target != 0):
		int run_main = args_has_flag(c"no_main") == 0
		if (repl_load_file(target, run_main, argc, argv) == 0):
			if (run_main):
				println(c"(loaded file defines no main; its definitions are available)")

	# :reset rolls back to this point: everything above (the preloaded
	# stdlib and an optional startup file) stays; every entry typed at
	# the prompt from here on is what :reset undoes.
	repl_genesis_checkpoint()

	# Scripted/agent mode (issue #276 P3, D5): a piped stdin, --quiet or
	# --json all mean a program is driving this session rather than a
	# person, so the banner and w>/.. prompts move to stderr (repl_interactive
	# gates that in repl_prompt_line/repl_read_plain) and the raw-mode line
	# editor (auto-indent, history) stays off even when a real tty happens
	# to be attached -- --quiet/--json force the plain path unconditionally,
	# e.g. for a pty-wrapped agent harness that still wants pure NDJSON.
	int quiet = args_has_flag(c"quiet")
	repl_json_mode = args_has_flag(c"json")
	repl_interactive = term_isatty(0) & (quiet == 0) & (repl_json_mode == 0)

	# Echo printing is this front end's policy: the engine calls the hook
	# with a bare expression's value and compile-time type, inside its
	# fault window (echoing can dereference a bad pointer too). --json
	# routes the same hook mechanism into an NDJSON record instead of a
	# plain println.
	repl_echo_hook = cast(int, repl_echo)
	if (repl_json_mode):
		repl_echo_hook = cast(int, repl_json_echo_hook)

	# Tab completion (issue #276 P2): lib/line_edit.w calls this hook with
	# the identifier prefix before the cursor; repl_complete_names walks
	# the live compiler symbol table for matches. Harmless to set even in
	# non-interactive/--json modes, since line_edit_read (and therefore
	# the hook) is never reached there.
	le_complete_hook = cast(int, repl_complete_names)

	# -e "entry" (repeatable): run the given entries in order and exit,
	# no prompt loop. Collected after the target file and genesis
	# checkpoint so -e entries see the loaded file's definitions, exactly
	# like interactive entries would.
	list[char*] e_entries = repl_collect_e_entries()
	if (e_entries.length > 0):
		repl_run_e_mode(e_entries, repl_json_mode)
		return 0 /* unreachable: repl_run_e_mode always exit()s */

	if (repl_interactive):
		println(c"w repl - :quit exits, :help for help")
	else:
		println2(c"w repl - :quit exits, :help for help")

	if (repl_interactive):
		line_edit_history_load(c"~/.w_history")
	repl_line = string_new()
	repl_entry = string_new()
	while (1):
		if (repl_read_entry() == 0):
			if (repl_interactive):
				println(c"")
			else:
				println2(c"")
			repl_cleanup()
			exit(0)
		if (string_equals(repl_entry, c":quit")):
			repl_cleanup()
			exit(0)
		if (string_equals(repl_entry, c":help")):
			repl_print_help()
			continue
		if (string_equals(repl_entry, c":symbols")):
			print_symbol_table(0)
			continue
		if (string_equals(repl_entry, c":reset")):
			if (repl_reset_to_genesis()):
				# The synthesized shell_commands import (if any) is one of
				# the entries rolled back, so its "already imported" flag
				# must roll back too (Sec 4); if the session is still in
				# shell mode, re-import right away so shell mode keeps
				# working instead of silently breaking until the next
				# ":sh" toggle.
				repl_shell_commands_imported = 0
				if (repl_shell_mode):
					repl_eval(c"import lib.shell_commands as shell_commands")
					repl_shell_commands_imported = 1
				println(c"session reset to its startup state")
			else:
				println(c"nothing to reset (no startup checkpoint)")
			continue
		if (string_equals(repl_entry, c":sh")):
			repl_cmd_sh()
			continue
		if (repl_command_is(repl_entry.data, c":type")):
			repl_cmd_type(repl_command_arg(repl_entry.data, c":type"))
			continue
		if (repl_command_is(repl_entry.data, c":time")):
			repl_cmd_time(repl_command_arg(repl_entry.data, c":time"))
			continue
		if (repl_command_is(repl_entry.data, c":load")):
			repl_cmd_load(repl_command_arg(repl_entry.data, c":load"))
			continue
		if (repl_command_is(repl_entry.data, c":save")):
			repl_cmd_save(repl_command_arg(repl_entry.data, c":save"))
			continue
		if (repl_entry.length == 0):
			continue
		if (repl_entry.data[0] == '!'):
			# '!' always means "the other grammar, for exactly one line"
			# (design doc Sec 4): in W mode it escapes to a shell command
			# (repl_handle_bang); in shell mode it escapes back to W,
			# compiled/run/echoed exactly like an ordinary W-mode entry,
			# after which the loop returns to shell-mode dispatch below.
			if (repl_shell_mode):
				char* w_entry = repl_entry.data + 1
				if (repl_json_mode):
					repl_eval_json(w_entry)
				else:
					repl_eval(w_entry)
			else:
				repl_handle_bang(repl_entry.data + 1)
			continue
		if (repl_shell_mode):
			repl_dispatch_shell_line(repl_entry.data)
			continue
		if (repl_scan_string):
			# The tokenizer cannot recover from an unterminated string
			println(c"unterminated string literal, entry discarded")
			continue
		if (repl_json_mode):
			repl_eval_json(repl_entry.data)
		else:
			repl_eval(repl_entry.data)
	return 0
