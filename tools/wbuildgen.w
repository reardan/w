/*
wbuildgen: generates build.json from build.base.json plus the source tree.

build.base.json is the hand-maintained manifest: toolchain targets,
fixture targets, anything with expectations, stdin, timeouts, or an
unconventional shape. Conventional test targets are not written by hand;
wbuildgen derives them from the tree and appends them, so adding a plain
test is just creating the source file and rerunning `./wbuild manifest`.

Generation rules:

- Every `*_test.w` file under tests/, lib/, structures/, graphics/,
  libs/ and tools/ (walked recursively, like wexec's input hashing) is a
  candidate. A source dir/X_test.w yields the target

      {"name": "X_test", "deps": ["wv2"],
       "steps": [{"cmd": ["bin/wv2", "dir/X_test.w", "-o", "bin/X_test"]},
                 {"cmd": ["bin/X_test"]}]}

- A `# wbuild: x64` directive line in the source also yields the
  X_64_test twin, compiling the same file with the `x64` argument.
- Base wins by name: when build.base.json already defines X_test (or
  X_64_test), that definition is kept and nothing is generated for the
  name. This is how a test with extra hand-written steps keeps its
  32-bit target in base while still generating its conventional twin.
- Sources listed in build.base.json's "generate": {"exclude": [...]}
  are skipped entirely; that list holds sources whose targets live in
  base under unconventional names (crypto_base64_test for
  base64_test.w, the pac/darwin fixtures, the parser-generator outputs
  that cannot carry directives because they are regenerated and
  diffed). The "generate" key is not copied into build.json.
- Umbrellas: generated 32-bit targets are appended to the "tests"
  target's deps and generated x64 twins to "tests_x64", sorted by name,
  except names already pinned by an explicit mention in a step-less
  base target's deps (that is how sha2/hmac/hkdf/x25519's twins stay
  members of "tests" instead).
- Output is deterministic: base targets keep their order and field
  order, generated targets are appended sorted by name, and the same
  tree always serializes to byte-identical build.json.

Usage: wbuildgen [--check] [--base build.base.json] [--out build.json]

--check regenerates to bin/build.json.gen, byte-compares it with the
committed build.json, and exits 1 with a per-target drift summary when
they differ (the CI gate: `./wbuild manifest_check`). Without --check
the manifest is rewritten in place (`./wbuild manifest`).

Design notes: docs/projects/wexec.md (manifest generation section).
*/
import lib.lib
import lib.file
import lib.stream
import structures.string
import structures.json


json_value* wbg_base                     # parsed build.base.json
map[char*, json_value*] wbg_base_targets # name -> target object
list[char*] wbg_base_names               # base manifest order
map[char*, int] wbg_exclude              # source path -> 1
map[char*, int] wbg_pinned               # names listed in step-less base deps
list[json_value*] wbg_generated          # generated targets, sorted by name
map[char*, int] wbg_gen_seen             # generated names, for collisions
list[char*] wbg_gen32_names
list[char*] wbg_gen64_names


void wbg_error(char* message):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wbuildgen: error: ")
	stream_write_line(err, message)
	stream_flush(err)


void wbg_error2(char* message, char* detail):
	string_builder* s = string_new()
	string_append(s, message)
	string_append(s, detail)
	wbg_error(s.data)
	string_free(s)


void wbg_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wbuildgen [--check] [--base build.base.json] [--out build.json]")
	stream_flush(err)


char* wbg_get_string(json_value* object, char* key):
	json_value* value = json_object_get(object, key)
	if (value == 0):
		return 0
	if (value.type != json_type_string()):
		return 0
	return value.string_value


int wbg_load_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


# Recursively collect every regular file under path, the same getdents
# walk wexec uses for directory inputs (d_reclen 2 bytes after the two
# word-sized ino/off fields, d_type in the record's last byte).
void wbg_collect_dir(char* path, list[char*] files):
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
			int reclen = wbg_load_uint16(entry + 2 * __word_size__)
			char* entry_name = entry + 2 * __word_size__ + 2
			int kind = entry[reclen - 1] & 255
			if ((strcmp(entry_name, c".") != 0) && (strcmp(entry_name, c"..") != 0)):
				string_builder* child = string_new()
				string_append(child, path)
				string_append(child, c"/")
				string_append(child, entry_name)
				if (kind == 4):
					wbg_collect_dir(child.data, files)
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
# output must not.
void wbg_sort_strings(list[char*] names):
	int i = 1
	while (i < names.length):
		char* value = names[i]
		int j = i - 1
		while ((j >= 0) && (strcmp(names[j], value) > 0)):
			names[j + 1] = names[j]
			j = j - 1
		names[j + 1] = value
		i = i + 1


char* wbg_basename(char* path):
	int i = 0
	int last = 0
	while (path[i] != 0):
		if (path[i] == '/'):
			last = i + 1
		i = i + 1
	return path + last


# The first (length - n) characters of text, as a fresh string.
char* wbg_strip_suffix(char* text, int n):
	int keep = strlen(text) - n
	string_builder* s = string_new()
	int i = 0
	while (i < keep):
		string_append_char(s, text[i])
		i = i + 1
	char* out = s.data
	free(s)
	return out


char* wbg_concat(char* left, char* right):
	string_builder* s = string_new()
	string_append(s, left)
	string_append(s, right)
	char* out = s.data
	free(s)
	return out


/* Directive parsing.

A directive is a source line starting with "# wbuild:" followed by
whitespace-separated tokens. The only token today is "x64" (also
generate the X_64_test twin). Unknown tokens are an error so typos
fail the manifest run instead of silently generating nothing. */

# Returns 1 when the source declares x64, 0 when not, -1 on error.
int wbg_parse_directives(char* path):
	char* text = file_read_text(path)
	if (text == 0):
		wbg_error2(c"cannot read source ", path)
		return -1
	int x64 = 0
	int failed = 0
	int at_line_start = 1
	int i = 0
	while (text[i] != 0):
		if (at_line_start && starts_with(text + i, c"# wbuild:")):
			int j = i + 9
			while ((text[j] != 0) && (text[j] != '\n')):
				if ((text[j] == ' ') | (text[j] == '\t')):
					j = j + 1
				else:
					string_builder* token = string_new()
					while ((text[j] != 0) && (text[j] != '\n') && (text[j] != ' ') && (text[j] != '\t')):
						string_append_char(token, text[j])
						j = j + 1
					if (strcmp(token.data, c"x64") == 0):
						x64 = 1
					else:
						string_builder* s = string_new()
						string_append(s, c"unknown '# wbuild:' directive '")
						string_append(s, token.data)
						string_append(s, c"' in ")
						string_append(s, path)
						wbg_error(s.data)
						string_free(s)
						failed = 1
					string_free(token)
		at_line_start = text[i] == '\n'
		i = i + 1
	free(text)
	if (failed):
		return -1
	return x64


int wbg_load_base(char* path):
	char* text = file_read_text(path)
	if (text == 0):
		wbg_error2(c"cannot read base manifest ", path)
		return 1
	wbg_base = json_parse(text)
	free(text)
	if (wbg_base == 0):
		wbg_error2(c"base manifest is not valid JSON: ", path)
		return 1
	if (wbg_base.type != json_type_object()):
		wbg_error2(c"base manifest root must be a JSON object: ", path)
		return 1
	json_value* targets = json_object_get(wbg_base, c"targets")
	if (targets == 0):
		wbg_error2(c"base manifest has no \"targets\" array: ", path)
		return 1
	if (targets.type != json_type_array()):
		wbg_error2(c"\"targets\" must be an array: ", path)
		return 1

	wbg_base_targets = new map[char*, json_value*]
	wbg_base_names = new list[char*]
	wbg_pinned = new map[char*, int]
	int i = 0
	while (i < json_array_length(targets)):
		json_value* target = json_array_get(targets, i)
		if (target.type != json_type_object()):
			wbg_error2(c"every target must be a JSON object: ", path)
			return 1
		char* name = wbg_get_string(target, c"name")
		if (name == 0):
			wbg_error2(c"target without a \"name\" string: ", path)
			return 1
		if (name in wbg_base_targets):
			wbg_error2(c"duplicate base target ", name)
			return 1
		wbg_base_targets[name] = target
		wbg_base_names.push(name)
		# Deps of step-less (umbrella) targets pin their members: a
		# generated name listed there keeps that hand-chosen placement
		# instead of being auto-appended to its conventional umbrella.
		if (json_object_has(target, c"steps") == 0):
			json_value* deps = json_object_get(target, c"deps")
			if (deps != 0):
				if (deps.type == json_type_array()):
					int d = 0
					while (d < json_array_length(deps)):
						json_value* dep = json_array_get(deps, d)
						if (dep.type == json_type_string()):
							wbg_pinned[dep.string_value] = 1
						d = d + 1
		i = i + 1

	wbg_exclude = new map[char*, int]
	json_value* generate = json_object_get(wbg_base, c"generate")
	if (generate != 0):
		if (generate.type != json_type_object()):
			wbg_error(c"\"generate\" must be an object")
			return 1
		json_value* exclude = json_object_get(generate, c"exclude")
		if (exclude != 0):
			if (exclude.type != json_type_array()):
				wbg_error(c"\"generate\".\"exclude\" must be an array")
				return 1
			int e = 0
			while (e < json_array_length(exclude)):
				json_value* entry = json_array_get(exclude, e)
				if (entry.type != json_type_string()):
					wbg_error(c"\"generate\".\"exclude\" entries must be strings")
					return 1
				# A stale entry usually means a test was deleted without
				# updating the base manifest; fail loudly.
				int fd = open(entry.string_value, 0, 0)
				if (fd < 0):
					wbg_error2(c"generate.exclude entry does not exist: ", entry.string_value)
					return 1
				close(fd)
				wbg_exclude[entry.string_value] = 1
				e = e + 1
	return 0


json_value* wbg_make_target(char* name, char* src, int is64):
	char* binary = wbg_concat(c"bin/", name)
	json_value* target = json_object()
	json_object_set(target, c"name", json_string(name))
	json_value* deps = json_array()
	json_array_push(deps, json_string(c"wv2"))
	json_object_set(target, c"deps", deps)
	json_value* compile_cmd = json_array()
	json_array_push(compile_cmd, json_string(c"bin/wv2"))
	if (is64):
		json_array_push(compile_cmd, json_string(c"x64"))
	json_array_push(compile_cmd, json_string(src))
	json_array_push(compile_cmd, json_string(c"-o"))
	json_array_push(compile_cmd, json_string(binary))
	json_value* compile_step = json_object()
	json_object_set(compile_step, c"cmd", compile_cmd)
	json_value* run_cmd = json_array()
	json_array_push(run_cmd, json_string(binary))
	json_value* run_step = json_object()
	json_object_set(run_step, c"cmd", run_cmd)
	json_value* steps = json_array()
	json_array_push(steps, compile_step)
	json_array_push(steps, run_step)
	json_object_set(target, c"steps", steps)
	free(binary)
	return target


int wbg_add_generated(char* name, char* src, int is64):
	if (name in wbg_gen_seen):
		string_builder* s = string_new()
		string_append(s, c"generated target '")
		string_append(s, name)
		string_append(s, c"' collides (from ")
		string_append(s, src)
		string_append(s, c")")
		wbg_error(s.data)
		string_free(s)
		return 1
	wbg_gen_seen[name] = 1
	wbg_generated.push(wbg_make_target(name, src, is64))
	if (is64):
		wbg_gen64_names.push(name)
	else:
		wbg_gen32_names.push(name)
	return 0


void wbg_sort_generated():
	int i = 1
	while (i < wbg_generated.length):
		json_value* value = wbg_generated[i]
		char* name = wbg_get_string(value, c"name")
		int j = i - 1
		while ((j >= 0) && (strcmp(wbg_get_string(wbg_generated[j], c"name"), name) > 0)):
			wbg_generated[j + 1] = wbg_generated[j]
			j = j - 1
		wbg_generated[j + 1] = value
		i = i + 1


int wbg_scan():
	wbg_generated = new list[json_value*]
	wbg_gen_seen = new map[char*, int]
	wbg_gen32_names = new list[char*]
	wbg_gen64_names = new list[char*]

	list[char*] files = new list[char*]
	wbg_collect_dir(c"tests", files)
	wbg_collect_dir(c"lib", files)
	wbg_collect_dir(c"structures", files)
	wbg_collect_dir(c"graphics", files)
	wbg_collect_dir(c"libs", files)
	wbg_collect_dir(c"tools", files)
	wbg_sort_strings(files)

	for char* src in files:
		if (ends_with(src, c"_test.w") == 0):
			continue
		if (src in wbg_exclude):
			continue
		int x64 = wbg_parse_directives(src)
		if (x64 < 0):
			return 1
		char* name32 = wbg_strip_suffix(wbg_basename(src), 2)
		if ((name32 in wbg_base_targets) == 0):
			if (wbg_add_generated(name32, strclone(src), 0)):
				return 1
		if (x64):
			char* stem = wbg_strip_suffix(name32, 5)
			char* name64 = wbg_concat(stem, c"_64_test")
			free(stem)
			if ((name64 in wbg_base_targets) == 0):
				if (wbg_add_generated(name64, strclone(src), 1)):
					return 1
	wbg_sort_generated()
	wbg_sort_strings(wbg_gen32_names)
	wbg_sort_strings(wbg_gen64_names)
	return 0


# Append the generated members of one umbrella (already sorted), minus
# the pinned names, to the umbrella target's deps.
int wbg_extend_umbrella(char* umbrella, list[char*] names):
	list[char*] wanted = new list[char*]
	for char* name in names:
		if ((name in wbg_pinned) == 0):
			wanted.push(name)
	if (wanted.length == 0):
		return 0
	json_value* target = wbg_base_targets.get(umbrella, 0)
	if (target == 0):
		wbg_error2(c"missing umbrella target ", umbrella)
		return 1
	json_value* deps = json_object_get(target, c"deps")
	if (deps == 0):
		wbg_error2(c"umbrella target has no \"deps\": ", umbrella)
		return 1
	if (deps.type != json_type_array()):
		wbg_error2(c"umbrella \"deps\" is not an array: ", umbrella)
		return 1
	for char* name in wanted:
		json_array_push(deps, json_string(name))
	return 0


/* Serialization.

The manifest layout is fixed so regeneration is reproducible:
- scalar and array fields print compact on one line with ", " and ": "
  separators;
- each step prints on its own line;
- the deps of step-less (umbrella) targets print one per line;
- base targets keep their parse order, field order included. */

void wbg_append_compact(string_builder* out, json_value* value):
	if (value.type == json_type_string()):
		json_append_escaped_string(out, value.string_value)
	else if (value.type == json_type_int()):
		string_append_int(out, value.int_value)
	else if (value.type == json_type_bool()):
		if (value.int_value):
			string_append(out, c"true")
		else:
			string_append(out, c"false")
	else if (value.type == json_type_array()):
		string_append_char(out, '[')
		int i = 0
		while (i < json_array_length(value)):
			if (i > 0):
				string_append(out, c", ")
			wbg_append_compact(out, json_array_get(value, i))
			i = i + 1
		string_append_char(out, ']')
	else if (value.type == json_type_object()):
		string_append_char(out, '{')
		int first = 1
		for char* key, json_value* member in value.object_values:
			if (first == 0):
				string_append(out, c", ")
			first = 0
			json_append_escaped_string(out, key)
			string_append(out, c": ")
			wbg_append_compact(out, member)
		string_append_char(out, '}')
	else:
		string_append(out, c"null")


# One array element per line, indented with four tabs.
void wbg_append_element_lines(string_builder* out, json_value* array):
	int i = 0
	while (i < json_array_length(array)):
		string_append(out, c"\t\t\t\t")
		wbg_append_compact(out, json_array_get(array, i))
		if (i + 1 < json_array_length(array)):
			string_append_char(out, ',')
		string_append_char(out, '\n')
		i = i + 1


void wbg_append_target(string_builder* out, json_value* target):
	string_append(out, c"\t\t{\n")
	int has_steps = json_object_has(target, c"steps")
	int first = 1
	for char* key, json_value* member in target.object_values:
		if (first == 0):
			string_append(out, c",\n")
		first = 0
		int multiline = 0
		if (member.type == json_type_array()):
			if (strcmp(key, c"steps") == 0):
				multiline = 1
			if ((strcmp(key, c"deps") == 0) && (has_steps == 0)):
				multiline = 1
		if (multiline):
			string_append(out, c"\t\t\t")
			json_append_escaped_string(out, key)
			string_append(out, c": [\n")
			wbg_append_element_lines(out, member)
			string_append(out, c"\t\t\t]")
		else:
			string_append(out, c"\t\t\t")
			json_append_escaped_string(out, key)
			string_append(out, c": ")
			wbg_append_compact(out, member)
	string_append(out, c"\n\t\t}")


# The whole manifest: root members in base order minus "generate",
# targets expanded one object at a time.
char* wbg_render():
	string_builder* out = string_new()
	string_append(out, c"{\n")
	int first = 1
	for char* key, json_value* member in wbg_base.object_values:
		if (strcmp(key, c"generate") == 0):
			continue
		if (first == 0):
			string_append(out, c",\n")
		first = 0
		if (strcmp(key, c"targets") == 0):
			string_append(out, c"\t\"targets\": [\n")
			int i = 0
			while (i < json_array_length(member)):
				if (i > 0):
					string_append(out, c",\n")
				wbg_append_target(out, json_array_get(member, i))
				i = i + 1
			string_append(out, c"\n\t]")
		else:
			string_append(out, c"\t")
			json_append_escaped_string(out, key)
			string_append(out, c": ")
			wbg_append_compact(out, member)
	string_append(out, c"\n}\n")
	char* text = out.data
	free(out)
	return text


/* --check drift summary: name-level triage between the committed
manifest and the regenerated one, so the failure says which target to
look at instead of just "bytes differ". */

void wbg_report_drift(char* out_path, char* current, char* rendered):
	json_value* committed = json_parse(current)
	json_value* fresh = json_parse(rendered)
	int reported = 0
	if ((committed != 0) && (fresh != 0)):
		json_value* old_targets = json_object_get(committed, c"targets")
		json_value* new_targets = json_object_get(fresh, c"targets")
		map[char*, char*] old_defs = new map[char*, char*]
		int i = 0
		while (i < json_array_length(old_targets)):
			json_value* target = json_array_get(old_targets, i)
			char* name = wbg_get_string(target, c"name")
			if (name != 0):
				old_defs[name] = json_stringify(target)
			i = i + 1
		map[char*, int] new_names = new map[char*, int]
		i = 0
		while (i < json_array_length(new_targets)):
			json_value* target = json_array_get(new_targets, i)
			char* name = wbg_get_string(target, c"name")
			if (name != 0):
				new_names[name] = 1
				char* old_def = old_defs.get(name, 0)
				if (old_def == 0):
					wbg_error2(c"target missing from committed manifest: ", name)
					reported = 1
				else:
					char* new_def = json_stringify(target)
					if (strcmp(old_def, new_def) != 0):
						wbg_error2(c"target definition drifted: ", name)
						reported = 1
					free(new_def)
			i = i + 1
		for char* name, char* def in old_defs:
			if ((name in new_names) == 0):
				wbg_error2(c"committed target no longer generated: ", name)
				reported = 1
	if (reported == 0):
		wbg_error(c"manifests differ in formatting only")
	wbg_error2(c"stale manifest; regenerate with ./wbuild manifest: ", out_path)


int main(int argc, int argv):
	char* base_path = c"build.base.json"
	char* out_path = c"build.json"
	int check_only = 0
	int i = 1
	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--check") == 0):
			check_only = 1
		else if (strcmp(*arg, c"--base") == 0):
			i = i + 1
			if (i >= argc):
				wbg_usage()
				return 1
			char** base_value = argv + i * __word_size__
			base_path = *base_value
		else if (strcmp(*arg, c"--out") == 0):
			i = i + 1
			if (i >= argc):
				wbg_usage()
				return 1
			char** out_value = argv + i * __word_size__
			out_path = *out_value
		else:
			wbg_usage()
			return 1
		i = i + 1

	if (wbg_load_base(base_path)):
		return 1
	if (wbg_scan()):
		return 1
	if (wbg_extend_umbrella(c"tests", wbg_gen32_names)):
		return 1
	if (wbg_extend_umbrella(c"tests_x64", wbg_gen64_names)):
		return 1

	json_value* targets = json_object_get(wbg_base, c"targets")
	for json_value* target in wbg_generated:
		json_array_push(targets, target)
	char* rendered = wbg_render()

	string_builder* summary = string_new()
	string_append_int(summary, json_array_length(targets))
	string_append(summary, c" targets, ")
	string_append_int(summary, wbg_generated.length)
	string_append(summary, c" generated)")

	wstream* out = stdout_writer()
	if (check_only):
		char* current = file_read_text(out_path)
		if (current != 0):
			if (strcmp(current, rendered) == 0):
				stream_write_cstr(out, c"wbuildgen: OK ")
				stream_write_cstr(out, out_path)
				stream_write_cstr(out, c" is up to date (")
				stream_write_line(out, summary.data)
				stream_flush(out)
				return 0
		# Failure (usually EEXIST) is fine, like wexec_make_dirs.
		mkdir(c"bin", 493)
		file_write_text(c"bin/build.json.gen", rendered)
		wbg_error(c"regenerated manifest written to bin/build.json.gen")
		if (current == 0):
			wbg_error2(c"cannot read committed manifest ", out_path)
		else:
			wbg_report_drift(out_path, current, rendered)
		return 1

	if (file_write_text(out_path, rendered) == 0):
		wbg_error2(c"cannot write ", out_path)
		return 1
	stream_write_cstr(out, c"wbuildgen: wrote ")
	stream_write_cstr(out, out_path)
	stream_write_cstr(out, c" (")
	stream_write_line(out, summary.data)
	stream_flush(out)
	return 0
