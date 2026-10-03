# wbuild: x64 tool=tools/wc2.w expect_stdout="wc2_resident_memory_test: OK"
import lib.assert
import tools.wc2.service


void wc2_memory_request(wc2_resident* r, char* method, char* file, char* output):
	json_value* request = json_object()
	json_object_set(request, c"method", json_string(method))
	json_object_set(request, c"file", json_string(file))
	json_object_set(request, c"output", json_string(output))
	json_value* response = wc2_resident_request(r, request)
	char* wire = json_stringify(response)
	free(wire)
	json_free(response)
	json_free(request)


int main():
	malloc_force_debug_mode()
	string_builder* base = string_new()
	string_append(base, c"bin/wc2_resident_memory_")
	string_append_int(base, getpid())
	char* dependency = strjoin(base.data, c"_dep.w")
	char* root = strjoin(base.data, c"_root.w")
	char* sibling = strjoin(base.data, c"_sibling.w")
	char* output = strjoin(base.data, c"_output")
	string_builder* source = string_new()
	string_append(source, c"import ")
	for i in range(base.length):
		int ch = base.data[i]
		if (ch == '/'): ch = '.'
		string_append_char(source, ch)
	string_append(source, c"_dep\nint main(): return value()\n")
	assert1(file_write_text(root, source.data))
	assert1(file_write_text(sibling, source.data))
	assert1(file_write_text(dependency, c"int value(): return 7\n"))
	wc2_resident* r = wc2_resident_new()
	for i in range(3):
		wc2_memory_request(r, c"symbols", root, output)
		wc2_memory_request(r, c"deps", root, output)
		wc2_memory_request(r, c"build", root, output)
		wc2_memory_request(r, c"build", sibling, output)
	assert_equal(3, r.parses)
	assert_equal(2, r.analyses)
	assert_equal(2, r.emissions)
	assert1(file_write_text(dependency, c"int value(): return missing + other\n"))
	wc2_memory_request(r, c"check", root, output)
	# The other root still owns its old checked snapshot while the shared
	# parsed dependency has been freed/replaced. Refresh it independently.
	wc2_memory_request(r, c"check", sibling, output)
	assert1(file_write_text(dependency, c"int broken(\n"))
	wc2_memory_request(r, c"check", root, output)
	unlink(dependency)
	wc2_memory_request(r, c"check", root, output)
	assert1(file_write_text(dependency, c"int value(): return 9\n"))
	wc2_memory_request(r, c"build", root, output)
	wc2_resident_clear(r)
	wc2_memory_request(r, c"build", root, output)
	wc2_resident_free(r)
	unlink(dependency)
	unlink(root)
	unlink(sibling)
	unlink(output)
	free(dependency)
	free(root)
	free(sibling)
	free(output)
	string_free(base)
	string_free(source)
	assert_equal(0, debug_alloc_report_leaks())
	println(c"wc2_resident_memory_test: OK")
	return 0
