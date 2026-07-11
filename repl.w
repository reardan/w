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
*/
import repl.core
import repl.scan
import compiler.compiler
import structures.string
import lib.args
import lib.line_edit
import lib.format
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


# Read one line into repl_line via the line editor (raw-mode editing and
# history on a tty, plain reads otherwise). indent > 0 seeds that many
# editable tabs. Returns the length, -1 on end of input, -2 when the
# line was discarded with Ctrl-C.
int repl_prompt_line(char* prompt, int indent):
	string_clear(repl_line)
	if (repl_read_buffer == 0):
		repl_read_buffer = malloc(4096)
	char* initial = 0
	if (indent > 0):
		initial = malloc(indent + 1)
		for int t in range(indent):
			initial[t] = 9
		initial[indent] = 0
	int n = line_edit_read(prompt, repl_read_buffer, 4096, initial)
	if (initial != 0):
		free(initial)
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
	while ((s[i] == 9) | (s[i] == ' ')):
		i = i + 1
	int j = 0
	while (word[j]):
		if (s[i + j] != word[j]):
			return 0
		j = j + 1
	char c = s[i + j]
	if ((('a' <= c) & (c <= 'z')) | (('A' <= c) & (c <= 'Z')) |
			(('0' <= c) & (c <= '9')) | (c == '_')):
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
	int r = repl_prompt_line(c"w> ", 0)
	if (r == -1):
		return 0
	if (r == -2):
		return 1 /* discarded: the empty entry is a no-op */
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
		if (block_mode & repl_line_only_tabs() & (open_state == 0)):
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
	if ((word_size == 8) & (type == float64_value_type)):
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
	if ((pointers > 0) | (type == 4)):
		println(hex(value))
		return;
	println(itoa(value))


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
	println(c"commands: :quit exits, :help shows this text")


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

	println(c"w repl - :quit exits, :help for help")

	repl_interactive = term_isatty(0)
	if (repl_interactive):
		line_edit_history_load(c"~/.w_history")
	repl_line = string_new()
	repl_entry = string_new()
	# Echo printing is this front end's policy: the engine calls the hook
	# with a bare expression's value and compile-time type, inside its
	# fault window (echoing can dereference a bad pointer too).
	repl_echo_hook = cast(int, repl_echo)
	while (1):
		if (repl_read_entry() == 0):
			println(c"")
			repl_cleanup()
			exit(0)
		if (string_equals(repl_entry, c":quit")):
			repl_cleanup()
			exit(0)
		if (string_equals(repl_entry, c":help")):
			repl_print_help()
			continue
		if (repl_entry.length == 0):
			continue
		if (repl_scan_string):
			# The tokenizer cannot recover from an unterminated string
			println(c"unterminated string literal, entry discarded")
			continue
		repl_eval(repl_entry.data)
	return 0
