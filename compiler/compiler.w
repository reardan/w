import lib.lib
import compiler.compiler_vars
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
	print_string("joined: ", joined2)
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


int compile_file(char* filename):
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

	println2("filesystem root reached, abandoning search")
	exit(1)



void compile_save(char* fn, int new_wildcard_import):
	char* old_filename = filename
	int old_file = file
	int old_line_number = line_number + 1
	int old_tab_level = old_tab_level
	int old_wildcard_import = wildcard_import

	wildcard_import = new_wildcard_import
	if (verbosity >= 0):
		print_string("compiling ", fn)

	compile_file(fn)
	close(file)

	filename = old_filename
	file = old_file
	line_number = old_line_number
	tab_level = old_tab_level
	wildcard_import = old_wildcard_import

	if (verbosity >= 0):
		print_string("back to ", filename)


int link(int argc, int argv):
	int i = 1
	word_size = 4
	word_size_log2 = 2
	int first_arg = argv + word_size
	print_string("argv + word_size: ", *first_arg)
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


	while (i < argc):
		int arg = argv + i * 4
		print_error("compiling '")
		print_error(*arg)
		print_error("'\x0a")
		compile_file(*arg)
		i = i + 1

	# print_symbol_table(0)
	type_print_all()
	emit_debugging_symbols(word_size)
	be_finish(word_size)
