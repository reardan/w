import lib.lib
import compiler.tokenizer
import codegen
import lib.assert
import compiler.type_table
import compiler.symbol_table
import grammar


void file_not_found_error():
	print_error("file '")
	print_error(filename)
	print_error("' not found error '")
	print_error(itoa(error))
	print_error("'\x0a")


int compile_attempt(char* fn):
	filename = fn
	file = open(filename, 0, 511)
	if (file < 0):
		file_not_found_error()
		return 0
	line_number = 0
	tab_level = 0
	nextc = get_character()
	get_token()
	program()
	return 1


int compile_joined(char* cwd, char* filename):

	# Compute path based on current directory
	char* joined = strjoin(cwd, "/")

	char* joined2 = strjoin(joined, filename)
	# print_string("joined: ", joined2)
	free(joined)

	# Add the .w extension if not already present
	if (ends_with(joined2, ".w") == 0):
		char* joined3 = strjoin(joined2, ".w")
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
		print_string("went up one directory: ", cwd)

	# error() instead of exit() so a REPL entry importing a missing
	# module recovers to the prompt instead of killing the session
	error("filesystem root reached, abandoning search")
	return 0


int compile_file(char* filename):
	# Handle absolute paths by using the filename directly on filesep start
	if (filename[0] == 47):
		print2("using filename as path directly: ")
		println2(filename)
		return compile_attempt(filename)

	return compile_relative_path(filename)


void compile_save(char* fn):
	char* old_filename = filename
	int old_file = file
	int old_line_number = line_number + 1
	int old_tab_level = tab_level

	if (verbosity >= 0):
		print_string("compiling ", fn)

	compile_file(fn)
	close(file)

	filename = old_filename
	file = old_file
	line_number = old_line_number
	tab_level = old_tab_level

	if (verbosity >= 0):
		print_string("back to ", filename)


int link(int argc, int argv):
	if (argc < 2):
		println2("usage: w [x64] <file.w>... [-o output] [--bounds=on|off|trap]")
		exit(1)
	int i = 1
	word_size = 4
	word_size_log2 = 2
	bounds_mode = 1
	# argv strides by the HOST pointer size: __word_size__ was baked in
	# when this compiler binary was itself compiled
	int first_arg = argv + __word_size__
	if (strcmp(*first_arg, "x64") == 0):
		println2("Compiling in x64 mode")
		word_size =  8
		word_size_log2 = 3
		i = i + 1
	push_basic_types()
	pointer_indirection = 0
	last_identifier = malloc(8000)
	last_global_declaration = malloc(8000)
	be_start(word_size)

	output_fd = 1 /* default: write the ELF to stdout */
	char* output_path = 0

	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, "-o") == 0):
			i = i + 1
			asserts("-o requires an output path", i < argc)
			arg = argv + i * __word_size__
			output_path = *arg
		else if (strcmp(*arg, "--bounds=on") == 0):
			bounds_mode = 1
		else if (strcmp(*arg, "--bounds=trap") == 0):
			bounds_mode = 1
		else if (strcmp(*arg, "--bounds=off") == 0):
			bounds_mode = 0
		else:
			print_error("compiling '")
			print_error(*arg)
			print_error("'\x0a")
			compile_file(*arg)
		i = i + 1

	if (output_path != 0):
		/* O_WRONLY|O_CREAT|O_TRUNC, mode 0755 so the result is executable */
		output_fd = open(output_path, 577, 493)
		asserts("could not open output file", output_fd >= 0)

	# print_symbol_table(0)
	# type_print_all()
	emit_debugging_symbols(word_size)
	be_finish(word_size)

	if (output_path != 0):
		close(output_fd)
