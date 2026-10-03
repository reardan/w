# wbuild: x64 tool=tools/wc2.w
import tests.wc2_support
import tools.wc2.service
import tools.wc2.dump
import lib.stat


json_value* wc2_test_request(wc2_resident* r, char* method, char* file, char* output):
	json_value* request = json_object()
	json_object_set(request, c"method", json_string(method))
	if (file != 0): json_object_set(request, c"file", json_string(file))
	if (output != 0): json_object_set(request, c"output", json_string(output))
	json_value* result = wc2_resident_request(r, request)
	json_free(request)
	return result


void wc2_test_response(json_value* response, int ok):
	assert_equal(ok, json_object_get(response, c"ok").int_value)
	json_free(response)


struct wc2_resident_fixture:
	char* directory
	char* prefix
	char* common
	char* helper
	char* root
	char* sibling
	char* output


char* wc2_test_import_source(char* prefix, char* module_name, char* body):
	string_builder* source = string_new()
	string_append(source, c"import ")
	string_append(source, prefix)
	string_append_char(source, '.')
	string_append(source, module_name)
	string_append_char(source, '\n')
	string_append(source, body)
	char* result = strclone(source.data)
	string_free(source)
	return result


void wc2_test_import_write(char* file, char* prefix, char* module_name, char* body):
	char* source = wc2_test_import_source(prefix, module_name, body)
	assert1(file_write_text(file, source))
	free(source)


wc2_resident_fixture* wc2_resident_fixture_new():
	wc2_resident_fixture* f = new wc2_resident_fixture()
	string_builder* name = string_new()
	string_append(name, c"bin/wc2_resident_")
	string_append_int(name, getpid())
	f.directory = strclone(name.data)
	string_free(name)
	assert_equal(0, mkdir(f.directory, 493))
	f.prefix = strclone(f.directory)
	for i in range(strlen(f.prefix)):
		if (f.prefix[i] == '/'): f.prefix[i] = '.'
	f.common = path_join(f.directory, c"common.w")
	f.helper = path_join(f.directory, c"helper.w")
	f.root = path_join(f.directory, c"root.w")
	f.sibling = path_join(f.directory, c"sibling.w")
	f.output = path_join(f.directory, c"output")
	assert1(file_write_text(f.common, c"int shared(): return 10\n"))
	wc2_test_import_write(f.helper, f.prefix, c"common", c"int help(): return shared() + 1\n")
	wc2_test_import_write(f.root, f.prefix, c"helper", c"int main(): return help()\n")
	wc2_test_import_write(f.sibling, f.prefix, c"common", c"int main(): return shared()\n")
	return f


void wc2_resident_fixture_free(wc2_resident_fixture* f):
	unlink(f.common)
	unlink(f.helper)
	unlink(f.root)
	unlink(f.sibling)
	unlink(f.output)
	assert_equal(0, rmdir(f.directory))
	free(f.common)
	free(f.helper)
	free(f.root)
	free(f.sibling)
	free(f.output)
	free(f.prefix)
	free(f.directory)
	free(f)


void test_wc2_resident_reuse_and_invalidation():
	wc2_resident_fixture* f = wc2_resident_fixture_new()
	wc2_resident* r = wc2_resident_new()
	assert_equal(0, file_utimens(f.common, 1700000000, 1700000000, 0))
	json_value* response = wc2_test_request(r, c"symbols", f.root, 0)
	assert_equal(3, json_array_length(json_object_get(response, c"symbols")))
	wc2_test_response(response, 1)
	assert_equal(3, r.parses)
	assert_equal(0, r.analyses)
	char* original = wc2_dump(r.files[0].parsed)
	response = wc2_test_request(r, c"deps", f.root, 0)
	assert_equal(3, json_array_length(json_object_get(response, c"deps")))
	assert_equal(2, json_array_length(json_object_get(response, c"imports")))
	assert_equal(1, json_object_get(response, c"reused").int_value)
	wc2_test_response(response, 1)
	wc2_test_response(wc2_test_request(r, c"check", f.root, 0), 1)
	wc2_test_response(wc2_test_request(r, c"build", f.root, f.output), 1)
	wc2_test_exit(f.output, 11)
	wc2_test_response(wc2_test_request(r, c"build", f.root, f.output), 1)
	assert_equal(3, r.parses)
	assert_equal(1, r.analyses)
	assert_equal(1, r.emissions)
	char* after = wc2_dump(r.files[0].parsed)
	assert_strings_equal(original, after)
	free(original)
	free(after)
	wc2_test_response(wc2_test_request(r, c"check", f.sibling, 0), 1)
	assert_equal(4, r.parses)
	assert_equal(2, r.analyses)
	# Same-size, same-mtime edit; only the dependency's parse is replaced.
	assert1(file_write_text(f.common, c"int shared(): return 20\n"))
	assert_equal(0, file_utimens(f.common, 1700000000, 1700000000, 0))
	wc2_test_response(wc2_test_request(r, c"check", f.sibling, 0), 1)
	assert_equal(5, r.parses)
	assert_equal(3, r.analyses)
	wc2_test_response(wc2_test_request(r, c"build", f.root, f.output), 1)
	assert_equal(5, r.parses)
	assert_equal(4, r.analyses)
	wc2_test_exit(f.output, 21)
	# An unrelated root edit cannot invalidate this program.
	assert1(file_write_text(f.sibling, c"int main(): return 9\n"))
	wc2_test_response(wc2_test_request(r, c"check", f.root, 0), 1)
	assert_equal(5, r.parses)
	assert_equal(4, r.analyses)
	# Remove a transitive edge; the closure must shrink immediately.
	assert1(file_write_text(f.helper, c"int help(): return 31\n"))
	response = wc2_test_request(r, c"deps", f.root, 0)
	assert_equal(2, json_array_length(json_object_get(response, c"deps")))
	wc2_test_response(response, 1)
	wc2_test_response(wc2_test_request(r, c"build", f.root, f.output), 1)
	wc2_test_exit(f.output, 31)
	# I/O errors are request-local, not cached as a compilation failure.
	wc2_test_response(wc2_test_request(r, c"build", f.root, f.directory), 0)
	wc2_test_response(wc2_test_request(r, c"build", f.root, f.output), 1)
	wc2_test_response(wc2_test_request(r, c"clear", 0, 0), 1)
	assert_equal(0, r.files.length)
	assert_equal(0, r.programs.length)
	wc2_test_response(wc2_test_request(r, c"build", f.root, f.output), 1)
	wc2_test_exit(f.output, 31)
	wc2_resident_free(r)
	wc2_resident_fixture_free(f)


void test_wc2_resident_errors_and_repair():
	wc2_resident_fixture* f = wc2_resident_fixture_new()
	wc2_resident* r = wc2_resident_new()
	assert1(file_write_text(f.common, c"int shared(): return missing + other\nint bad(): return absent\n"))
	json_value* response = wc2_test_request(r, c"check", f.root, 0)
	json_value* diagnostics = json_object_get(response, c"diagnostics")
	assert1(json_array_length(diagnostics) >= 3)
	assert_contains(json_object_get(json_array_get(diagnostics, 0), c"file").string_value, c"common.w")
	int count = json_array_length(diagnostics)
	wc2_test_response(response, 0)
	response = wc2_test_request(r, c"check", f.root, 0)
	assert_equal(count, json_array_length(json_object_get(response, c"diagnostics")))
	wc2_test_response(response, 0)
	assert_equal(1, r.analyses)
	# Symbols are structural: a semantic error does not hide declarations.
	wc2_test_response(wc2_test_request(r, c"symbols", f.root, 0), 1)
	assert_equal(1, r.analyses)
	assert1(file_write_text(f.output, c"keep previous output"))
	wc2_test_response(wc2_test_request(r, c"build", f.root, f.output), 0)
	char* kept = file_read_text(f.output)
	assert_strings_equal(c"keep previous output", kept)
	free(kept)
	# Newly-created and deleted imports are noticed without an importer edit.
	unlink(f.common)
	wc2_test_response(wc2_test_request(r, c"check", f.root, 0), 0)
	assert1(file_write_text(f.common, c"int shared(): return 42\n"))
	wc2_test_response(wc2_test_request(r, c"build", f.root, f.output), 1)
	wc2_test_exit(f.output, 43)
	# Parse errors in two independent modules are reported together.
	assert1(file_write_text(f.helper, c"int broken(\n"))
	assert1(file_write_text(f.common, c"int invalid(\n"))
	char* tail = wc2_test_import_source(f.prefix, c"common", c"int main(): return 0\n")
	wc2_test_import_write(f.root, f.prefix, c"helper", tail)
	free(tail)
	response = wc2_test_request(r, c"check", f.root, 0)
	diagnostics = json_object_get(response, c"diagnostics")
	int helper_errors = 0
	int common_errors = 0
	for json_value* diagnostic in diagnostics.array_values:
		char* file = json_object_get(diagnostic, c"file").string_value
		if (ends_with(file, c"helper.w")): helper_errors = helper_errors + 1
		if (ends_with(file, c"common.w")): common_errors = common_errors + 1
	assert1(helper_errors > 0)
	assert1(common_errors > 0)
	wc2_test_response(response, 0)
	# Embedded NULs cannot turn a changed file into a hit on its old prefix.
	int fd = open(f.root, 577, 493)
	assert1(fd >= 0)
	assert_equal(29, write_all(fd, c"int main(): return 0\n\x00ignored", 29))
	close(fd)
	response = wc2_test_request(r, c"check", f.root, 0)
	assert_contains(json_object_get(json_array_get(json_object_get(response, c"diagnostics"), 0), c"message").string_value, c"embedded NUL")
	wc2_test_response(response, 0)
	unlink(f.root)
	wc2_test_response(wc2_test_request(r, c"check", f.root, 0), 0)
	assert1(file_write_text(f.root, c"int main(): return 0\n"))
	wc2_test_response(wc2_test_request(r, c"check", f.root, 0), 1)
	wc2_resident_free(r)
	wc2_resident_fixture_free(f)


void test_wc2_resident_import_shadowing():
	wc2_resident_fixture* f = wc2_resident_fixture_new()
	wc2_resident* r = wc2_resident_new()
	char* root = wc2_absolute_path(f.root)
	char* output = wc2_absolute_path(f.output)
	char* directory = wc2_absolute_path(f.directory)
	char* nested = path_join(directory, c"nested")
	char* shadow = path_join(nested, c"common.w")
	char[4096] cwd
	assert1(getcwd(cwd, 4096) >= 0)
	assert_equal(0, mkdir(nested, 493))
	assert1(file_write_text(root, c"import common\nint main(): return shared()\n"))
	assert_equal(0, chdir(nested))
	wc2_test_response(wc2_test_request(r, c"build", root, output), 1)
	wc2_test_exit(output, 10)
	assert_equal(2, r.parses)
	# A nearer module appears; no already-cached file changed.
	assert1(file_write_text(shadow, c"int shared(): return 20\n"))
	wc2_test_response(wc2_test_request(r, c"build", root, output), 1)
	wc2_test_exit(output, 20)
	assert_equal(3, r.parses)
	unlink(shadow)
	wc2_test_response(wc2_test_request(r, c"build", root, output), 1)
	wc2_test_exit(output, 10)
	assert_equal(3, r.parses)
	assert_equal(0, chdir(cwd))
	rmdir(nested)
	free(root)
	free(output)
	free(directory)
	free(nested)
	free(shadow)
	wc2_resident_free(r)
	wc2_resident_fixture_free(f)


void test_wc2_resident_program_eviction():
	wc2_resident_fixture* f = wc2_resident_fixture_new()
	wc2_resident* r = wc2_resident_new()
	list[char*] paths = new list[char*]
	for i in range(18):
		string_builder* name = string_new()
		string_append(name, f.directory)
		string_append(name, c"/root_")
		string_append_int(name, i)
		string_append(name, c".w")
		paths.push(strclone(name.data))
		assert1(file_write_text(name.data, c"int main(): return 0\n"))
		wc2_test_response(wc2_test_request(r, c"check", name.data, 0), 1)
		string_free(name)
	assert_equal(16, r.programs.length)
	assert_equal(18, r.files.length)
	assert_equal(18, r.parses)
	wc2_test_response(wc2_test_request(r, c"check", paths[0], 0), 1)
	assert_equal(18, r.parses)
	assert_equal(19, r.analyses)
	for char* path in paths:
		unlink(path)
		free(path)
	__w_list_free(cast(__w_list*, paths))
	wc2_resident_free(r)
	wc2_resident_fixture_free(f)


void test_wc2_resident_protocol():
	wc2_resident_fixture* f = wc2_resident_fixture_new()
	json_value* request = json_object()
	json_object_set(request, c"id", json_int(17))
	json_object_set(request, c"method", json_string(c"check"))
	json_object_set(request, c"file", json_string(f.root))
	char* request_text = json_stringify(request)
	string_builder* input = string_new()
	string_append(input, c"not json\n[]\n{\"method\":\"nope\"}\n{\"method\":\"build\",\"file\":12}\n")
	string_append(input, request_text)
	string_append_char(input, '\n')
	string_append(input, request_text)
	string_append(input, c"\n{\"method\":\"shutdown\",\"id\":\"done\"}\n")
	char** args = strv_new(2)
	strv_set(args, 0, c"bin/wc2")
	strv_set(args, 1, c"serve")
	process_result* result = process_run(c"bin/wc2", args, 0, input.data, 10000)
	assert1(result != 0)
	assert_equal(0, result.status)
	assert_strings_equal(c"", result.stderr_text)
	int start = 0
	int lines = 0
	for i in range(strlen(result.stdout_text)):
		if (result.stdout_text[i] != '\n'): continue
		char* line = path_clone_range(result.stdout_text + start, i - start)
		json_value* response = json_parse(line)
		assert1(response != 0)
		int want = lines >= 4
		assert_equal(want, json_object_get(response, c"ok").int_value)
		if ((lines == 4) || (lines == 5)): assert_equal(17, json_object_get(response, c"id").int_value)
		if (lines == 5):
			json_value* stats = json_object_get(response, c"stats")
			assert_equal(3, json_object_get(stats, c"parses").int_value)
			assert_equal(1, json_object_get(stats, c"analyses").int_value)
		if (lines == 6): assert_strings_equal(c"done", json_object_get(response, c"id").string_value)
		json_free(response)
		free(line)
		start = i + 1
		lines = lines + 1
	assert_equal(7, lines)
	process_result_free(result)
	free(cast(void*, args))
	free(request_text)
	json_free(request)
	string_free(input)
	wc2_resident_fixture_free(f)


void test_wc2_query_cli():
	char* path = wc2_emit_test_path(c".query.w")
	assert1(file_write_text(path, c"int library_function(): return 1\n"))
	char** args = strv_new(4)
	strv_set(args, 0, c"bin/wc2")
	strv_set(args, 1, c"symbols")
	strv_set(args, 2, c"--json")
	strv_set(args, 3, path)
	process_result* result = process_run(c"bin/wc2", args, 0, 0, 10000)
	assert_equal(0, result.status)
	assert_strings_equal(c"", result.stderr_text)
	json_value* response = json_parse(result.stdout_text)
	assert1(response != 0)
	json_value* symbol = json_array_get(json_object_get(response, c"symbols"), 0)
	assert_strings_equal(c"library_function", json_object_get(symbol, c"name").string_value)
	assert_equal(0, json_object_get(json_object_get(response, c"stats"), c"analyses").int_value)
	json_free(response)
	process_result_free(result)
	strv_set(args, 1, c"check")
	result = process_run(c"bin/wc2", args, 0, 0, 10000)
	assert_equal(1, result.status)
	assert_contains(result.stdout_text, c"requires int main()")
	process_result_free(result)
	free(cast(void*, args))
	args = strv_new(3)
	strv_set(args, 0, c"bin/wc2")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--json")
	result = process_run(c"bin/wc2", args, 0, 0, 10000)
	assert_equal(2, result.status)
	process_result_free(result)
	free(cast(void*, args))
	unlink(path)
	free(path)
