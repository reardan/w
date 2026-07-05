import lib.lib
import structures.string


int target_verify
int target_lib_test
int target_lib_64_test
int target_path_test
int target_time_test
int target_result_test
int target_net_test
int target_poll_test
int target_hash_map_test
int target_hash_table_test
int target_array_list_test
int target_linked_list_test
int target_list_test
int target_string_test
int target_json_test
int target_warning_test
int target_check_json_test
int target_self_host_warning_test
int target_type_system_error_test
int target_type_system_warning_test
int target_repl_test
int target_debug_test
int target_c_import_test
int target_c_preprocessor_test
int target_c_import_errno_test
int target_c_import_libc_test
int target_parser_generator_test
int target_parser_generator_w_test
int target_parser_generator_c_test
int target_tests
int wtest_verbose


void wtest_usage():
	write(2, c"usage: wtest changed [--verbose] [file...]\x0a", 45)


void wtest_note(char* path, char* target):
	if (wtest_verbose == 0):
		return
	write(2, path, strlen(path))
	write(2, c" -> ", 4)
	write(2, target, strlen(target))
	write(2, c"\x0a", 1)


void wtest_add(char* path, char* target):
	wtest_note(path, target)
	if (strcmp(target, c"verify") == 0):
		target_verify = 1
	else if (strcmp(target, c"lib_test") == 0):
		target_lib_test = 1
	else if (strcmp(target, c"lib_64_test") == 0):
		target_lib_64_test = 1
	else if (strcmp(target, c"path_test") == 0):
		target_path_test = 1
	else if (strcmp(target, c"time_test") == 0):
		target_time_test = 1
	else if (strcmp(target, c"result_test") == 0):
		target_result_test = 1
	else if (strcmp(target, c"net_test") == 0):
		target_net_test = 1
	else if (strcmp(target, c"poll_test") == 0):
		target_poll_test = 1
	else if (strcmp(target, c"hash_map_test") == 0):
		target_hash_map_test = 1
	else if (strcmp(target, c"hash_table_test") == 0):
		target_hash_table_test = 1
	else if (strcmp(target, c"array_list_test") == 0):
		target_array_list_test = 1
	else if (strcmp(target, c"linked_list_test") == 0):
		target_linked_list_test = 1
	else if (strcmp(target, c"list_test") == 0):
		target_list_test = 1
	else if (strcmp(target, c"string_test") == 0):
		target_string_test = 1
	else if (strcmp(target, c"json_test") == 0):
		target_json_test = 1
	else if (strcmp(target, c"warning_test") == 0):
		target_warning_test = 1
	else if (strcmp(target, c"check_json_test") == 0):
		target_check_json_test = 1
	else if (strcmp(target, c"self_host_warning_test") == 0):
		target_self_host_warning_test = 1
	else if (strcmp(target, c"type_system_error_test") == 0):
		target_type_system_error_test = 1
	else if (strcmp(target, c"type_system_warning_test") == 0):
		target_type_system_warning_test = 1
	else if (strcmp(target, c"repl_test") == 0):
		target_repl_test = 1
	else if (strcmp(target, c"debug_test") == 0):
		target_debug_test = 1
	else if (strcmp(target, c"c_import_test") == 0):
		target_c_import_test = 1
	else if (strcmp(target, c"c_preprocessor_test") == 0):
		target_c_preprocessor_test = 1
	else if (strcmp(target, c"c_import_errno_test") == 0):
		target_c_import_errno_test = 1
	else if (strcmp(target, c"c_import_libc_test") == 0):
		target_c_import_libc_test = 1
	else if (strcmp(target, c"parser_generator_test") == 0):
		target_parser_generator_test = 1
	else if (strcmp(target, c"parser_generator_w_test") == 0):
		target_parser_generator_w_test = 1
	else if (strcmp(target, c"parser_generator_c_test") == 0):
		target_parser_generator_c_test = 1
	else:
		target_tests = 1


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
		wtest_add(path, c"poll_test")
	else if (strcmp(path, c"lib/poll.w") == 0):
		wtest_add(path, c"poll_test")
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


int wtest_read_line(string_builder* line):
	string_clear(line)
	int c = getchar(0)
	if (c == -1):
		return 0
	while ((c != 10) & (c != -1)):
		string_append_char(line, c)
		c = getchar(0)
	return 1


void wtest_emit_target(char* target, int enabled):
	if (enabled == 0):
		return
	write(1, target, strlen(target))
	write(1, c"\x0a", 1)


void wtest_emit_targets():
	wtest_emit_target(c"verify", target_verify)
	wtest_emit_target(c"lib_test", target_lib_test)
	wtest_emit_target(c"path_test", target_path_test)
	wtest_emit_target(c"time_test", target_time_test)
	wtest_emit_target(c"result_test", target_result_test)
	wtest_emit_target(c"lib_64_test", target_lib_64_test)
	wtest_emit_target(c"warning_test", target_warning_test)
	wtest_emit_target(c"check_json_test", target_check_json_test)
	wtest_emit_target(c"self_host_warning_test", target_self_host_warning_test)
	wtest_emit_target(c"type_system_error_test", target_type_system_error_test)
	wtest_emit_target(c"type_system_warning_test", target_type_system_warning_test)
	wtest_emit_target(c"list_test", target_list_test)
	wtest_emit_target(c"hash_map_test", target_hash_map_test)
	wtest_emit_target(c"hash_table_test", target_hash_table_test)
	wtest_emit_target(c"string_test", target_string_test)
	wtest_emit_target(c"array_list_test", target_array_list_test)
	wtest_emit_target(c"json_test", target_json_test)
	wtest_emit_target(c"parser_generator_test", target_parser_generator_test)
	wtest_emit_target(c"parser_generator_w_test", target_parser_generator_w_test)
	wtest_emit_target(c"parser_generator_c_test", target_parser_generator_c_test)
	wtest_emit_target(c"linked_list_test", target_linked_list_test)
	wtest_emit_target(c"net_test", target_net_test)
	wtest_emit_target(c"poll_test", target_poll_test)
	wtest_emit_target(c"repl_test", target_repl_test)
	wtest_emit_target(c"debug_test", target_debug_test)
	wtest_emit_target(c"c_import_test", target_c_import_test)
	wtest_emit_target(c"c_preprocessor_test", target_c_preprocessor_test)
	wtest_emit_target(c"c_import_errno_test", target_c_import_errno_test)
	wtest_emit_target(c"c_import_libc_test", target_c_import_libc_test)
	wtest_emit_target(c"tests", target_tests)


int main(int argc, int argv):
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
		string_builder* line = string_new()
		while (wtest_read_line(line)):
			wtest_map_path(line.data)
		string_free(line)
	wtest_emit_targets()
	return 0
