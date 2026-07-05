/*
wexec: the W-native build executor — the MVP replacement for the Makefile.

wexec reads a static JSON manifest (build.json by default) describing
build/test targets, resolves their dependency DAG depth-first, and runs
each target's steps as child processes via lib.process. It deliberately
knows nothing about W itself: the manifest spells out every command, so
porting a Makefile rule is a mechanical transcription and the executor
core stays small enough to trust.

Manifest shape:

{
	"dirs": ["bin"],
	"targets": [
		{
			"name": "hello",
			"deps": ["wv2"],
			"steps": [
				{"cmd": ["bin/wv2", "tests/hello.w", "-o", "bin/hello"]},
				{"cmd": ["bin/hello"], "expect_stdout": "hello, world!"}
			]
		}
	]
}

Step fields: "cmd" (argv, required; argv[0] is resolved against PATH
when it contains no slash), "stdin" (text piped to the child),
"expect_stdout" / "expect_stderr" (a substring — or array of
substrings — the captured stream must contain), "reject_stdout" /
"reject_stderr" (substring(s) that must NOT appear, the manifest's
version of "! grep -q"), "expect_fail" (the step must exit nonzero,
the manifest's version of Make's "! cmd"), "expect_status" (an exact
exit code), "stdout_file" / "stderr_file" (write the captured stream
to a path, replacing shell "> file" redirects), and "timeout_ms"
(0 = no timeout).

Every target runs at most once per invocation and there is no caching:
like the Makefile's FORCE targets, requesting a target always runs it.
A step's captured stdout/stderr is re-emitted after the step finishes,
so output is visible but not interleaved live.

Usage: wexec [-f manifest.json] [--list] target...

Design notes: docs/projects/wexec.md
*/
import lib.lib
import lib.env
import lib.file
import lib.process
import lib.stream
import structures.string
import structures.json
import structures.hash_map


json_value* wexec_manifest
hash_map* wexec_targets      # name -> json_value* of the target object
hash_map* wexec_states       # name -> 0 unvisited / 1 running / 2 done
list[char*] wexec_names      # manifest order, for --list
int wexec_completed          # targets finished this invocation


int wexec_run_target(char* name);


void wexec_error(char* message):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wexec: error: ")
	stream_write_line(err, message)
	stream_flush(err)


void wexec_error2(char* message, char* detail):
	string_builder* s = string_new()
	string_append(s, message)
	string_append(s, detail)
	wexec_error(s.data)
	string_free(s)


void wexec_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wexec [-f manifest.json] [--list] target...")
	stream_flush(err)


/* JSON field accessors tolerating absent keys. */

char* wexec_get_string(json_value* object, char* key):
	json_value* value = json_object_get(object, key)
	if (value == 0):
		return 0
	if (value.type != json_type_string()):
		return 0
	return value.string_value


int wexec_get_int(json_value* object, char* key, int missing):
	json_value* value = json_object_get(object, key)
	if (value == 0):
		return missing
	if (value.type != json_type_int()):
		return missing
	return value.int_value


int wexec_get_flag(json_value* object, char* key):
	json_value* value = json_object_get(object, key)
	if (value == 0):
		return 0
	if ((value.type == json_type_bool()) | (value.type == json_type_int())):
		return value.int_value != 0
	return 0


int wexec_str_contains(char* haystack, char* needle):
	int n = strlen(needle)
	if (n == 0):
		return 1
	int i = 0
	while (haystack[i] != 0):
		int j = 0
		while ((j < n) & (haystack[i + j] == needle[j])):
			j = j + 1
		if (j == n):
			return 1
		i = i + 1
	return 0


# execve does no PATH lookup, so commands like "cmp" or "grep" must be
# resolved here. Anything with a slash is used as-is.
char* wexec_resolve_program(char* name):
	int i = 0
	while (name[i] != 0):
		if (name[i] == '/'):
			return name
		i = i + 1
	char* path = env_get(c"PATH")
	if (path == 0):
		path = c"/usr/bin:/bin"
	string_builder* candidate = string_new()
	int p = 0
	int at_end = 0
	while (at_end == 0):
		string_clear(candidate)
		while ((path[p] != ':') & (path[p] != 0)):
			string_append_char(candidate, path[p])
			p = p + 1
		if (path[p] == 0):
			at_end = 1
		else:
			p = p + 1
		if (candidate.length > 0):
			string_append_char(candidate, '/')
			string_append(candidate, name)
			int fd = open(candidate.data, 0, 0)
			if (fd >= 0):
				close(fd)
				return candidate.data
	string_free(candidate)
	return name


void wexec_echo_command(char** argv, int count):
	string_builder* line = string_new()
	string_append(line, c"$")
	int i = 0
	while (i < count):
		string_append(line, c" ")
		string_append(line, strv_get(argv, i))
		i = i + 1
	wstream* out = stdout_writer()
	stream_write_line(out, line.data)
	stream_flush(out)
	string_free(line)


void wexec_step_error(char* target_name, int step_index, char* message):
	string_builder* s = string_new()
	string_append(s, c"target '")
	string_append(s, target_name)
	string_append(s, c"' step ")
	string_append_int(s, step_index + 1)
	string_append(s, c": ")
	string_append(s, message)
	wexec_error(s.data)
	string_free(s)


# Re-emit the child's captured streams so build output stays visible.
void wexec_emit_output(process_result* result):
	if (result.stdout_length > 0):
		write(1, result.stdout_text, result.stdout_length)
	if (result.stderr_length > 0):
		write(2, result.stderr_text, result.stderr_length)


int wexec_check_status(char* target_name, int step_index, json_value* step, process_result* result):
	if (result.status < 0):
		wexec_step_error(target_name, step_index, c"command timed out or could not be waited on")
		return 1
	json_value* wanted = json_object_get(step, c"expect_status")
	if (wanted != 0):
		if (wanted.type != json_type_int()):
			wexec_step_error(target_name, step_index, c"\"expect_status\" must be an integer")
			return 1
		if (result.status != wanted.int_value):
			string_builder* s = string_new()
			string_append(s, c"command exited ")
			string_append_int(s, result.status)
			string_append(s, c", expected status ")
			string_append_int(s, wanted.int_value)
			wexec_step_error(target_name, step_index, s.data)
			string_free(s)
			return 1
		return 0
	if (wexec_get_flag(step, c"expect_fail")):
		if (result.status == 0):
			wexec_step_error(target_name, step_index, c"command was expected to fail but exited 0")
			return 1
		return 0
	if (result.status != 0):
		string_builder* s = string_new()
		string_append(s, c"command failed with exit status ")
		string_append_int(s, result.status)
		wexec_step_error(target_name, step_index, s.data)
		string_free(s)
		return 1
	return 0


# reject != 0 inverts the check: the needle must be absent.
int wexec_check_needle(char* target_name, int step_index, char* stream_name, char* text, char* needle, int reject):
	int found = wexec_str_contains(text, needle)
	if (reject == 0):
		if (found):
			return 0
	else:
		if (found == 0):
			return 0
	string_builder* s = string_new()
	string_append(s, c"expected ")
	string_append(s, stream_name)
	if (reject):
		string_append(s, c" to not contain: ")
	else:
		string_append(s, c" to contain: ")
	string_append(s, needle)
	wexec_step_error(target_name, step_index, s.data)
	string_free(s)
	return 1


# An expectation field may be a single substring or an array of them.
int wexec_check_expectation(char* target_name, int step_index, json_value* step, char* key, char* stream_name, char* text, int reject):
	json_value* value = json_object_get(step, key)
	if (value == 0):
		return 0
	if (value.type == json_type_string()):
		return wexec_check_needle(target_name, step_index, stream_name, text, value.string_value, reject)
	if (value.type != json_type_array()):
		wexec_error2(c"expectation must be a string or array of strings: ", key)
		return 1
	int i = 0
	while (i < json_array_length(value)):
		json_value* entry = json_array_get(value, i)
		if (entry.type != json_type_string()):
			wexec_error2(c"expectation array entries must be strings: ", key)
			return 1
		if (wexec_check_needle(target_name, step_index, stream_name, text, entry.string_value, reject)):
			return 1
		i = i + 1
	return 0


# "stdout_file" / "stderr_file": save the captured stream to a path,
# the manifest's version of a "> file" shell redirect.
int wexec_write_capture(char* target_name, int step_index, json_value* step, char* key, char* data, int length):
	char* path = wexec_get_string(step, key)
	if (path == 0):
		return 0
	# 577 = O_WRONLY | O_CREAT | O_TRUNC, 420 = rw-r--r--
	int fd = open(path, 577, 420)
	if (fd < 0):
		wexec_step_error(target_name, step_index, c"cannot write capture file")
		return 1
	int written = 0
	if (length > 0):
		written = write(fd, data, length)
	close(fd)
	if (written < length):
		wexec_step_error(target_name, step_index, c"short write to capture file")
		return 1
	return 0


int wexec_run_step(char* target_name, int step_index, json_value* step):
	if (step.type != json_type_object()):
		wexec_step_error(target_name, step_index, c"step is not a JSON object")
		return 1
	json_value* cmd = json_object_get(step, c"cmd")
	if (cmd == 0):
		wexec_step_error(target_name, step_index, c"step has no \"cmd\"")
		return 1
	if (cmd.type != json_type_array()):
		wexec_step_error(target_name, step_index, c"\"cmd\" is not an array")
		return 1
	int count = json_array_length(cmd)
	if (count < 1):
		wexec_step_error(target_name, step_index, c"\"cmd\" is empty")
		return 1

	char** argv = strv_new(count)
	int i = 0
	while (i < count):
		json_value* piece = json_array_get(cmd, i)
		if (piece.type != json_type_string()):
			wexec_step_error(target_name, step_index, c"\"cmd\" entries must be strings")
			free(cast(char*, argv))
			return 1
		strv_set(argv, i, piece.string_value)
		i = i + 1

	wexec_echo_command(argv, count)
	char* program = wexec_resolve_program(strv_get(argv, 0))
	char* stdin_text = wexec_get_string(step, c"stdin")
	int timeout_ms = wexec_get_int(step, c"timeout_ms", 0)
	process_result* result = process_run(program, argv, 0, stdin_text, timeout_ms)
	free(cast(char*, argv))
	if (result == 0):
		wexec_step_error(target_name, step_index, c"failed to spawn command")
		return 1

	wexec_emit_output(result)
	int failed = wexec_write_capture(target_name, step_index, step, c"stdout_file", result.stdout_text, result.stdout_length)
	if (failed == 0):
		failed = wexec_write_capture(target_name, step_index, step, c"stderr_file", result.stderr_text, result.stderr_length)
	if (failed == 0):
		failed = wexec_check_status(target_name, step_index, step, result)
	if (failed == 0):
		failed = wexec_check_expectation(target_name, step_index, step, c"expect_stdout", c"stdout", result.stdout_text, 0)
	if (failed == 0):
		failed = wexec_check_expectation(target_name, step_index, step, c"expect_stderr", c"stderr", result.stderr_text, 0)
	if (failed == 0):
		failed = wexec_check_expectation(target_name, step_index, step, c"reject_stdout", c"stdout", result.stdout_text, 1)
	if (failed == 0):
		failed = wexec_check_expectation(target_name, step_index, step, c"reject_stderr", c"stderr", result.stderr_text, 1)
	process_result_free(result)
	return failed


int wexec_run_deps(char* name, json_value* target):
	json_value* deps = json_object_get(target, c"deps")
	if (deps == 0):
		return 0
	if (deps.type != json_type_array()):
		wexec_error2(c"\"deps\" is not an array in target ", name)
		return 1
	int i = 0
	while (i < json_array_length(deps)):
		json_value* dep = json_array_get(deps, i)
		if (dep.type != json_type_string()):
			wexec_error2(c"\"deps\" entries must be strings in target ", name)
			return 1
		if (wexec_run_target(dep.string_value)):
			return 1
		i = i + 1
	return 0


int wexec_run_target(char* name):
	int state = hash_map_get_default(wexec_states, name, 0)
	if (state == 2):
		return 0
	if (state == 1):
		wexec_error2(c"dependency cycle involving target ", name)
		return 1
	json_value* target = cast(json_value*, hash_map_get_default(wexec_targets, name, 0))
	if (target == 0):
		wexec_error2(c"unknown target ", name)
		return 1
	hash_map_set(wexec_states, name, 1)
	if (wexec_run_deps(name, target)):
		return 1

	wstream* out = stdout_writer()
	stream_write_cstr(out, c"wexec: target ")
	stream_write_line(out, name)
	stream_flush(out)

	json_value* steps = json_object_get(target, c"steps")
	if (steps != 0):
		if (steps.type != json_type_array()):
			wexec_error2(c"\"steps\" is not an array in target ", name)
			return 1
		int i = 0
		while (i < json_array_length(steps)):
			if (wexec_run_step(name, i, json_array_get(steps, i))):
				return 1
			i = i + 1
	hash_map_set(wexec_states, name, 2)
	wexec_completed = wexec_completed + 1
	return 0


void wexec_make_dirs():
	json_value* dirs = json_object_get(wexec_manifest, c"dirs")
	if (dirs == 0):
		return
	if (dirs.type != json_type_array()):
		return
	int i = 0
	while (i < json_array_length(dirs)):
		json_value* dir = json_array_get(dirs, i)
		if (dir.type == json_type_string()):
			# Failure (usually EEXIST) is fine; a truly missing
			# directory surfaces when a step tries to use it.
			mkdir(dir.string_value, 493)
		i = i + 1


int wexec_load_manifest(char* path):
	char* text = file_read_text(path)
	if (text == 0):
		wexec_error2(c"cannot read manifest ", path)
		return 1
	wexec_manifest = json_parse(text)
	free(text)
	if (wexec_manifest == 0):
		wexec_error2(c"manifest is not valid JSON: ", path)
		return 1
	if (wexec_manifest.type != json_type_object()):
		wexec_error2(c"manifest root must be a JSON object: ", path)
		return 1
	json_value* targets = json_object_get(wexec_manifest, c"targets")
	if (targets == 0):
		wexec_error2(c"manifest has no \"targets\" array: ", path)
		return 1
	if (targets.type != json_type_array()):
		wexec_error2(c"\"targets\" must be an array: ", path)
		return 1

	wexec_targets = hash_map_new()
	wexec_states = hash_map_new()
	wexec_names = new list[char*]
	int i = 0
	while (i < json_array_length(targets)):
		json_value* target = json_array_get(targets, i)
		if (target.type != json_type_object()):
			wexec_error2(c"every target must be a JSON object: ", path)
			return 1
		char* name = wexec_get_string(target, c"name")
		if (name == 0):
			wexec_error2(c"target without a \"name\" string: ", path)
			return 1
		if (hash_map_contains(wexec_targets, name)):
			wexec_error2(c"duplicate target ", name)
			return 1
		hash_map_set(wexec_targets, name, cast(int, target))
		wexec_names.push(name)
		i = i + 1
	wexec_make_dirs()
	return 0


void wexec_list_targets():
	wstream* out = stdout_writer()
	for char* name in wexec_names:
		stream_write_line(out, name)
	stream_flush(out)


void wexec_report_ok():
	string_builder* s = string_new()
	string_append(s, c"wexec: OK (")
	string_append_int(s, wexec_completed)
	string_append(s, c" targets)")
	wstream* out = stdout_writer()
	stream_write_line(out, s.data)
	stream_flush(out)
	string_free(s)


int main(int argc, int argv):
	char* manifest_path = c"build.json"
	list[char*] requested = new list[char*]
	int list_only = 0
	int i = 1
	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"-f") == 0):
			i = i + 1
			if (i >= argc):
				wexec_usage()
				return 1
			char** value = argv + i * __word_size__
			manifest_path = *value
		else if (strcmp(*arg, c"--list") == 0):
			list_only = 1
		else:
			requested.push(*arg)
		i = i + 1

	if (wexec_load_manifest(manifest_path)):
		return 1
	if (list_only):
		wexec_list_targets()
		return 0
	if (requested.length == 0):
		wexec_usage()
		wexec_list_targets()
		return 1
	for char* name in requested:
		if (wexec_run_target(name)):
			return 1
	wexec_report_ok()
	return 0
