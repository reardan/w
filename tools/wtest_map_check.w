/*
wtest_map_check: property checker for bin/wtest's changed-path selection.

Replaces the frozen exact-set selection lists that used to live inline in
build.base.json's wtest_map_test target — the repo's worst merge-conflict
surface: every new test whose import closure reached a listed library
(lib/stream.w, lib/file.w, ...) changed those order-sensitive lists, and
parallel PRs collided on them constantly (consolidated plan §1). Instead
of freezing bin/wtest's full output, each case in the expectations file
asserts PROPERTIES of the selection:

  case <path> [<path>...]   run 'bin/wtest changed <paths>'
  expect <target>           the selection must include <target>
  forbid <target>           the selection must not include <target>
  empty                     the selection must be empty

plus three implicit properties, checked for every case:

  - every selected name must be a target in build.json (bin/wtest can
    never emit a stale or misspelled name),
  - the selection must come out in manifest order with no duplicates —
    bin/wtest's output-order contract (wtest_emit_targets iterates the
    manifest), asserted here so it stays load-bearing, documented
    behavior instead of an accident the old frozen lists encoded, and
  - an empty selection must announce itself with 'wtest: 0 targets
    selected' on stderr (stdout stays clean for xargs), and a
    non-empty one must not — so every 'empty' case also pins the
    visibility of a zero-target run.

Case words are handed to 'bin/wtest changed' verbatim, so a case may
lead with '-f <manifest>' / '--base-manifest <manifest>' fixture flags
before its changed paths (the build.json leaf-diff cases do); the
implicit properties are still checked against the real build.json, so
fixture manifests must reuse real target names in build.json order.

Every expect/forbid name must itself exist in build.json, so a renamed
or deleted target makes the expectations file fail loudly ("unknown
target") instead of an assertion silently passing forever.

Design rule (issue #251 Direction 1 / consolidated plan §2 A1): adding a
conventional test target must never require editing the expectations
file. Assert only targets tied to the selection mechanism itself — the
residue rules in tools/test_map.w, literal step references, closure
representatives — plus structurally invariant forbids. To inspect the
real selection for a case:

  ./wbuild wtest && bin/wtest changed <path...>

Usage: wtest_map_check <expectations-file>     (run from the repo root)
Prints 'wtest_map_check: OK (<n> cases)' and exits 0 when every case
passes; prints one 'wtest_map_check: FAIL [...]' block per violated
assertion (with the full actual selection) and exits 1 otherwise.
*/
import lib.lib
import lib.file
import lib.process
import lib.stream
import structures.string
import structures.json


struct check_case:
	char* label          # paths joined with spaces, for messages
	int line             # 'case' line number in the expectations file
	int want_empty
	list[char*] paths
	list[char*] expects
	list[char*] forbids


list[check_case*] check_cases
check_case* check_current
list[char*] check_target_names       # build.json targets, manifest order
map[char*, int] check_target_index   # name -> manifest position + 1
int check_failures
int check_parse_failed
char* check_expectations_path


void check_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wtest_map_check expectations-file")
	stream_flush(err)


void check_error(char* message, char* detail):
	check_parse_failed = 1
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wtest_map_check: error: ")
	stream_write_cstr(err, message)
	stream_write_line(err, detail)
	stream_flush(err)


void check_parse_error(int line, char* message, char* detail):
	check_parse_failed = 1
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wtest_map_check: error: ")
	stream_write_cstr(err, check_expectations_path)
	stream_write_cstr(err, c":")
	stream_write_cstr(err, itoa(line))
	stream_write_cstr(err, c": ")
	stream_write_cstr(err, message)
	stream_write_line(err, detail)
	stream_flush(err)


# One FAIL block per violated assertion; when the selection is relevant
# it is printed in full, so a CI log alone is enough to diagnose.
void check_case_fail(check_case* c, char* message, char* detail, list[char*] selected):
	check_failures = check_failures + 1
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wtest_map_check: FAIL [")
	stream_write_cstr(err, c.label)
	stream_write_cstr(err, c"] (")
	stream_write_cstr(err, check_expectations_path)
	stream_write_cstr(err, c":")
	stream_write_cstr(err, itoa(c.line))
	stream_write_cstr(err, c"): ")
	stream_write_cstr(err, message)
	stream_write_line(err, detail)
	if (selected != 0):
		stream_write_line(err, c"  selection was:")
		if (selected.length == 0):
			stream_write_line(err, c"    (empty)")
		for char* name in selected:
			stream_write_cstr(err, c"    ")
			stream_write_line(err, name)
	stream_flush(err)


/* Manifest: target names in order, for the implicit properties. */

int check_load_manifest():
	char* text = file_read_text(c"build.json")
	if (text == 0):
		check_error(c"cannot read ", c"build.json")
		return 1
	json_value* manifest = json_parse(text)
	free(text)
	if (manifest == 0):
		check_error(c"manifest is not valid JSON: ", c"build.json")
		return 1
	json_value* targets = json_object_get(manifest, c"targets")
	if (targets == 0):
		check_error(c"manifest has no targets array: ", c"build.json")
		return 1
	if (targets.type != json_type_array()):
		check_error(c"manifest targets is not an array: ", c"build.json")
		return 1
	check_target_names = new list[char*]
	check_target_index = new map[char*, int]
	int i = 0
	while (i < json_array_length(targets)):
		json_value* target = json_array_get(targets, i)
		if (target.type == json_type_object()):
			json_value* name = json_object_get(target, c"name")
			if (name != 0):
				if (name.type == json_type_string()):
					check_target_names.push(name.string_value)
					check_target_index[name.string_value] = check_target_names.length
		i = i + 1
	return 0


/* Expectations file parsing. */

list[char*] check_split_words(char* text):
	list[char*] out = new list[char*]
	string_builder* word = string_new()
	int i = 0
	int at_end = 0
	while (at_end == 0):
		int ch = text[i]
		if ((ch == ' ') || (ch == 9) || (ch == 0)):
			if (word.length > 0):
				out.push(strclone(word.data))
				string_clear(word)
			if (ch == 0):
				at_end = 1
		else:
			string_append_char(word, ch)
		i = i + 1
	string_free(word)
	return out


void check_parse_line(char* content, int line_number):
	list[char*] words = check_split_words(content)
	if (words.length == 0):
		return
	char* head = words[0]
	if (head[0] == '#'):
		return
	if (strcmp(head, c"case") == 0):
		if (words.length < 2):
			check_parse_error(line_number, c"'case' needs at least one path", c"")
			return
		check_case* c = new check_case()
		c.line = line_number
		c.want_empty = 0
		c.paths = new list[char*]
		c.expects = new list[char*]
		c.forbids = new list[char*]
		string_builder* label = string_new()
		int i = 1
		while (i < words.length):
			c.paths.push(words[i])
			if (i > 1):
				string_append_char(label, ' ')
			string_append(label, words[i])
			i = i + 1
		c.label = label.data
		free(label)
		check_cases.push(c)
		check_current = c
		return
	if (check_current == 0):
		check_parse_error(line_number, c"directive before first 'case': ", head)
		return
	if (strcmp(head, c"expect") == 0):
		if (words.length != 2):
			check_parse_error(line_number, c"'expect' needs exactly one target", c"")
			return
		check_current.expects.push(words[1])
		return
	if (strcmp(head, c"forbid") == 0):
		if (words.length != 2):
			check_parse_error(line_number, c"'forbid' needs exactly one target", c"")
			return
		check_current.forbids.push(words[1])
		return
	if (strcmp(head, c"empty") == 0):
		if (words.length != 1):
			check_parse_error(line_number, c"'empty' takes no arguments", c"")
			return
		check_current.want_empty = 1
		return
	check_parse_error(line_number, c"unknown directive: ", head)


void check_known_target(int line, char* name):
	if (check_target_index.get(name, 0) == 0):
		check_parse_error(line, c"unknown target (renamed or removed from build.json?): ", name)


# A case must assert something; 'empty' is exclusive; every asserted
# name must exist in the manifest so renames fail loudly.
void check_validate():
	if (check_cases.length == 0):
		check_error(c"no cases in ", check_expectations_path)
	for check_case* c in check_cases:
		if (c.want_empty):
			if ((c.expects.length > 0) || (c.forbids.length > 0)):
				check_parse_error(c.line, c"'empty' cannot be combined with expect/forbid", c"")
		else if ((c.expects.length == 0) && (c.forbids.length == 0)):
			check_parse_error(c.line, c"case has no assertions", c"")
		for char* name in c.expects:
			check_known_target(c.line, name)
		for char* forbidden in c.forbids:
			check_known_target(c.line, forbidden)


int check_parse_expectations():
	char* text = file_read_text(check_expectations_path)
	if (text == 0):
		check_error(c"cannot read ", check_expectations_path)
		return 1
	check_cases = new list[check_case*]
	check_current = 0
	string_builder* line = string_new()
	int line_number = 0
	int i = 0
	int at_end = 0
	while (at_end == 0):
		int ch = text[i]
		if (ch == 0):
			at_end = 1
		if ((ch == 10) || (ch == 0)):
			line_number = line_number + 1
			check_parse_line(line.data, line_number)
			string_clear(line)
		else:
			string_append_char(line, ch)
		i = i + 1
	string_free(line)
	free(text)
	check_validate()
	return check_parse_failed


/* Case execution. */

list[char*] check_split_lines(char* text):
	list[char*] out = new list[char*]
	string_builder* line = string_new()
	int i = 0
	int at_end = 0
	while (at_end == 0):
		int ch = text[i]
		if (ch == 0):
			at_end = 1
		if ((ch == 10) || (ch == 0)):
			if (line.length > 0):
				out.push(strclone(line.data))
				string_clear(line)
		else:
			string_append_char(line, ch)
		i = i + 1
	string_free(line)
	return out


int check_selected_contains(list[char*] selected, char* name):
	for char* candidate in selected:
		if (strcmp(candidate, name) == 0):
			return 1
	return 0


int check_str_contains(char* haystack, char* needle):
	int n = strlen(needle)
	if (n == 0):
		return 1
	int i = 0
	while (haystack[i] != 0):
		int j = 0
		while ((j < n) && (haystack[i + j] == needle[j])):
			j = j + 1
		if (j == n):
			return 1
		i = i + 1
	return 0


void check_run_case(check_case* c):
	char** argv = strv_new(2 + c.paths.length)
	strv_set(argv, 0, c"bin/wtest")
	strv_set(argv, 1, c"changed")
	int i = 0
	while (i < c.paths.length):
		strv_set(argv, 2 + i, c.paths[i])
		i = i + 1
	# Generous timeout: the first run after a build recomputes the
	# import-closure cache (bin/.wtest_deps_cache), which takes ~35s.
	process_result* result = process_run(c"bin/wtest", argv, 0, 0, 300000)
	free(cast(char*, argv))
	if (result == 0):
		check_case_fail(c, c"cannot run bin/wtest", c"", 0)
		return
	if (result.status != 0):
		check_case_fail(c, c"bin/wtest failed: ", result.stderr_text, 0)
		process_result_free(result)
		return
	list[char*] selected = check_split_lines(result.stdout_text)
	char* errors = strclone(result.stderr_text)
	process_result_free(result)

	# Implicit property: an empty selection announces itself on stderr
	# ('wtest: 0 targets selected', tools/test_map.w) and a non-empty
	# one stays quiet, so a zero-target run is never invisible.
	int announced = check_str_contains(errors, c"wtest: 0 targets selected")
	free(errors)
	if (selected.length == 0):
		if (announced == 0):
			check_case_fail(c, c"empty selection did not print 'wtest: 0 targets selected' on stderr", c"", selected)
	else if (announced):
		check_case_fail(c, c"non-empty selection printed 'wtest: 0 targets selected' on stderr", c"", selected)

	# Implicit properties: known names only, manifest order, no dupes.
	int previous = 0
	for char* name in selected:
		int index = check_target_index.get(name, 0)
		if (index == 0):
			check_case_fail(c, c"selected name is not a build.json target: ", name, selected)
		else:
			if (index <= previous):
				check_case_fail(c, c"selection out of manifest order (or duplicate): ", name, selected)
			previous = index

	# Explicit assertions.
	if (c.want_empty && (selected.length != 0)):
		check_case_fail(c, c"expected empty selection", c"", selected)
	for char* expected in c.expects:
		if (check_selected_contains(selected, expected) == 0):
			check_case_fail(c, c"missing expected target: ", expected, selected)
	for char* forbidden in c.forbids:
		if (check_selected_contains(selected, forbidden)):
			check_case_fail(c, c"selected forbidden target: ", forbidden, selected)


int main(int argc, int argv):
	if (argc != 2):
		check_usage()
		return 1
	char** arg = argv + __word_size__
	check_expectations_path = *arg
	if (check_load_manifest()):
		return 1
	if (check_parse_expectations()):
		return 1
	for check_case* c in check_cases:
		check_run_case(c)
	if (check_failures > 0):
		wstream* err = stderr_writer()
		stream_write_cstr(err, c"wtest_map_check: ")
		stream_write_cstr(err, itoa(check_failures))
		stream_write_line(err, c" failed assertion(s)")
		stream_flush(err)
		return 1
	wstream* out = stdout_writer()
	stream_write_cstr(out, c"wtest_map_check: OK (")
	stream_write_cstr(out, itoa(check_cases.length))
	stream_write_line(out, c" cases)")
	stream_flush(out)
	return 0
