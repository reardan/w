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

Every target runs at most once per invocation. Targets that declare
"inputs" (a list of files and directory prefixes ending in "/") are
cached by content hash: when the hash of the target definition, its
input files and its dependencies' keys matches the stamp left in
bin/.wexec_cache/ — and every declared "outputs" file exists — the
target is skipped. Targets without "inputs" behave like the Makefile's
FORCE targets: requesting them always runs them. A step's captured
stdout/stderr is re-emitted after the step finishes, so output is
visible but not interleaved live.

Usage: wexec [-f manifest.json] [--list] [--no-cache] [-j N] target...

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
hash_map* wexec_states       # name -> 0 unvisited / 1 visiting / 2 collected
hash_map* wexec_keys         # name -> char* cache key, for targets with "inputs"
hash_map* wexec_started      # name -> 1 once launched (or completed inline)
hash_map* wexec_finished     # name -> 1 once successfully finished
list[char*] wexec_names      # manifest order, for --list
list[char*] wexec_closure    # requested targets + deps, dependency order
int wexec_completed          # targets finished this invocation
int wexec_no_cache           # --no-cache: never skip cached targets
int wexec_jobs               # max targets in flight (-j), default nproc
int wexec_mask32             # keeps the hash accumulators at 32 bits on x64


int wexec_collect_closure(char* name);
void wexec_collect_dir(char* path, list[char*] files);


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
	stream_write_line(err, c"usage: wexec [-f manifest.json] [--list] [--no-cache] [-j N] target...")
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


/* Content-hash caching.

A target that declares "inputs" gets a cache key: a 64-bit FNV-style
hash over its serialized definition, its dependencies' cache keys and
the contents of every input file (directory entries ending in "/" are
walked recursively). The key is stamped into bin/.wexec_cache/<name>
after a successful run; a matching stamp plus existing "outputs" files
lets the next invocation skip the target. A target whose dependency
has no cache key (a FORCE-style target) is never cacheable, because a
fresh dependency run may have changed what this target consumes. */

struct wexec_hash:
	int h1
	int h2


int wexec_mask32_value():
	if (__word_size__ == 8):
		int high = 1 << 16
		return high * high - 1
	return -1


void wexec_hash_init(wexec_hash* h):
	# The FNV offset basis (2166136261 as a signed 32-bit value)
	h.h1 = -2128831035 & wexec_mask32
	h.h2 = 1000003


# Two 32-bit multiplicative rolling hashes with independent multipliers
# (the FNV prime and a prime from Python's tuple hash). W has no xor
# operator, so this is polynomial accumulation rather than FNV proper;
# 64 combined bits is plenty for build staleness detection.
void wexec_hash_bytes(wexec_hash* h, char* data, int n):
	int i = 0
	while (i < n):
		int byte = data[i] & 255
		h.h1 = (h.h1 * 16777619 + byte) & wexec_mask32
		h.h2 = (h.h2 * 1000003 + byte) & wexec_mask32
		i = i + 1


# Strings never contain NUL, so a trailing 0 byte keeps consecutive
# strings from colliding with their concatenation.
void wexec_hash_cstr(wexec_hash* h, char* text):
	wexec_hash_bytes(h, text, strlen(text))
	char zero = 0
	wexec_hash_bytes(h, &zero, 1)


void wexec_hash_file(wexec_hash* h, char* path):
	int fd = open(path, 0, 0)
	if (fd < 0):
		wexec_hash_cstr(h, c"<missing input>")
		return
	char* buffer = malloc(4096)
	int n = read(fd, buffer, 4096)
	while (n > 0):
		wexec_hash_bytes(h, buffer, n)
		n = read(fd, buffer, 4096)
	free(buffer)
	close(fd)


void wexec_append_hex(string_builder* s, int value):
	int shift = 28
	while (shift >= 0):
		int nibble = (value >> shift) & 15
		if (nibble < 10):
			string_append_char(s, '0' + nibble)
		else:
			string_append_char(s, 'a' + nibble - 10)
		shift = shift - 4


char* wexec_hash_hex(wexec_hash* h):
	string_builder* s = string_new()
	wexec_append_hex(s, h.h1)
	wexec_append_hex(s, h.h2)
	char* text = s.data
	free(s)
	return text


int wexec_load_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


# Recursively collect every regular file under path. Uses the classic
# getdents layout: d_reclen is 2 bytes after ino and off (one word each),
# the name follows it, and d_type sits in the record's last byte
# (4 = directory, 8 = regular file).
void wexec_collect_dir(char* path, list[char*] files):
	# 65536 = O_DIRECTORY
	int fd = open(path, 65536, 0)
	if (fd < 0):
		return
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* entry = buffer + off
			int reclen = wexec_load_uint16(entry + 2 * __word_size__)
			char* entry_name = entry + 2 * __word_size__ + 2
			int kind = entry[reclen - 1] & 255
			if ((strcmp(entry_name, c".") != 0) && (strcmp(entry_name, c"..") != 0)):
				string_builder* child = string_new()
				string_append(child, path)
				string_append(child, c"/")
				string_append(child, entry_name)
				if (kind == 4):
					wexec_collect_dir(child.data, files)
					string_free(child)
				else if (kind == 8):
					char* owned = child.data
					free(child)
					files.push(owned)
				else:
					string_free(child)
			off = off + reclen
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)


# Insertion sort: getdents order depends on filesystem state, and the
# hash must not.
void wexec_sort_strings(list[char*] files):
	int i = 1
	while (i < files.length):
		char* value = files[i]
		int j = i - 1
		while ((j >= 0) && (strcmp(files[j], value) > 0)):
			files[j + 1] = files[j]
			j = j - 1
		files[j + 1] = value
		i = i + 1


char* wexec_stamp_path(char* name):
	string_builder* s = string_new()
	string_append(s, c"bin/.wexec_cache/")
	string_append(s, name)
	char* path = s.data
	free(s)
	return path


# Returns the target's cache key, or 0 when the target is not cacheable
# (no "inputs" declared, or a dependency without a key of its own).
# Dependencies must have finished before this is called.
char* wexec_cache_key(char* name, json_value* target):
	json_value* inputs = json_object_get(target, c"inputs")
	if (inputs == 0):
		return 0
	if (inputs.type != json_type_array()):
		return 0

	wexec_hash h
	wexec_hash_init(&h)
	char* definition = json_stringify(target)
	wexec_hash_cstr(&h, definition)
	free(definition)

	json_value* deps = json_object_get(target, c"deps")
	if (deps != 0):
		if (deps.type == json_type_array()):
			int i = 0
			while (i < json_array_length(deps)):
				json_value* dep = json_array_get(deps, i)
				if (dep.type == json_type_string()):
					char* dep_key = cast(char*, hash_map_get_default(wexec_keys, dep.string_value, 0))
					if (dep_key == 0):
						return 0
					wexec_hash_cstr(&h, dep_key)
				i = i + 1

	list[char*] files = new list[char*]
	int i = 0
	while (i < json_array_length(inputs)):
		json_value* entry = json_array_get(inputs, i)
		if (entry.type == json_type_string()):
			char* path = entry.string_value
			int n = strlen(path)
			if ((n > 0) && (path[n - 1] == '/')):
				char* dir = strclone(path)
				dir[n - 1] = 0
				wexec_collect_dir(dir, files)
				free(dir)
			else:
				files.push(path)
		i = i + 1
	wexec_sort_strings(files)
	for char* path in files:
		wexec_hash_cstr(&h, path)
		wexec_hash_file(&h, path)
	return wexec_hash_hex(&h)


# A cache hit needs a matching stamp and every declared output present.
int wexec_cache_fresh(char* name, char* key, json_value* target):
	char* stamp_path = wexec_stamp_path(name)
	char* stamp = file_read_text(stamp_path)
	free(stamp_path)
	if (stamp == 0):
		return 0
	int same = strcmp(stamp, key) == 0
	free(stamp)
	if (same == 0):
		return 0
	json_value* outputs = json_object_get(target, c"outputs")
	if (outputs != 0):
		if (outputs.type == json_type_array()):
			int i = 0
			while (i < json_array_length(outputs)):
				json_value* output = json_array_get(outputs, i)
				if (output.type == json_type_string()):
					int fd = open(output.string_value, 0, 0)
					if (fd < 0):
						return 0
					close(fd)
				i = i + 1
	return 1


void wexec_cache_store(char* name, char* key):
	# Failure (usually EEXIST) is fine, like wexec_make_dirs.
	mkdir(c"bin", 493)
	mkdir(c"bin/.wexec_cache", 493)
	char* stamp_path = wexec_stamp_path(name)
	file_write_text(stamp_path, key)
	free(stamp_path)


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


/* The scheduler.

Targets run as concurrently forked copies of wexec itself: the child
redirects its stdout/stderr into pipes and runs the target's steps with
the ordinary sequential machinery, so everything a target prints stays
attributable to it. The parent polls every worker's pipes, buffers
output, and prints each target's output in start order (the oldest
in-flight worker streams live, later ones are held back until it
finishes), so parallel logs never interleave. Cache keys are computed
and stamps written by the parent only; a cache hit completes a target
without forking. The first failure stops new launches, in-flight
targets are drained, and the run exits 1 — make without -k. */

# Depth-first closure collection: validates deps, diagnoses unknown
# targets and cycles, and appends every reachable target in dependency
# order (the serial execution order) to wexec_closure.
int wexec_collect_closure(char* name):
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
	json_value* deps = json_object_get(target, c"deps")
	if (deps != 0):
		if (deps.type != json_type_array()):
			wexec_error2(c"\"deps\" is not an array in target ", name)
			return 1
		int i = 0
		while (i < json_array_length(deps)):
			json_value* dep = json_array_get(deps, i)
			if (dep.type != json_type_string()):
				wexec_error2(c"\"deps\" entries must be strings in target ", name)
				return 1
			if (wexec_collect_closure(dep.string_value)):
				return 1
			i = i + 1
	hash_map_set(wexec_states, name, 2)
	wexec_closure.push(name)
	return 0


int wexec_deps_finished(char* name):
	json_value* target = cast(json_value*, hash_map_get_default(wexec_targets, name, 0))
	json_value* deps = json_object_get(target, c"deps")
	if (deps == 0):
		return 1
	int i = 0
	while (i < json_array_length(deps)):
		json_value* dep = json_array_get(deps, i)
		if (hash_map_get_default(wexec_finished, dep.string_value, 0) == 0):
			return 0
		i = i + 1
	return 1


void wexec_print_target_header(char* name, char* suffix):
	wstream* out = stdout_writer()
	stream_write_cstr(out, c"wexec: target ")
	stream_write_cstr(out, name)
	stream_write_line(out, suffix)
	stream_flush(out)


int wexec_run_steps(char* name, json_value* target):
	json_value* steps = json_object_get(target, c"steps")
	if (steps == 0):
		return 0
	if (steps.type != json_type_array()):
		wexec_error2(c"\"steps\" is not an array in target ", name)
		return 1
	int i = 0
	while (i < json_array_length(steps)):
		if (wexec_run_step(name, i, json_array_get(steps, i))):
			return 1
		i = i + 1
	return 0


struct wexec_worker:
	char* name
	char* key            # cache key to stamp on success, or 0
	int pid
	int stdout_fd        # -1 once EOF
	int stderr_fd
	process_capture* out_buffer
	process_capture* err_buffer
	int out_printed      # bytes already written through to our stdout
	int err_printed
	int done


void wexec_mark_finished(char* name, char* key):
	if (key != 0):
		wexec_cache_store(name, key)
	hash_map_set(wexec_finished, name, 1)
	wexec_completed = wexec_completed + 1


# Launch one target. Returns 0 when the target completed inline (cache
# hit or no steps), 1 when a worker was forked, -1 on spawn failure.
int wexec_launch(char* name, list[wexec_worker*] workers):
	json_value* target = cast(json_value*, hash_map_get_default(wexec_targets, name, 0))
	char* key = wexec_cache_key(name, target)
	if (key != 0):
		hash_map_set(wexec_keys, name, cast(int, key))
		if ((wexec_no_cache == 0) && wexec_cache_fresh(name, key, target)):
			wexec_print_target_header(name, c" (cached)")
			hash_map_set(wexec_finished, name, 1)
			wexec_completed = wexec_completed + 1
			return 0
	json_value* steps = json_object_get(target, c"steps")
	if (steps == 0):
		# Aggregate target: nothing to fork.
		wexec_print_target_header(name, c"")
		wexec_mark_finished(name, key)
		return 0

	int out_read = -1
	int out_write = -1
	int err_read = -1
	int err_write = -1
	if (process_make_pipe(&out_read, &out_write) < 0):
		wexec_error2(c"cannot create pipes for target ", name)
		return -1
	if (process_make_pipe(&err_read, &err_write) < 0):
		close(out_read)
		close(out_write)
		wexec_error2(c"cannot create pipes for target ", name)
		return -1
	int pid = fork()
	if (pid < 0):
		close(out_read)
		close(out_write)
		close(err_read)
		close(err_write)
		wexec_error2(c"cannot fork worker for target ", name)
		return -1
	if (pid == 0):
		# Worker: everything we print belongs to this target.
		close(out_read)
		close(err_read)
		process_redirect(out_write, 1)
		process_redirect(err_write, 2)
		wexec_print_target_header(name, c"")
		exit(wexec_run_steps(name, target))
	close(out_write)
	close(err_write)

	wexec_worker* w = new wexec_worker()
	w.name = name
	w.key = key
	w.pid = pid
	w.stdout_fd = out_read
	w.stderr_fd = err_read
	w.out_buffer = new process_capture()
	w.err_buffer = new process_capture()
	process_capture_init(w.out_buffer)
	process_capture_init(w.err_buffer)
	w.out_printed = 0
	w.err_printed = 0
	w.done = 0
	workers.push(w)
	return 1


# Write through any buffered output the worker has not printed yet.
# Only the oldest unfinished worker streams live; the rest are flushed
# when they reach the head of the start-order queue.
void wexec_worker_flush(wexec_worker* w):
	if (w.out_buffer.length > w.out_printed):
		write(1, w.out_buffer.data + w.out_printed, w.out_buffer.length - w.out_printed)
		w.out_printed = w.out_buffer.length
	if (w.err_buffer.length > w.err_printed):
		write(2, w.err_buffer.data + w.err_printed, w.err_buffer.length - w.err_printed)
		w.err_printed = w.err_buffer.length


# One read per poll wakeup; returns 1 when the pipe reached EOF.
int wexec_worker_drain(int fd, process_capture* buffer):
	return process_capture_read(buffer, fd) <= 0


# Drive every requested target (and its dependency closure) to
# completion with up to wexec_jobs targets in flight. Returns 0 when
# everything succeeded.
int wexec_execute(list[char*] requested):
	for char* name in requested:
		if (wexec_collect_closure(name)):
			return 1

	int total = wexec_closure.length
	list[wexec_worker*] workers = new list[wexec_worker*]
	int head = 0       # first worker whose output is not fully printed
	int running = 0
	int finished = 0
	int failed = 0
	char* poll_fds = malloc(2 * wexec_jobs * 8 + 16)

	while (finished < total):
		# Launch phase: start every ready target, oldest first. Inline
		# completions (cache hits, aggregates) can ready more targets,
		# so repeat until a full scan launches nothing.
		int launched_any = 1
		while ((failed == 0) && launched_any):
			launched_any = 0
			int t = 0
			while ((t < total) && (running < wexec_jobs)):
				char* name = wexec_closure[t]
				if ((hash_map_get_default(wexec_started, name, 0) == 0) && wexec_deps_finished(name)):
					hash_map_set(wexec_started, name, 1)
					int outcome = wexec_launch(name, workers)
					if (outcome < 0):
						failed = 1
					else if (outcome == 0):
						finished = finished + 1
						launched_any = 1
					else:
						running = running + 1
				t = t + 1

		if (running == 0):
			# Nothing in flight: done, or blocked behind a failure.
			if (finished < total):
				failed = 1
			if (failed):
				# Print whatever buffered output is left, in order.
				while (head < workers.length):
					wexec_worker_flush(workers[head])
					head = head + 1
				free(poll_fds)
				return 1
			free(poll_fds)
			return 0

		# Collect the open pipe fds of every unfinished worker.
		int nfds = 0
		int i = head
		while (i < workers.length):
			wexec_worker* w = workers[i]
			if (w.done == 0):
				if (w.stdout_fd >= 0):
					process_pollfd_set(poll_fds, nfds, w.stdout_fd, 1)
					nfds = nfds + 1
				if (w.stderr_fd >= 0):
					process_pollfd_set(poll_fds, nfds, w.stderr_fd, 1)
					nfds = nfds + 1
			i = i + 1
		if (nfds > 0):
			# Bounded wait so reaps of pipe-less workers still happen.
			poll(cast(int*, poll_fds), nfds, 100)
		else:
			process_sleep_ms(2)

		# Drain readable pipes (walking the same fd order the poll set
		# was built in) and reap workers whose pipes have both closed.
		int slot = 0
		i = head
		while (i < workers.length):
			wexec_worker* w = workers[i]
			if (w.done == 0):
				if (w.stdout_fd >= 0):
					if (process_pollfd_revents(poll_fds, slot) != 0):
						if (wexec_worker_drain(w.stdout_fd, w.out_buffer)):
							close(w.stdout_fd)
							w.stdout_fd = -1
					slot = slot + 1
				if (w.stderr_fd >= 0):
					if (process_pollfd_revents(poll_fds, slot) != 0):
						if (wexec_worker_drain(w.stderr_fd, w.err_buffer)):
							close(w.stderr_fd)
							w.stderr_fd = -1
					slot = slot + 1
				if ((w.stdout_fd < 0) && (w.stderr_fd < 0)):
					int status = 0
					int reaped = wait4(w.pid, &status, 0, 0)
					w.done = 1
					running = running - 1
					finished = finished + 1
					int decoded = process_decode_status(status)
					if (reaped < 0):
						decoded = 1
					if (decoded != 0):
						failed = 1
					else:
						wexec_mark_finished(w.name, w.key)
			i = i + 1

		# Print phase: stream the head worker live and retire every
		# finished worker at the front of the start-order queue.
		while ((head < workers.length) && workers[head].done):
			wexec_worker_flush(workers[head])
			head = head + 1
		if (head < workers.length):
			wexec_worker_flush(workers[head])

	free(poll_fds)
	if (failed):
		return 1
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
	wexec_keys = hash_map_new()
	wexec_started = hash_map_new()
	wexec_finished = hash_map_new()
	wexec_names = new list[char*]
	wexec_closure = new list[char*]
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


# Default parallelism: one target per online CPU.
int wexec_default_jobs():
	char* text = file_read_text(c"/proc/cpuinfo")
	if (text == 0):
		return 1
	int count = 0
	int line_start = 1
	int i = 0
	while (text[i] != 0):
		if (line_start):
			if (starts_with(text + i, c"processor")):
				count = count + 1
		line_start = text[i] == 10
		i = i + 1
	free(text)
	if (count < 1):
		return 1
	return count


int main(int argc, int argv):
	wexec_mask32 = wexec_mask32_value()
	wexec_jobs = 0
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
		else if (strcmp(*arg, c"--no-cache") == 0):
			wexec_no_cache = 1
		else if (strcmp(*arg, c"-j") == 0):
			i = i + 1
			if (i >= argc):
				wexec_usage()
				return 1
			char** jobs_value = argv + i * __word_size__
			wexec_jobs = atoi(*jobs_value)
		else if (starts_with(*arg, c"-j")):
			char* digits = *arg
			wexec_jobs = atoi(digits + 2)
		else:
			requested.push(*arg)
		i = i + 1
	if (wexec_jobs < 1):
		wexec_jobs = wexec_default_jobs()

	if (wexec_load_manifest(manifest_path)):
		return 1
	if (list_only):
		wexec_list_targets()
		return 0
	if (requested.length == 0):
		wexec_usage()
		wexec_list_targets()
		return 1
	if (wexec_execute(requested)):
		return 1
	wexec_report_ok()
	return 0
