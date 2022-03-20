import lib
import compiler_vars
import tokenizer
import codegen
import assert
import type_table
import symbol_table
import grammar




void compile(char* fn):
	filename = fn
	file = open(filename, 0, 511)
	if (file < 0):
		print_error("file '")
		print_error(filename)
		print_error("' not found error '")
		print_error(itoa(error))
		print_error("'\x0a")
		exit(1)
	line_number = 0
	tab_level = 0
	nextc = get_character()
	get_token()
	program()


void compile_save(char* fn, int new_wildcard_import):
	char* old_filename = filename
	int old_file = file
	int old_line_number = line_number + 1
	int old_tab_level = old_tab_level
	int old_wildcard_import = wildcard_import

	wildcard_import = new_wildcard_import
	if (verbosity >= 2):
		print_string("compiling ", fn)

	compile(fn)
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
		compile(*arg)
		i = i + 1

	# print_symbol_table(0)
	type_print_all()
	emit_debugging_symbols(word_size)
	be_finish(word_size)
