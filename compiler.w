import lib
import tokenizer
import codegen
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


void compile_save(char* fn):
	char* old_filename = filename
	int old_file = file
	int old_line_number = line_number + 1
	int old_tab_level = old_tab_level

	compile(fn)
	close(file)

	filename = old_filename
	file = old_file
	line_number = old_line_number
	tab_level = old_tab_level
	nextc = get_character()
	get_token()

	if (verbosity > 0):
		print_error("switching back to '")
		print_error(filename)
		print_error("'\x0a")


int link(int argc, int argv):
	pointer_indirection = 0
	last_identifier = malloc(8000)
	last_global_declaration = malloc(8000)
	be_start()

	int i = 1
	while (i < argc):
		int arg = argv + i * 4
		print_error("compiling '")
		print_error(*arg)
		print_error("'\x0a")
		compile(*arg)
		i = i + 1

	# print_symbol_table(0)
	emit_debugging_symbols()
	be_finish()
