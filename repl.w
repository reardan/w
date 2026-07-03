/*
Interactive REPL.

Each input line is compiled as the body of a fresh anonymous function into
an executable mmap buffer, then called immediately. The standard library is
compiled into the same buffer at startup, so lines can call print, malloc,
strjoin and friends directly.

v0 limitations:
- one line per entry (single-line blocks like "if (1): print(...)" work)
- locals do not persist between lines
- a compile error exits the process (the compiler's error() calls exit)

Commands: :quit exits.
*/
import compiler.compiler
import structures.string


int repl_counter


# Compile the file as the body of a fresh function; returns its address.
int repl_compile_line(char* path):
	filename = path
	file = open(path, 0, 511)
	asserts("could not reopen line buffer", file >= 0)
	line_number = 0
	tab_level = 0
	nextc = get_character()
	get_token()

	char* counter_digits = itoa(repl_counter)
	char* name = strjoin("__repl_", counter_digits)
	free(counter_digits)
	repl_counter = repl_counter + 1

	int current_symbol = sym_declare_global(name, 1, 2)
	sym_define_global(current_symbol)
	current_function_symbol = current_symbol
	int n = table_pos
	number_of_args = 0
	enclosing_tab_level = 0
	while (token[0] != 0):
		statement()
	be_pop(stack_pos)
	stack_pos = 0
	ret()
	table_pos = n
	close(file)

	int address = sym_address(name)
	free(name)
	return address


# Read one line from stdin into s; returns 0 on end of input.
int repl_read_line(string* s):
	string_clear(s)
	int c = getchar(0)
	if (c == -1):
		return 0
	while ((c != 10) & (c != -1)):
		string_append_char(s, c)
		c = getchar(0)
	return 1


int main(int argc, int argv):
	verbosity = -1
	word_size = 4
	word_size_log2 = 2
	push_basic_types()
	pointer_indirection = 0
	last_identifier = malloc(8000)
	last_global_declaration = malloc(8000)

	# Executable buffer the compiled lines run from. code_offset makes every
	# embedded address point into this mapping, so no relocation is needed.
	int buffer_size = 8388608
	int buffer = mmap(0, buffer_size, 7, 34) /* RWX, PRIVATE|ANONYMOUS */
	asserts("mmap of code buffer failed", (buffer > 0) | (buffer < -4095))
	code = buffer + 0
	code_size = buffer_size
	codepos = 0
	code_offset = buffer

	# Runtime support: syscall stubs first, then the library itself
	define_asm_functions()
	compile_save("lib/lib.w")
	compile_save("lib/assert.w")

	println("w repl - one statement per line, :quit exits")

	string* line = string_new()
	char* line_path = "/tmp/w_repl_line.w"
	while (1):
		print("w> ")
		if (repl_read_line(line) == 0):
			println("")
			exit(0)
		if (string_equals(line, ":quit")):
			exit(0)
		if (line.length == 0):
			continue

		# The tokenizer reads from a file, so stage the line in /tmp
		int out = create_file(line_path, 511)
		asserts("could not create line buffer", out >= 0)
		write(out, line.data, line.length)
		write(out, "\x0a", 1)
		close(out)

		int address = repl_compile_line(line_path)
		address()

	return 0
