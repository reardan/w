import lib.lib
import lib.stream
import structures.string


# Ordered registry of Makefile targets wtest knows how to emit. The order
# here is the output order; the catch-all "tests" target stays last.
# Adding a target is one push() here plus a mapping rule below.
list[char*] wtest_targets
map[char*, int] wtest_enabled
int wtest_verbose


void wtest_init_targets():
	wtest_targets = new list[char*]
	wtest_enabled = new map[char*, int]
	wtest_targets.push(c"verify")
	wtest_targets.push(c"lib_test")
	wtest_targets.push(c"path_test")
	wtest_targets.push(c"time_test")
	wtest_targets.push(c"result_test")
	wtest_targets.push(c"lib_64_test")
	wtest_targets.push(c"warning_test")
	wtest_targets.push(c"check_json_test")
	wtest_targets.push(c"symbols_test")
	wtest_targets.push(c"self_host_warning_test")
	wtest_targets.push(c"type_system_error_test")
	wtest_targets.push(c"type_system_warning_test")
	wtest_targets.push(c"list_test")
	wtest_targets.push(c"hash_map_test")
	wtest_targets.push(c"hash_table_test")
	wtest_targets.push(c"string_test")
	wtest_targets.push(c"array_list_test")
	wtest_targets.push(c"json_test")
	wtest_targets.push(c"parser_generator_test")
	wtest_targets.push(c"parser_generator_w_test")
	wtest_targets.push(c"parser_generator_c_test")
	wtest_targets.push(c"linked_list_test")
	wtest_targets.push(c"net_test")
	wtest_targets.push(c"env_test")
	wtest_targets.push(c"env_64_test")
	wtest_targets.push(c"process_test")
	wtest_targets.push(c"process_64_test")
	wtest_targets.push(c"stream_test")
	wtest_targets.push(c"stream_64_test")
	wtest_targets.push(c"file_test")
	wtest_targets.push(c"repl_test")
	wtest_targets.push(c"debug_test")
	wtest_targets.push(c"c_import_test")
	wtest_targets.push(c"c_preprocessor_test")
	wtest_targets.push(c"c_import_errno_test")
	wtest_targets.push(c"c_import_libc_test")
	wtest_targets.push(c"tests")


int wtest_target_known(char* target):
	for char* known in wtest_targets:
		if (strcmp(known, target) == 0):
			return 1
	return 0


void wtest_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wtest changed [--verbose] [file...]")
	stream_flush(err)


void wtest_note(char* path, char* target):
	if (wtest_verbose == 0):
		return
	wstream* err = stderr_writer()
	stream_write_cstr(err, path)
	stream_write_cstr(err, c" -> ")
	stream_write_line(err, target)
	stream_flush(err)


void wtest_add(char* path, char* target):
	wtest_note(path, target)
	if (wtest_target_known(target)):
		wtest_enabled[target] = 1
	else:
		wtest_enabled[c"tests"] = 1


void wtest_add_compiler(char* path):
	wtest_add(path, c"verify")
	wtest_add(path, c"self_host_warning_test")


void wtest_add_c_import(char* path):
	wtest_add(path, c"c_import_test")
	wtest_add(path, c"c_preprocessor_test")
	wtest_add(path, c"c_import_errno_test")
	wtest_add(path, c"c_import_libc_test")


void wtest_add_parser_generator(char* path):
	wtest_add(path, c"parser_generator_test")
	wtest_add(path, c"parser_generator_w_test")
	wtest_add(path, c"parser_generator_c_test")


int wtest_doc_only(char* path):
	if (starts_with(path, c"docs/")):
		return 1
	if (ends_with(path, c".md")):
		return 1
	if (ends_with(path, c".txt")):
		return 1
	return 0


void wtest_map_lib(char* path):
	if (starts_with(path, c"lib/__arch__/")):
		wtest_add(path, c"lib_test")
		wtest_add(path, c"lib_64_test")
	else if (strcmp(path, c"lib/path.w") == 0):
		wtest_add(path, c"path_test")
	else if (strcmp(path, c"lib/time.w") == 0):
		wtest_add(path, c"time_test")
	else if (strcmp(path, c"lib/result.w") == 0):
		wtest_add(path, c"result_test")
	else if (strcmp(path, c"lib/net.w") == 0):
		wtest_add(path, c"net_test")
	else if (strcmp(path, c"lib/env.w") == 0):
		wtest_add(path, c"env_test")
		wtest_add(path, c"env_64_test")
	else if (strcmp(path, c"lib/process.w") == 0):
		wtest_add(path, c"process_test")
		wtest_add(path, c"process_64_test")
	else if (strcmp(path, c"lib/stream.w") == 0):
		# lib/file.w builds on the stream module.
		wtest_add(path, c"stream_test")
		wtest_add(path, c"stream_64_test")
		wtest_add(path, c"file_test")
	else if (strcmp(path, c"lib/file.w") == 0):
		wtest_add(path, c"file_test")
	else:
		wtest_add(path, c"lib_test")


void wtest_map_structures(char* path):
	if (strcmp(path, c"structures/json.w") == 0):
		wtest_add(path, c"json_test")
	else if (strcmp(path, c"structures/hash_map.w") == 0):
		wtest_add(path, c"hash_map_test")
	else if (strcmp(path, c"structures/hash_table.w") == 0):
		wtest_add(path, c"hash_table_test")
	else if (strcmp(path, c"structures/array_list.w") == 0):
		wtest_add(path, c"array_list_test")
	else if (strcmp(path, c"structures/linked_list.w") == 0):
		wtest_add(path, c"linked_list_test")
	else if (strcmp(path, c"structures/list.w") == 0):
		wtest_add(path, c"list_test")
	else if (strcmp(path, c"structures/string.w") == 0):
		wtest_add(path, c"string_test")
	else:
		wtest_add(path, c"tests")


void wtest_map_path(char* path):
	if (strlen(path) == 0):
		return
	if (wtest_doc_only(path)):
		return
	if ((strcmp(path, c"w.w") == 0) | (strcmp(path, c"grammar.w") == 0) | (strcmp(path, c"codegen.w") == 0)):
		wtest_add_compiler(path)
	else if (starts_with(path, c"compiler/") | starts_with(path, c"grammar/") | starts_with(path, c"code_generator/")):
		wtest_add_compiler(path)
	else if (starts_with(path, c"lib/")):
		wtest_map_lib(path)
	else if (starts_with(path, c"structures/")):
		wtest_map_structures(path)
	else if (strcmp(path, c"repl.w") == 0):
		wtest_add(path, c"repl_test")
	else if (starts_with(path, c"debugger/")):
		wtest_add(path, c"debug_test")
	else if (starts_with(path, c"libs/extras/c_import/") | starts_with(path, c"libs/extras/c_preprocessor/")):
		wtest_add_c_import(path)
	else if (starts_with(path, c"libs/extras/parser_generator/") | (strcmp(path, c"tools/parser_generator.w") == 0)):
		wtest_add_parser_generator(path)
	else if ((strcmp(path, c"tests/warning_fixture.w") == 0) | (strcmp(path, c"tests/warning_clean_fixture.w") == 0) | (strcmp(path, c"tests/string_char_warning_fixture.w") == 0)):
		wtest_add(path, c"warning_test")
	else if (strcmp(path, c"tests/symbols_fixture.w") == 0):
		wtest_add(path, c"symbols_test")
	else if (starts_with(path, c"tests/type_system_error")):
		wtest_add(path, c"type_system_error_test")
	else if (starts_with(path, c"tests/type_system_warning")):
		wtest_add(path, c"type_system_warning_test")
	else if (starts_with(path, c"tests/parser_generator/")):
		wtest_add_parser_generator(path)
	else if (strcmp(path, c"Makefile") == 0):
		wtest_add(path, c"tests")
	else:
		wtest_add(path, c"tests")


void wtest_emit_targets():
	wstream* out = stdout_writer()
	for char* target in wtest_targets:
		if (target in wtest_enabled):
			stream_write_line(out, target)
	stream_flush(out)


int main(int argc, int argv):
	wtest_init_targets()
	if (argc < 2):
		wtest_usage()
		return 1
	char** command = argv + __word_size__
	if (strcmp(*command, c"changed") != 0):
		wtest_usage()
		return 1
	int saw_file = 0
	int i = 2
	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--verbose") == 0):
			wtest_verbose = 1
		else:
			wtest_map_path(*arg)
			saw_file = 1
		i = i + 1
	if (saw_file == 0):
		wstream* in = stdin_reader()
		string_builder* line = string_new()
		while (stream_read_line(in, line)):
			wtest_map_path(line.data)
		string_free(line)
	wtest_emit_targets()
	return 0
