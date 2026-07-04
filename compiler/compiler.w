import lib.lib
import compiler.tokenizer
import codegen
import lib.assert
import compiler.type_table
import compiler.symbol_table
import grammar


void file_not_found_error():
	print_error(c"file '")
	print_error(filename)
	print_error(c"' not found error '")
	# 'file' holds the failed open() result; the old code passed the
	# error() function itself, which the typed checks now reject
	print_error(itoa(file))
	print_error(c"'\x0a")


int compile_attempt(char* fn):
	filename = fn
	file = open(filename, 0, 511)
	if (file < 0):
		file_not_found_error()
		return 0
	line_number = 0
	column_number = 0
	tab_level = 0
	nextc = get_character()
	get_token()
	program()
	return 1


int compile_joined(char* cwd, char* filename):

	# Compute path based on current directory
	char* joined = strjoin(cwd, c"/")

	char* joined2 = strjoin(joined, filename)
	# print_string("joined: ", joined2)
	free(joined)

	# Add the .w extension if not already present
	if (ends_with(joined2, c".w") == 0):
		char* joined3 = strjoin(joined2, c".w")
		free(joined2)
		joined2 = joined3

	# Attempt to compile the path
	int result = compile_attempt(joined2)
	free(joined2)
	return result


int compile_relative_path(char* filename):
	# Get current directory
	int max_path_size = 4096
	char* cwd = malloc(max_path_size)
	getcwd(cwd, max_path_size)

	# While we still have path remaining:
	while (cwd[0]):

		# Attempt to compile with this path
		int result = compile_joined(cwd, filename)

		# If successfull return
		if (result == 1):
			free(cwd)
			return 1

		# Go back up one directory
		int index = strlen(cwd) - 1
		while (index >= 0):
			if (cwd[index] == '/'):
				cwd[index] = 0
				index = 0 /* hacky way to break from loop */
			index = index - 1
		print_string(c"went up one directory: ", cwd)

	# error() instead of exit() so a REPL entry importing a missing
	# module recovers to the prompt instead of killing the session
	error(c"filesystem root reached, abandoning search")
	return 0


int compile_file(char* filename):
	# Handle absolute paths by using the filename directly on filesep start
	if (filename[0] == 47):
		print2(c"using filename as path directly: ")
		println2(filename)
		return compile_attempt(filename)

	return compile_relative_path(filename)


void compile_save(char* fn):
	char* old_filename = filename
	int old_file = file
	int old_line_number = line_number + 1
	int old_column_number = column_number
	int old_diag_token_line = diag_token_line
	int old_diag_token_column = diag_token_column
	int old_tab_level = tab_level

	if (verbosity >= 0):
		print_string(c"compiling ", fn)

	compile_file(fn)
	close(file)

	filename = old_filename
	file = old_file
	line_number = old_line_number
	column_number = old_column_number
	diag_token_line = old_diag_token_line
	diag_token_column = old_diag_token_column
	tab_level = old_tab_level

	if (verbosity >= 0):
		print_string(c"back to ", filename)


int link_impl(int argc, int argv, int start_index, int check_mode):
	if (argc <= start_index):
		println2(c"usage: w [x64] <file.w>... [-o output] [--bounds=on|off|trap]")
		exit(1)
	int i = start_index
	word_size = 4
	word_size_log2 = 2
	bounds_mode = 1
	# argv strides by the HOST pointer size: __word_size__ was baked in
	# when this compiler binary was itself compiled
	char** first_arg = argv + i * __word_size__
	if (strcmp(*first_arg, c"x64") == 0):
		println2(c"Compiling in x64 mode")
		word_size =  8
		word_size_log2 = 3
		i = i + 1
	push_basic_types()
	pointer_indirection = 0
	last_identifier = malloc(8000)
	last_global_declaration = malloc(8000)
	be_start(word_size)
	import_module(c"structures.hash_table")

	output_fd = 1 /* default: write the ELF to stdout */
	char* output_path = 0

	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"-o") == 0):
			i = i + 1
			asserts(c"-o requires an output path", i < argc)
			arg = argv + i * __word_size__
			output_path = *arg
		else if (strcmp(*arg, c"--bounds=on") == 0):
			bounds_mode = 1
		else if (strcmp(*arg, c"--bounds=trap") == 0):
			bounds_mode = 1
		else if (strcmp(*arg, c"--bounds=off") == 0):
			bounds_mode = 0
		else:
			print_error(c"compiling '")
			print_error(*arg)
			print_error(c"'\x0a")
			compile_file(*arg)
		i = i + 1

	if (output_path != 0):
		/* O_WRONLY|O_CREAT|O_TRUNC, mode 0755 so the result is executable */
		output_fd = open(output_path, 577, 493)
		asserts(c"could not open output file", output_fd >= 0)
	if (check_mode):
		output_fd = open(c"/dev/null", 577, 493)
		asserts(c"could not open /dev/null", output_fd >= 0)

	# print_symbol_table(0)
	# type_print_all()
	emit_debugging_symbols(word_size)
	be_finish(word_size)

	if ((output_path != 0) | check_mode):
		close(output_fd)

	return 0


int link(int argc, int argv):
	return link_impl(argc, argv, 1, 0)


int check_main(int argc, int argv):
	int i = 2
	diag_json = 0
	if (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--json") == 0):
			diag_json = 1
			i = i + 1
	if (argc <= i):
		println2(c"usage: w check [--json] [x64] <file.w>... [--bounds=on|off|trap]")
		exit(1)
	return link_impl(argc, argv, i, 1)
