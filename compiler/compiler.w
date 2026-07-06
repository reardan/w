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

	# Import aliases and plain-import records are file-scoped: hide the
	# importer's entries while the imported file compiles, then drop the
	# imported file's entries on the way back out.
	int old_alias_base = import_alias_base
	int old_alias_count = import_alias_count
	int old_plain_base = import_plain_base
	int old_plain_count = import_plain_count
	import_alias_base = import_alias_count
	import_plain_base = import_plain_count

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
	import_alias_base = old_alias_base
	import_alias_count = old_alias_count
	import_plain_base = old_plain_base
	import_plain_count = old_plain_count

	if (verbosity >= 0):
		print_string(c"back to ", filename)


int link_impl(int argc, int argv, int start_index, int check_mode):
	if (argc <= start_index):
		println2(c"usage: w [x64] <file.w>... [-o output] [--bounds=on|off|trap] [--strict]")
		exit(1)
	int i = start_index
	word_size = 4
	word_size_log2 = 2
	diag_word_size = word_size
	bounds_mode = 1
	strict_mode = 0
	warning_count = 0
	# argv strides by the HOST pointer size: __word_size__ was baked in
	# when this compiler binary was itself compiled
	char** first_arg = argv + i * __word_size__
	if (strcmp(*first_arg, c"x64") == 0):
		println2(c"Compiling in x64 mode")
		word_size =  8
		word_size_log2 = 3
		diag_word_size = word_size
		i = i + 1
	push_basic_types()
	pointer_indirection = 0
	last_identifier = malloc(8000)
	last_global_declaration = malloc(8000)
	be_start(word_size)
	import_module(c"structures.hash_table")
	import_module(c"structures.w_list")

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
		else if (strcmp(*arg, c"--strict") == 0):
			strict_mode = 1
		else:
			print_error(c"compiling '")
			print_error(*arg)
			print_error(c"'\x0a")
			compile_file(*arg)
		i = i + 1

	# On-demand runtimes for the to_json/from_json builtins and f"..."
	# template strings: imported after all user files so the modules'
	# code lands at a top-level boundary
	json_codec_finish_import()
	template_string_finish_import()

	# --strict: fail before any output is written so no artifact is
	# produced when warnings fired. Warnings were already printed with
	# their usual text; this only adds a summary and the failing exit.
	# str_from_cstr keeps the message printable when this file is compiled
	# by the seed, which does not coerce char* call arguments to string.
	if (strict_mode):
		if (warning_count > 0):
			print_error(str_from_cstr(c"error: "))
			print_error(str_from_cstr(itoa(warning_count)))
			print_error(str_from_cstr(c" warning(s) treated as errors (--strict)\x0a"))
			exit(1)

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
		println2(c"usage: w check [--json] [x64] <file.w>... [--bounds=on|off|trap] [--strict]")
		exit(1)
	return link_impl(argc, argv, i, 1)


/*
w symbols [--json] [x64] <file.w>...

Compiles like 'w check' (output to /dev/null), then dumps the global symbol
table and user-declared types with their declaration locations. --json emits
one NDJSON record per entry on stdout, mirroring 'w check --json'. Entries
without a recorded location (runtime stubs declared before any source file)
are skipped.
*/


# Type name with pointer stars appended, e.g. "char*". Caller frees.
char* symbols_type_display(int type):
	if (type < 0):
		return strclone(c"<none>")
	char* name = strclone(type_get_name(type))
	int stars = type_get_pointer_level(type)
	while (stars > 0):
		char* with_star = strjoin(name, c"*")
		free(name)
		name = with_star
		stars = stars - 1
	return name


char* symbols_kind_name(int symtype):
	if (symtype == 2):
		return c"function"
	if (symtype == 1):
		return c"object"
	return c"notype"


# Kind of a type-table record from its RAW kind tag (type_get_kind would
# follow alias targets). Only struct/union/enum/alias/fn declarations record
# locations, so the default is "struct".
char* symbols_type_kind_name(int type_index):
	int t = get(type_index)
	int kind = load_int(t + 820)
	if (kind == type_kind_alias):
		return c"alias"
	if (kind == type_kind_union):
		return c"union"
	if (kind == type_kind_enum):
		return c"enum"
	if (kind == type_kind_function):
		return c"fn"
	return c"struct"


void symbols_emit_json(char* name, char* kind, char* type_name, int file_index, int line, int column):
	char* arch = c"x86"
	if (diag_word_size == 8):
		arch = c"x64"
	diag_write_cstr(c"{")
	diag_write_json_field(c"name", name)
	diag_write_cstr(c", ")
	diag_write_json_field(c"kind", kind)
	diag_write_cstr(c", ")
	diag_write_json_field(c"type", type_name)
	diag_write_cstr(c", ")
	diag_write_json_field(c"file", debug_file_name(file_index))
	diag_write_cstr(c", ")
	diag_write_json_int_field(c"line", line)
	diag_write_cstr(c", ")
	diag_write_json_int_field(c"column", column)
	diag_write_cstr(c", ")
	diag_write_json_field(c"arch", arch)
	diag_write_cstr(c"}\x0a")


void symbols_emit_human(char* name, char* kind, char* type_name, int file_index, int line, int column):
	diag_write_cstr(debug_file_name(file_index))
	diag_write_cstr(c":")
	char* line_digits = itoa(line)
	diag_write_cstr(line_digits)
	free(line_digits)
	diag_write_cstr(c":")
	char* column_digits = itoa(column)
	diag_write_cstr(column_digits)
	free(column_digits)
	diag_write_cstr(c": ")
	diag_write_cstr(kind)
	diag_write_cstr(c" ")
	diag_write_cstr(name)
	diag_write_cstr(c": ")
	diag_write_cstr(type_name)
	diag_write_cstr(c"\x0a")


void symbols_emit(int json, char* name, char* kind, char* type_name, int file_index, int line, int column):
	if (json):
		symbols_emit_json(name, kind, type_name, file_index, line, column)
	else:
		symbols_emit_human(name, kind, type_name, file_index, line, column)


void symbols_dump(int json):
	int t = 0
	while (t <= table_pos - 1):
		char* sym = table + t
		t = t + strlen(table + t)
		int file_index = sym_decl_file_index(t)
		if (file_index >= 0):
			char* type_name = symbols_type_display(load_int(table + t + 6))
			char* kind = symbols_kind_name(load_int(table + t + 10))
			symbols_emit(json, sym, kind, type_name, file_index, sym_decl_line(t), sym_decl_column(t))
			free(type_name)
		t = next_token(t)
	# User-declared types: structs, unions, enums, and type aliases.
	# 'length' is the type table's structures.list element count.
	int i = 0
	while (i < length):
		if (type_decl_file_index(i) >= 0):
			symbols_emit(json, type_get_name(i), symbols_type_kind_name(i), type_get_name(i), type_decl_file_index(i), type_decl_line(i), type_decl_column(i))
		i = i + 1


int symbols_main(int argc, int argv):
	int i = 2
	int json = 0
	diag_json = 0
	if (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--json") == 0):
			json = 1
			diag_json = 1
			i = i + 1
	if (argc <= i):
		println2(c"usage: w symbols [--json] [x64] <file.w>... [--bounds=on|off|trap] [--strict]")
		exit(1)
	link_impl(argc, argv, i, 1)
	symbols_dump(json)
	return 0
