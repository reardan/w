# One JSON object per input/output line. The foreground process owns all
# resident state and exits on EOF or shutdown; no sockets or child compiler.
import tools.wc2.resident
import lib.stream


json_value* wc2_request_error(char* message):
	json_value* response = json_object()
	json_object_set(response, c"ok", json_bool(0))
	json_object_set(response, c"error", json_string(message))
	return response


char* wc2_request_string(json_value* request, char* key):
	json_value* value = json_object_get(request, key)
	if ((value == 0) || (value.type != json_type_string())): return 0
	if (value.string_value[0] == 0): return 0
	return value.string_value


json_value* wc2_resident_request(wc2_resident* r, json_value* request):
	if ((request == 0) || (request.type != json_type_object())): return wc2_request_error(c"request must be a JSON object")
	char* method = wc2_request_string(request, c"method")
	if (method == 0): return wc2_request_error(c"method must be a nonempty string")
	if ((strcmp(method, c"stats") == 0) || (strcmp(method, c"clear") == 0) || (strcmp(method, c"shutdown") == 0)):
		if (strcmp(method, c"clear") == 0): wc2_resident_clear(r)
		json_value* response = json_object()
		json_object_set(response, c"ok", json_bool(1))
		json_object_set(response, c"stats", wc2_resident_stats(r))
		return response
	int checking = strcmp(method, c"check") == 0
	int building = strcmp(method, c"build") == 0
	int symbols = strcmp(method, c"symbols") == 0
	int deps = strcmp(method, c"deps") == 0
	if ((checking || building || symbols || deps) == 0): return wc2_request_error(c"unknown method")
	char* file = wc2_request_string(request, c"file")
	if (file == 0): return wc2_request_error(c"file must be a nonempty string")
	char* output = 0
	if (building):
		output = wc2_request_string(request, c"output")
		if (output == 0): return wc2_request_error(c"build requires a nonempty output string")
	char* path = wc2_absolute_path(file)
	if (path == 0): return wc2_request_error(c"cannot read working directory")
	int hits = r.program_hits
	wc2_cached_program* program = wc2_resident_program(r, path)
	free(path)
	json_value* diagnostics = json_clone(program.diagnostics)
	if (checking || building):
		wc2_resident_check(r, program)
		if (program.linked != 0): wc2_collect_diagnostics(diagnostics, program.linked)
	int ok = json_array_length(diagnostics) == 0
	if (building && ok):
		if (program.image == 0):
			program.image = wc2_emit_checked(program.semantic)
			r.emissions = r.emissions + 1
		if (wc2_write_executable(output, program.image) == 0):
			ok = 0
			json_array_push(diagnostics, wc2_diagnostic_json(output, 0, 0, c"wc2: cannot write executable"))
	json_value* response = json_object()
	json_object_set(response, c"ok", json_bool(ok))
	json_object_set(response, c"revision", json_int(program.revision))
	json_object_set(response, c"reused", json_bool(r.program_hits > hits))
	json_object_set(response, c"diagnostics", diagnostics)
	if (symbols): json_object_set(response, c"symbols", json_clone(program.symbols))
	if (deps):
		json_object_set(response, c"deps", json_clone(program.deps))
		json_object_set(response, c"imports", json_clone(program.edges))
	json_object_set(response, c"stats", wc2_resident_stats(r))
	return response


int wc2_serve():
	wc2_resident* r = wc2_resident_new()
	wstream* input = stream_reader(0)
	string_builder* line = string_new()
	while (stream_read_line(input, line)):
		json_value* request = json_parse(line.data)
		json_value* response = wc2_resident_request(r, request)
		int stop = 0
		if ((request != 0) && (request.type == json_type_object())):
			json_value* id = json_object_get(request, c"id")
			if (id != 0): json_object_set(response, c"id", json_clone(id))
			char* method = wc2_request_string(request, c"method")
			if (method != 0): stop = strcmp(method, c"shutdown") == 0
		char* text = json_stringify(response)
		println(text)
		free(text)
		json_free(response)
		json_free(request)
		if (stop): break
	string_free(line)
	stream_free(input)
	wc2_resident_free(r)
	return 0


int wc2_query_once(char* method, char* file):
	wc2_resident* r = wc2_resident_new()
	json_value* request = json_object()
	json_object_set(request, c"method", json_string(method))
	json_object_set(request, c"file", json_string(file))
	json_value* response = wc2_resident_request(r, request)
	char* text = json_stringify(response)
	println(text)
	int status = 1
	if (json_object_get(response, c"ok").int_value): status = 0
	free(text)
	json_free(response)
	json_free(request)
	wc2_resident_free(r)
	return status
