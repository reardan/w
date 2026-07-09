# Semantic index over 'wv2 symbols --json': cross-file find-references,
# callers/callees, struct fields, and imports for a set of entry files.
# There is no usage-site tracking in the compiler (declarations only), so
# reference finding is a textual identifier scan over every file the
# entry files' compile reaches, cross-checked against the declaration set
# for kind/type. Caller/callee resolution approximates a function's body
# span from W's tab-indentation rule (the next column-0, non-blank line
# ends the block) rather than true scope analysis. See
# docs/projects/semantic_index.md for the exact contract and known gaps.
#
# Build and run:
#   make windex && ./bin/windex symbol sym_fixture_add tests/symbols_fixture.w
import lib.lib
import lib.args
import lib.path
import lib.file
import lib.process
import structures.string
import structures.json


int windex_timeout_ms():
	return 60000


# Declarations from the last windex_build(), in 'wv2 symbols --json' order.
list[json_value*] windex_decls

# Declarations grouped by name (a name can have several: a struct's type
# and object entries share a name; externs can repeat across archs).
map[char*, list[json_value*]] windex_by_name

# Unique files named by any declaration, in first-seen order.
list[char*] windex_files

# Per-file cache of column-0 boundary line numbers (windex_boundaries()).
map[char*, list[int]] windex_boundaries_cache


/* JSON helpers */


json_value* windex_member(json_value* value, char* key):
	if (value == 0):
		return 0
	if (value.type != json_type_object()):
		return 0
	return json_object_get(value, key)


char* windex_string_member(json_value* value, char* key):
	json_value* member = windex_member(value, key)
	if (member == 0):
		return 0
	if (member.type != json_type_string()):
		return 0
	return member.string_value


int windex_int_member(json_value* value, char* key, int missing):
	json_value* member = windex_member(value, key)
	if (member == 0):
		return missing
	if (member.type != json_type_int()):
		return missing
	return member.int_value


list[json_value*] windex_parse_ndjson(char* text):
	list[json_value*] records = new list[json_value*]
	string_builder* line = string_new()
	int i = 0
	while (1):
		int c = text[i]
		if ((c == '\n') | (c == 0)):
			if (line.length > 0):
				json_value* record = json_parse(line.data)
				if (record != 0):
					records.push(record)
			string_clear(line)
			if (c == 0):
				string_free(line)
				return records
		else if (c != '\r'):
			string_append_char(line, c)
		i = i + 1
	return records


void windex_emit(json_value* record):
	char* body = json_stringify(record)
	write(1, body, strlen(body))
	write(1, c"\x0a", 1)
	free(body)


/* building the index */


int windex_files_contains(char* file):
	for char* known in windex_files:
		if (strcmp(known, file) == 0):
			return 1
	return 0


process_result* windex_run_symbols(list[char*] files):
	int n = 3 + files.length
	char** argv = strv_new(n)
	strv_set(argv, 0, c"./bin/wv2")
	strv_set(argv, 1, c"symbols")
	strv_set(argv, 2, c"--json")
	int i = 0
	while (i < files.length):
		strv_set(argv, 3 + i, files[i])
		i = i + 1
	process_result* result = process_run(c"./bin/wv2", argv, 0, 0, windex_timeout_ms())
	free(cast(void*, argv))
	return result


# Compiles entry_files via 'wv2 symbols --json' and populates
# windex_decls/windex_by_name/windex_files. Returns 0 (nothing printed by
# callers) when the subprocess could not run or the compile failed.
int windex_build(list[char*] entry_files):
	windex_decls = new list[json_value*]
	windex_by_name = new map[char*, list[json_value*]]
	windex_files = new list[char*]
	windex_boundaries_cache = new map[char*, list[int]]
	process_result* result = windex_run_symbols(entry_files)
	if (result == 0):
		return 0
	if (result.status != 0):
		process_result_free(result)
		return 0
	list[json_value*] records = windex_parse_ndjson(result.stdout_text)
	process_result_free(result)
	for json_value* record in records:
		windex_decls.push(record)
		char* name = windex_string_member(record, c"name")
		if (name != 0):
			if (name in windex_by_name):
				windex_by_name[name].push(record)
			else:
				list[json_value*] bucket = new list[json_value*]
				bucket.push(record)
				windex_by_name[name] = bucket
		char* file = windex_string_member(record, c"file")
		if (file != 0):
			if (windex_files_contains(file) == 0):
				windex_files.push(file)
	return 1


/* textual identifier scanning */


int windex_is_word_char(int c):
	if ((c >= 'a') & (c <= 'z')):
		return 1
	if ((c >= 'A') & (c <= 'Z')):
		return 1
	if ((c >= '0') & (c <= '9')):
		return 1
	return c == '_'


# Every identifier-shaped word in text as {"name", "line", "column"}
# (1-based). Includes keywords and type names; callers filter against
# known declarations, so non-symbols are harmless noise.
list[json_value*] windex_scan_all_identifiers(char* text):
	list[json_value*] hits = new list[json_value*]
	int i = 0
	int line = 1
	int line_start = 0
	while (text[i] != 0):
		int c = text[i] & 255
		if (c == '\n'):
			line = line + 1
			line_start = i + 1
			i = i + 1
			continue
		if (windex_is_word_char(c) == 0):
			i = i + 1
			continue
		int start = i
		while (windex_is_word_char(text[i] & 255)):
			i = i + 1
		char* word = path_clone_range(text + start, i - start)
		json_value* hit = json_object()
		json_object_set(hit, c"name", json_string(word))
		json_object_set(hit, c"line", json_int(line))
		json_object_set(hit, c"column", json_int(start - line_start + 1))
		hits.push(hit)
	return hits


# Occurrences of exactly 'name' in text; frees the ones that don't match.
list[json_value*] windex_scan_identifiers(char* text, char* name):
	list[json_value*] all = windex_scan_all_identifiers(text)
	list[json_value*] hits = new list[json_value*]
	for json_value* hit in all:
		if (strcmp(windex_string_member(hit, c"name"), name) == 0):
			hits.push(hit)
		else:
			json_free(hit)
	return hits


/* function body spans, approximated from column-0 indentation */


# Line numbers (1-based) of every non-blank line whose first character is
# not tab/space: top-level declarations, and (rarely) a stray column-0
# comment, which would truncate a body's computed span early.
list[int] windex_boundaries(char* text):
	list[int] result = new list[int]
	int pos = 0
	int line = 1
	while (text[pos] != 0):
		int c = text[pos] & 255
		if ((c != '\t') & (c != ' ') & (c != '\n') & (c != '\r')):
			result.push(line)
		while ((text[pos] != 0) & (text[pos] != '\n')):
			pos = pos + 1
		if (text[pos] == '\n'):
			pos = pos + 1
		line = line + 1
	return result


list[int] windex_get_boundaries(char* file):
	if (file in windex_boundaries_cache):
		return windex_boundaries_cache[file]
	list[int] boundaries = new list[int]
	char* text = file_read_text(file)
	if (text != 0):
		boundaries = windex_boundaries(text)
		free(text)
	windex_boundaries_cache[file] = boundaries
	return boundaries


# Last line of the block starting at start_line: the line before the next
# boundary, or "end of file" (a large sentinel; callers only compare it
# against real line numbers from the same file).
int windex_span_end(list[int] boundaries, int start_line):
	for int b in boundaries:
		if (b > start_line):
			return b - 1
	return 2147483647


int windex_is_declaration(char* name, char* file, int line, int column):
	if (name in windex_by_name):
		for json_value* decl in windex_by_name[name]:
			char* decl_file = windex_string_member(decl, c"file")
			if (decl_file == 0):
				continue
			if (strcmp(decl_file, file) != 0):
				continue
			if ((windex_int_member(decl, c"line", -1) == line) & (windex_int_member(decl, c"column", -1) == column)):
				return 1
	return 0


# Name of the function decl in 'file' whose span contains 'line', or 0.
char* windex_enclosing_function(char* file, int line):
	char* best = 0
	int best_start = -1
	for json_value* decl in windex_decls:
		char* decl_file = windex_string_member(decl, c"file")
		if (decl_file == 0):
			continue
		if (strcmp(decl_file, file) != 0):
			continue
		char* kind = windex_string_member(decl, c"kind")
		if (kind == 0):
			continue
		if (strcmp(kind, c"function") != 0):
			continue
		int decl_line = windex_int_member(decl, c"line", -1)
		if (decl_line > line):
			continue
		if (decl_line > best_start):
			best_start = decl_line
			best = windex_string_member(decl, c"name")
	if (best == 0):
		return 0
	list[int] boundaries = windex_get_boundaries(file)
	if (line > windex_span_end(boundaries, best_start)):
		return 0
	return best


/* subcommands */


void windex_cmd_symbol(char* name, list[char*] entry_files):
	if (windex_build(entry_files) == 0):
		return
	if (name in windex_by_name):
		for json_value* record in windex_by_name[name]:
			windex_emit(record)


void windex_cmd_type(char* name, list[char*] entry_files):
	windex_cmd_symbol(name, entry_files)


void windex_cmd_struct(char* name, list[char*] entry_files):
	if (windex_build(entry_files) == 0):
		return
	if (name in windex_by_name):
		for json_value* record in windex_by_name[name]:
			char* kind = windex_string_member(record, c"kind")
			if (kind == 0):
				continue
			if ((strcmp(kind, c"struct") != 0) & (strcmp(kind, c"union") != 0)):
				continue
			json_value* fields = windex_member(record, c"fields")
			if (fields == 0):
				continue
			int i = 0
			while (i < json_array_length(fields)):
				json_value* field = json_array_get(fields, i)
				json_value* out = json_object()
				json_object_set(out, c"struct", json_string(strclone(name)))
				json_object_set(out, c"field", json_string(strclone(windex_string_member(field, c"name"))))
				json_object_set(out, c"type", json_string(strclone(windex_string_member(field, c"type"))))
				json_object_set(out, c"offset", json_int(windex_int_member(field, c"offset", 0)))
				windex_emit(out)
				json_free(out)
				i = i + 1


void windex_cmd_references(char* name, list[char*] entry_files):
	if (windex_build(entry_files) == 0):
		return
	for char* file in windex_files:
		char* text = file_read_text(file)
		if (text == 0):
			continue
		list[json_value*] hits = windex_scan_identifiers(text, name)
		free(text)
		for json_value* hit in hits:
			int line = windex_int_member(hit, c"line", 0)
			int column = windex_int_member(hit, c"column", 0)
			int is_decl = windex_is_declaration(name, file, line, column)
			json_object_set(hit, c"file", json_string(strclone(file)))
			json_object_set(hit, c"is_declaration", json_bool(is_decl))
			windex_emit(hit)
			json_free(hit)


void windex_cmd_callers(char* name, list[char*] entry_files):
	if (windex_build(entry_files) == 0):
		return
	list[json_value*] refs = new list[json_value*]
	for char* file in windex_files:
		char* text = file_read_text(file)
		if (text == 0):
			continue
		list[json_value*] hits = windex_scan_identifiers(text, name)
		free(text)
		for json_value* hit in hits:
			json_object_set(hit, c"file", json_string(strclone(file)))
			refs.push(hit)
	for json_value* ref in refs:
		char* file = windex_string_member(ref, c"file")
		int line = windex_int_member(ref, c"line", 0)
		int column = windex_int_member(ref, c"column", 0)
		if (windex_is_declaration(name, file, line, column) == 0):
			char* caller = windex_enclosing_function(file, line)
			if (caller != 0):
				json_value* out = json_object()
				json_object_set(out, c"caller", json_string(strclone(caller)))
				json_object_set(out, c"callee", json_string(strclone(name)))
				json_object_set(out, c"file", json_string(strclone(file)))
				json_object_set(out, c"line", json_int(line))
				json_object_set(out, c"column", json_int(column))
				windex_emit(out)
				json_free(out)
		json_free(ref)


void windex_cmd_callees(char* name, list[char*] entry_files):
	if (windex_build(entry_files) == 0):
		return
	char* file = 0
	int start_line = 0
	int decl_column = 0
	if (name in windex_by_name):
		for json_value* decl in windex_by_name[name]:
			if (strcmp(windex_string_member(decl, c"kind"), c"function") == 0):
				file = windex_string_member(decl, c"file")
				start_line = windex_int_member(decl, c"line", 0)
				decl_column = windex_int_member(decl, c"column", 0)
				break
	if (file == 0):
		return
	list[int] boundaries = windex_get_boundaries(file)
	int end_line = windex_span_end(boundaries, start_line)
	char* text = file_read_text(file)
	if (text == 0):
		return
	list[json_value*] all = windex_scan_all_identifiers(text)
	free(text)
	for json_value* occ in all:
		int line = windex_int_member(occ, c"line", 0)
		int column = windex_int_member(occ, c"column", 0)
		if ((line >= start_line) & (line <= end_line)):
			if ((line != start_line) | (column != decl_column)):
				char* word = windex_string_member(occ, c"name")
				int is_function = 0
				if (word in windex_by_name):
					for json_value* candidate in windex_by_name[word]:
						if (strcmp(windex_string_member(candidate, c"kind"), c"function") == 0):
							is_function = 1
							break
				if (is_function):
					json_value* out = json_object()
					json_object_set(out, c"caller", json_string(strclone(name)))
					json_object_set(out, c"callee", json_string(strclone(word)))
					json_object_set(out, c"file", json_string(strclone(file)))
					json_object_set(out, c"line", json_int(line))
					json_object_set(out, c"column", json_int(column))
					windex_emit(out)
					json_free(out)
		json_free(occ)


# Textual re-parse of 'import a.b[.*][ as alias]' lines (column 0 only);
# there is no persistent importer/imported graph in the compiler to reuse.
void windex_cmd_imports(char* file):
	char* text = file_read_text(file)
	if (text == 0):
		return
	int pos = 0
	int line = 1
	while (text[pos] != 0):
		if (starts_with(text + pos, c"import ")):
			char* rest = text + pos + 7
			int j = 0
			while ((rest[j] != 0) & (rest[j] != '\n') & (rest[j] != '\r')):
				j = j + 1
			char* content = path_clone_range(rest, j)
			char* alias = 0
			int k = 0
			int split_at = -1
			while (content[k] != 0):
				if (starts_with(content + k, c" as ")):
					split_at = k
					break
				k = k + 1
			if (split_at >= 0):
				alias = strclone(content + split_at + 4)
				content[split_at] = 0
			if (ends_with(content, c".*")):
				content[strlen(content) - 2] = 0
			json_value* record = json_object()
			json_object_set(record, c"file", json_string(strclone(file)))
			json_object_set(record, c"module", json_string(strclone(content)))
			if (alias != 0):
				json_object_set(record, c"alias", json_string(alias))
			else:
				json_object_set(record, c"alias", json_null())
			json_object_set(record, c"line", json_int(line))
			windex_emit(record)
			json_free(record)
			free(content)
		while ((text[pos] != 0) & (text[pos] != '\n')):
			pos = pos + 1
		if (text[pos] == '\n'):
			pos = pos + 1
		line = line + 1
	free(text)


/* lifecycle and dispatch */


int windex_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: windex symbol|references|type|struct|callers|callees <name> <file...>")
	stream_write_line(err, c"       windex imports <file>")
	stream_flush(err)
	return 1


# The binary lives in bin/, so when launched by a path ending in bin/ hop
# to the parent (the repo root) so ./bin/wv2 resolves.
void windex_chdir_root():
	char* program = args_program()
	if (program == 0):
		return
	char* dir = path_dirname(program)
	char* base = path_basename(dir)
	if (strcmp(base, c"bin") == 0):
		char* root = path_join(dir, c"..")
		chdir(root)
		free(root)
	free(dir)
	free(base)


int main(int argc, int argv):
	args_init(argc, argv)
	windex_chdir_root()
	if (argc < 2):
		return windex_usage()
	char** command_ptr = argv + __word_size__
	char* command = *command_ptr
	if (strcmp(command, c"imports") == 0):
		if (argc < 3):
			return windex_usage()
		char** file_ptr = argv + 2 * __word_size__
		windex_cmd_imports(*file_ptr)
		return 0
	if (argc < 4):
		return windex_usage()
	char** name_ptr = argv + 2 * __word_size__
	char* name = *name_ptr
	list[char*] entry_files = new list[char*]
	int i = 3
	while (i < argc):
		char** arg_ptr = argv + i * __word_size__
		entry_files.push(*arg_ptr)
		i = i + 1
	if (strcmp(command, c"symbol") == 0):
		windex_cmd_symbol(name, entry_files)
	else if (strcmp(command, c"references") == 0):
		windex_cmd_references(name, entry_files)
	else if (strcmp(command, c"type") == 0):
		windex_cmd_type(name, entry_files)
	else if (strcmp(command, c"struct") == 0):
		windex_cmd_struct(name, entry_files)
	else if (strcmp(command, c"callers") == 0):
		windex_cmd_callers(name, entry_files)
	else if (strcmp(command, c"callees") == 0):
		windex_cmd_callees(name, entry_files)
	else:
		return windex_usage()
	return 0
