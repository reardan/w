/*
Interactive REPL.

Each entry (possibly spanning several lines, Python-style) is staged to a
temp file and compiled into an executable mmap buffer. Declarations --
imports, structs, extern, function definitions and top-level variables --
define symbols that persist for the whole session; executable statements
become the body of a fresh anonymous function that is called immediately.
The standard library is compiled into the same buffer at startup, so
entries can call print, malloc, strjoin and friends directly.

Top-level variable declarations become globals with storage in the code
buffer (jumped over by the entry function), so their values survive
between entries. Redefining a name declares a fresh symbol that shadows
the old one: code compiled earlier keeps its old binding, later entries
see the new one.

When the entry is a single bare expression, its value is echoed, printed
by its compile-time type (char* as a string, other pointers as hex).

Run a file first with "repl file.w [args...]": it is compiled into the
same buffer, its main() runs (unless --no_main), and the prompt attaches
with every function and global from the file still live.

A compile error does not exit: repl_compile_entry checkpoints the
compiler's globals and error() jumps back here (repl_setjmp/repl_longjmp),
after which the checkpoint rolls back the failed entry's code and symbols.

Commands: :quit exits, :help prints a summary.
*/
import compiler.compiler
import structures.string
import lib.args
import lib.line_edit


int repl_counter

# Type of the entry's final bare expression, for echoing; -1 means the
# entry ended with something that should not echo.
int repl_result_type

# The staged entry file's descriptor, so error recovery can close it even
# when the failure happened inside an imported file.
int repl_entry_file


# ---------------------------------------------------------------------------
# Continuation scanner: decides when an entry needs more lines.

int repl_scan_depth      /* ( [ { nesting */
int repl_scan_comment    /* inside a block comment */
int repl_scan_string     /* 0, or the open quote character */
int repl_scan_last_char  /* last significant character of the last line */


# Scan one line of an entry, updating bracket depth, block-comment and
# string-literal state, and the line's last significant character.
# Comment text never counts as significant; quotes and their contents do.
void repl_scan_line(char* s):
	int i = 0
	repl_scan_last_char = 0
	while (s[i]):
		char c = s[i]
		if (repl_scan_comment):
			if ((c == '*') & (s[i + 1] == '/')):
				repl_scan_comment = 0
				i = i + 1
		else if (repl_scan_string):
			if (c == 92):
				# A backslash escapes the next character (if any)
				if (s[i + 1]):
					i = i + 1
			else if (c == repl_scan_string):
				repl_scan_string = 0
			repl_scan_last_char = c
		else if (c == '#'):
			return;
		else if ((c == '/') & (s[i + 1] == '*')):
			repl_scan_comment = 1
			i = i + 1
		else if ((c == '"') | (c == 39)):
			repl_scan_string = c
			repl_scan_last_char = c
		else:
			if ((c == '(') | (c == '[') | (c == '{')):
				repl_scan_depth = repl_scan_depth + 1
			if ((c == ')') | (c == ']') | (c == '}')):
				repl_scan_depth = repl_scan_depth - 1
			if ((c != ' ') & (c != 9)):
				repl_scan_last_char = c
		i = i + 1


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
	repl_scan_depth = 0
	repl_scan_comment = 0
	repl_scan_string = 0
	repl_auto_indent = 0
	int r = repl_prompt_line(c"w> ", 0)
	if (r == -1):
		return 0
	if (r == -2):
		return 1 /* discarded: the empty entry is a no-op */
	string_append(repl_entry, repl_line.data)
	repl_scan_line(repl_line.data)
	int block_mode = (repl_scan_last_char == ':')
	int open_state = (repl_scan_depth > 0) | repl_scan_comment | (repl_scan_string != 0)
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
		open_state = (repl_scan_depth > 0) | repl_scan_comment | (repl_scan_string != 0)
	return 1


# ---------------------------------------------------------------------------
# Compiling entries.

# Emit a jump over a region that must not execute inline in the entry
# function (module code from imports, function bodies, global storage).
# Returns the position to patch with repl_skip_end.
int repl_skip_start():
	jmp_int32(0)
	return codepos


void repl_skip_end(int pos):
	save_int32(code + pos - 4, codepos - pos)


# Declare a global symbol for a REPL definition. An undefined symbol (a
# prototype with pending call sites) is reused so its backpatch chain
# resolves; a defined one gets a fresh entry that shadows it, because
# sym_lookup keeps the LAST match. This is Python-style rebinding: code
# compiled earlier keeps the old definition, later entries bind the new.
int repl_declare_global(char* name, int type, int symtype):
	int t = sym_lookup(name)
	if (t >= 0):
		if (table[t + 1] == 'U'):
			save_int(table + t + 6, type)
			save_int(table + t + 10, symtype)
			save_int(table + t + 18, pointer_indirection)
			return t
	sym_declare(name, type, 'U', code_offset, symtype)
	return table_pos - symbol_data_size()


# True when the current token begins a non-expression statement.
int repl_token_is_statement():
	if (peek(c"{")):
		return 1
	if (peek(c":")):
		return 1
	if (peek(c"if")):
		return 1
	if (peek(c"while")):
		return 1
	if (peek(c"for")):
		return 1
	if (peek(c"break")):
		return 1
	if (peek(c"continue")):
		return 1
	if (peek(c"return")):
		return 1
	if (peek(c"debugger")):
		return 1
	if (peek(c"pass")):
		return 1
	if (peek(c"raw_asm")):
		return 1
	if (peek(c"defer")):
		return 1
	return 0


# Compile one top-level item of the entry: a declaration (import, struct,
# extern, function, persistent variable) or an executable statement.
void repl_entry_item(int entry_symbol):
	repl_result_type = -1

	# Pure declarations: none of this executes now, but imports and extern
	# shims emit code, so the entry function jumps over the region
	if (peek(c"import") | peek(c"type") | peek(c"struct") | peek(c"union") | peek(c"enum") | peek(c"c_lib") | peek(c"extern")):
		int skip = repl_skip_start()
		if (import_statement()) {}
		else if (type_alias_declaration()) {}
		else if (struct_declaration()) {}
		else if (union_declaration()) {}
		else if (enum_declaration()) {}
		else if (extern_statement()) {}
		repl_skip_end(skip)
		current_function_symbol = entry_symbol
		number_of_args = 0
		return;

	# Generic function definitions ('T twice[T](T a):'): captured into
	# the generics registry (no code emitted) and skipped. Each entry is
	# staged in its own file, so the recorded span stays re-parseable
	# from later entries.
	if (generic_declaration_scan_repl()):
		current_function_symbol = entry_symbol
		number_of_args = 0
		return;

	# type-name ...: a function definition or a persistent variable
	if (peek(c"const") | (peek(c"map") & (nextc == '[')) | (peek(c"set") & (nextc == '[')) | (peek(c"list") & (nextc == '[')) | (type_lookup(token) >= 0) | generic_type_starts_here()):
		int decl_type = type_name()
		if (token[0] == 0):
			error(c"identifier expected after type name")
		char* decl_name = strclone(token)
		get_token()

		# function definition, e.g. "int add(int a, int b):"
		if (peek(c"(")):
			int function_symbol = repl_declare_global(decl_name, decl_type, 2)
			get_token() /* consume the '(' */
			int fskip = repl_skip_start()
			function_definition(function_symbol)
			repl_skip_end(fskip)
			current_function_symbol = entry_symbol
			number_of_args = 0
			enclosing_tab_level = 0
			free(decl_name)
			return;

		# persistent variable: storage lives in the code buffer (jumped
		# over); the initializer runs inside the entry function
		int global_symbol = repl_declare_global(decl_name, decl_type, 1)
		int gskip = repl_skip_start()
		sym_define_global(global_symbol)
		emit_global_storage(decl_type)
		repl_skip_end(gskip)
		pointer_indirection = 0

		if (accept(c"=")):
			# compile "name = expression" into the entry function
			sym_get_value(decl_name) /* address into eax */
			push_eax()
			stack_pos = stack_pos + 1
			int value_type = expression()
			value_type = promote(value_type)
			# Conversions the compiler's variable_declaration also
			# performs (var boxing, cstr-to-string, float widths)
			coerce(decl_type, value_type)
			pop_ebx()
			if (types_compatible_with_expression(decl_type, value_type) == 0):
				warn_type_mismatch(c"initialization", decl_type, value_type)
			assign_store(decl_type)
			stack_pos = stack_pos - 1
		expect_or_newline(c";")
		free(decl_name)
		return;

	# control flow and other non-expression statements
	if (repl_token_is_statement()):
		int statement_table_pos = table_pos
		enclosing_tab_level = 0
		statement()
		table_pos = statement_table_pos /* drop statement-local symbols */
		return;

	# bare expression: keep its value for echoing (unless it assigns)
	expression_is_assignment = 0
	last_call_return_type = -1
	last_call_end = -1
	int result_type = expression()
	promote(result_type)
	expect_or_newline(c";")
	repl_result_type = type_real(result_type)
	# When the expression ends in a call, the callee's declared return
	# type drives the echo: void stays silent, char* prints as a string
	if ((result_type == 3) & (last_call_end == codepos)):
		if (last_call_return_type >= 0):
			repl_result_type = last_call_return_type
	if (expression_is_assignment):
		repl_result_type = -1


# Compile the staged entry file. Returns the address of the entry's
# anonymous function, or 0 when the entry failed to compile.
int repl_compile_entry(char* path):
	# Checkpoint everything a failed compile could leave half-updated
	int saved_codepos = codepos
	int saved_table_pos = table_pos
	int saved_stack_pos = stack_pos
	int saved_loop_depth = loop_depth
	int saved_loop_break_chain = loop_break_chain
	int saved_loop_continue_chain = loop_continue_chain
	int saved_loop_stack_pos = loop_stack_pos
	int saved_defer_count = defer_count
	int saved_number_of_args = number_of_args
	int saved_type_count = length /* structures.list backs the type table */
	int saved_imported_count = imported_count
	int saved_alias_base = import_alias_base
	int saved_alias_count = import_alias_count
	int saved_plain_base = import_plain_base
	int saved_plain_count = import_plain_count
	int saved_function_symbol = current_function_symbol

	repl_recovery = 1
	if (repl_setjmp(repl_jump_buffer)):
		# error() jumped back: roll back the failed entry and skip execution
		repl_recovery = 0
		codepos = saved_codepos
		table_pos = saved_table_pos
		stack_pos = saved_stack_pos
		loop_depth = saved_loop_depth
		loop_break_chain = saved_loop_break_chain
		loop_continue_chain = saved_loop_continue_chain
		loop_stack_pos = saved_loop_stack_pos
		defer_count = saved_defer_count
		number_of_args = saved_number_of_args
		length = saved_type_count
		imported_count = saved_imported_count
		import_alias_base = saved_alias_base
		import_alias_count = saved_alias_count
		import_plain_base = saved_plain_base
		import_plain_count = saved_plain_count
		current_function_symbol = saved_function_symbol
		pointer_indirection = 0
		diag_clear()
		# The failure may have happened inside an imported file
		if (file != repl_entry_file):
			close(file)
		close(repl_entry_file)
		return 0

	filename = path
	file = open(path, 0, 511)
	asserts(c"could not reopen entry buffer", file >= 0)
	repl_entry_file = file
	line_number = 0
	column_number = 0
	tab_level = 0
	byte_offset = 0
	nextc = get_character()
	get_token()

	char* counter_digits = itoa(repl_counter)
	char* name = strjoin(c"__repl_", counter_digits)
	free(counter_digits)
	repl_counter = repl_counter + 1

	int entry_symbol = sym_declare_global(name, 1, 2)
	sym_define_global(entry_symbol)
	current_function_symbol = entry_symbol
	number_of_args = 0
	defer_reset()
	repl_result_type = -1

	while (token[0] != 0):
		repl_entry_item(entry_symbol)

	# The entry function's implicit end is a function exit: run any
	# deferred statements registered by this entry (LIFO)
	defer_emit_all()
	defer_reset()
	be_pop(stack_pos)
	stack_pos = 0
	ret()
	# On-demand runtimes for to_json/from_json and f"..." template
	# strings: the modules' functions land after the entry's ret, so
	# they are never in the execution path. Generic instantiations
	# requested by this entry compile here too.
	generic_finish_instantiations()
	json_codec_finish_import()
	template_string_finish_import()
	var_finish_import()
	generic_finish_instantiations()
	close(file)
	repl_recovery = 0

	int address = sym_address(name)
	free(name)
	return address


# ---------------------------------------------------------------------------
# Echoing expression results.

# Print an echoed expression value, formatted by its compile-time type.
void repl_echo(int value, int type):
	if (type <= 0): /* no result, or void */
		return;
	if (type_is_string(type)):
		write(1, load_word(value), load_word(value + word_size))
		put_char(10)
		return;
	int pointers = type_get_pointer_level(type)
	if ((pointers == 1) & (strcmp(type_get_name(type), c"char") == 0)):
		if (value == 0):
			println(c"(null)")
		else:
			println(str_from_cstr(cast(char*, value)))
		return;
	if ((pointers > 0) | (type == 4)):
		println(hex(value))
		return;
	println(itoa(value))


void repl_print_help():
	println(c"entries compile and run immediately; definitions persist:")
	println(c"  int x = 5           a variable that later entries can use")
	println(c"  int f(int a):       a function (finish the block, then a blank line)")
	println(c"  struct p: / import  structs and modules work too")
	println(c"a line ending in ':' opens a block and indents automatically;")
	println(c"return/break/continue/pass dedent; a blank line dedents one level")
	println(c"and ends the entry at column 0")
	println(c"a single bare expression echoes its value")
	println(c"commands: :quit exits, :help shows this text")


int main(int argc, int argv):
	args_init(argc, argv)
	verbosity = -1
	# The in-process model runs compiled entries directly, so the target
	# architecture is the one this binary was compiled for.
	word_size = __word_size__
	word_size_log2 = 2
	if (word_size == 8):
		word_size_log2 = 3
	push_basic_types()
	pointer_indirection = 0
	last_identifier = malloc(8000)
	last_global_declaration = malloc(8000)

	# Executable buffer the compiled entries run from. code_offset makes
	# every embedded address point into this mapping, so no relocation is
	# needed. The codegen embeds addresses as 32-bit immediates, so on
	# x64 the buffer must sit in the low 2GB: MAP_32BIT (0x40).
	int buffer_size = 8388608
	int mmap_flags = 34 /* PRIVATE|ANONYMOUS */
	if (word_size == 8):
		mmap_flags = 34 + 64
	int buffer = mmap(0, buffer_size, 7, mmap_flags) /* RWX */
	asserts(c"mmap of code buffer failed", (buffer > 0) | (buffer < -4095))
	code = buffer + 0
	code_size = buffer_size
	codepos = 0
	code_offset = buffer

	# Recoverable compile errors: error() jumps here instead of exiting
	repl_jump_buffer = cast(int, malloc(3 * __word_size__))
	repl_error_jump = cast(int, repl_longjmp)

	# Runtime support: syscall stubs first, then the library itself.
	# import_module (not compile_save) registers the modules, so a loaded
	# file importing lib.lib is not compiled a second time.
	if (word_size == 8):
		define_asm_functions_x64()
	else:
		define_asm_functions()
	import_module(c"lib.lib")
	import_module(c"lib.assert")

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
		compile_file(target)
		if (args_has_flag(c"no_main") == 0):
			# main must be 'D'efined: an undefined prototype's address
			# slot holds its backpatch chain, not an entry point
			int main_symbol = sym_lookup(c"main")
			int run_main = 0
			if (main_symbol >= 0):
				if (table[main_symbol + 1] == 'D'):
					run_main = 1
			if (run_main):
				int target_main = load_int(table + main_symbol + 2)
				# The target sees itself as argv[0]
				target_main(argc - 1, argv + __word_size__)
			else:
				println(c"(loaded file defines no main; its definitions are available)")

	println(c"w repl - :quit exits, :help for help")

	repl_interactive = term_isatty(0)
	if (repl_interactive):
		line_edit_history_load(c"~/.w_history")
	repl_line = string_new()
	repl_entry = string_new()
	# Each entry gets its own staging file: generic definitions record
	# (file, offset) spans that later entries re-parse on instantiation,
	# so an entry's text must survive subsequent entries.
	int entry_file_counter = 0
	char* entry_path = 0
	while (1):
		if (repl_read_entry() == 0):
			println(c"")
			exit(0)
		if (string_equals(repl_entry, c":quit")):
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

		# The tokenizer reads from a file, so stage the entry in /tmp
		if (entry_path != 0):
			free(entry_path)
		char* entry_digits = itoa(entry_file_counter)
		char* entry_prefix = strjoin(c"/tmp/w_repl_entry_", entry_digits)
		entry_path = strjoin(entry_prefix, c".w")
		free(entry_prefix)
		free(entry_digits)
		entry_file_counter = entry_file_counter + 1
		int out = create_file(entry_path, 511)
		asserts(c"could not create entry buffer", out >= 0)
		write(out, repl_entry.data, repl_entry.length)
		write(out, c"\x0a", 1)
		close(out)

		int address = repl_compile_entry(entry_path)
		if (address):
			int result = address()
			repl_echo(result, repl_result_type)

	return 0
