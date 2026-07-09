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
# This is the query engine shared by the one-shot CLI (w_index.w) and the
# persistent daemon (w_indexd.w, docs/projects/index_daemon.md): every
# function here takes an explicit windex_index* (built by windex_build)
# and an output string_builder* instead of touching globals or fd 1
# directly, so a caller — the CLI or a daemon serving many entry-file
# sets — controls the index's lifetime and where NDJSON output goes.
import lib.lib
import lib.path
import lib.file
import lib.process
import structures.string
import structures.json


int windex_timeout_ms():
	return 60000


# Discovery file the daemon (w_indexd.w) advertises its listen port
# through, and the CLI (w_index.w) reads to find a warm daemon. Shared
# here so the two binaries cannot disagree on the format.
char* windexd_port_file():
	return c"bin/.windexd.port"


# -1 when there is no port file, or its contents are not a positive
# integer — both mean "treat this as no daemon running".
int windexd_read_port():
	char* text = file_read_text(windexd_port_file())
	if (text == 0):
		return -1
	int port = atoi(text)
	free(text)
	if (port <= 0):
		return -1
	return port


void windexd_write_port(int port):
	string_builder* s = string_new()
	string_append_int(s, port)
	file_write_text(windexd_port_file(), s.data)
	string_free(s)


struct windex_index:
	# Declarations from windex_build(), in 'wv2 symbols --json' order.
	list[json_value*] decls
	# Declarations grouped by name (a name can have several: a struct's
	# type and object entries share a name; externs can repeat across
	# archs).
	map[char*, list[json_value*]] by_name
	# Unique files named by any declaration, in first-seen order: the
	# transitive closure the entry files' compile reached.
	list[char*] files
	# Per-file cache of column-0 boundary line numbers (windex_boundaries()).
	map[char*, list[int]] boundaries_cache


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


void windex_emit(string_builder* out, json_value* record):
	char* body = json_stringify(record)
	string_append(out, body)
	string_append_char(out, '\n')
	free(body)


/* building the index */


int windex_files_contains(windex_index* idx, char* file):
	for char* known in idx.files:
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


# Compiles entry_files via 'wv2 symbols --json' and returns a populated
# index, or 0 when the subprocess could not run or the compile failed.
windex_index* windex_build(list[char*] entry_files):
	process_result* result = windex_run_symbols(entry_files)
	if (result == 0):
		return 0
	if (result.status != 0):
		process_result_free(result)
		return 0
	list[json_value*] records = windex_parse_ndjson(result.stdout_text)
	process_result_free(result)

	windex_index* idx = new windex_index()
	idx.decls = new list[json_value*]
	idx.by_name = new map[char*, list[json_value*]]
	idx.files = new list[char*]
	idx.boundaries_cache = new map[char*, list[int]]
	for json_value* record in records:
		idx.decls.push(record)
		char* name = windex_string_member(record, c"name")
		if (name != 0):
			if (name in idx.by_name):
				idx.by_name[name].push(record)
			else:
				list[json_value*] bucket = new list[json_value*]
				bucket.push(record)
				idx.by_name[name] = bucket
		char* file = windex_string_member(record, c"file")
		if (file != 0):
			if (windex_files_contains(idx, file) == 0):
				idx.files.push(file)
	return idx


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


list[int] windex_get_boundaries(windex_index* idx, char* file):
	if (file in idx.boundaries_cache):
		return idx.boundaries_cache[file]
	list[int] boundaries = new list[int]
	char* text = file_read_text(file)
	if (text != 0):
		boundaries = windex_boundaries(text)
		free(text)
	idx.boundaries_cache[file] = boundaries
	return boundaries


# Last line of the block starting at start_line: the line before the next
# boundary, or "end of file" (a large sentinel; callers only compare it
# against real line numbers from the same file).
int windex_span_end(list[int] boundaries, int start_line):
	for int b in boundaries:
		if (b > start_line):
			return b - 1
	return 2147483647


int windex_is_declaration(windex_index* idx, char* name, char* file, int line, int column):
	if (name in idx.by_name):
		for json_value* decl in idx.by_name[name]:
			char* decl_file = windex_string_member(decl, c"file")
			if (decl_file == 0):
				continue
			if (strcmp(decl_file, file) != 0):
				continue
			if ((windex_int_member(decl, c"line", -1) == line) & (windex_int_member(decl, c"column", -1) == column)):
				return 1
	return 0


# Name of the function decl in 'file' whose span contains 'line', or 0.
char* windex_enclosing_function(windex_index* idx, char* file, int line):
	char* best = 0
	int best_start = -1
	for json_value* decl in idx.decls:
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
	list[int] boundaries = windex_get_boundaries(idx, file)
	if (line > windex_span_end(boundaries, best_start)):
		return 0
	return best


/* subcommands */


void windex_cmd_symbol(windex_index* idx, char* name, string_builder* out):
	if (name in idx.by_name):
		for json_value* record in idx.by_name[name]:
			windex_emit(out, record)


void windex_cmd_type(windex_index* idx, char* name, string_builder* out):
	windex_cmd_symbol(idx, name, out)


void windex_cmd_struct(windex_index* idx, char* name, string_builder* out):
	if (name in idx.by_name):
		for json_value* record in idx.by_name[name]:
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
				json_value* out_record = json_object()
				json_object_set(out_record, c"struct", json_string(strclone(name)))
				json_object_set(out_record, c"field", json_string(strclone(windex_string_member(field, c"name"))))
				json_object_set(out_record, c"type", json_string(strclone(windex_string_member(field, c"type"))))
				json_object_set(out_record, c"offset", json_int(windex_int_member(field, c"offset", 0)))
				windex_emit(out, out_record)
				json_free(out_record)
				i = i + 1


void windex_cmd_references(windex_index* idx, char* name, string_builder* out):
	for char* file in idx.files:
		char* text = file_read_text(file)
		if (text == 0):
			continue
		list[json_value*] hits = windex_scan_identifiers(text, name)
		free(text)
		for json_value* hit in hits:
			int line = windex_int_member(hit, c"line", 0)
			int column = windex_int_member(hit, c"column", 0)
			int is_decl = windex_is_declaration(idx, name, file, line, column)
			json_object_set(hit, c"file", json_string(strclone(file)))
			json_object_set(hit, c"is_declaration", json_bool(is_decl))
			windex_emit(out, hit)
			json_free(hit)


void windex_cmd_callers(windex_index* idx, char* name, string_builder* out):
	list[json_value*] refs = new list[json_value*]
	for char* file in idx.files:
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
		if (windex_is_declaration(idx, name, file, line, column) == 0):
			char* caller = windex_enclosing_function(idx, file, line)
			if (caller != 0):
				json_value* out_record = json_object()
				json_object_set(out_record, c"caller", json_string(strclone(caller)))
				json_object_set(out_record, c"callee", json_string(strclone(name)))
				json_object_set(out_record, c"file", json_string(strclone(file)))
				json_object_set(out_record, c"line", json_int(line))
				json_object_set(out_record, c"column", json_int(column))
				windex_emit(out, out_record)
				json_free(out_record)
		json_free(ref)


void windex_cmd_callees(windex_index* idx, char* name, string_builder* out):
	char* file = 0
	int start_line = 0
	int decl_column = 0
	if (name in idx.by_name):
		for json_value* decl in idx.by_name[name]:
			if (strcmp(windex_string_member(decl, c"kind"), c"function") == 0):
				file = windex_string_member(decl, c"file")
				start_line = windex_int_member(decl, c"line", 0)
				decl_column = windex_int_member(decl, c"column", 0)
				break
	if (file == 0):
		return
	list[int] boundaries = windex_get_boundaries(idx, file)
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
				if (word in idx.by_name):
					for json_value* candidate in idx.by_name[word]:
						if (strcmp(windex_string_member(candidate, c"kind"), c"function") == 0):
							is_function = 1
							break
				if (is_function):
					json_value* out_record = json_object()
					json_object_set(out_record, c"caller", json_string(strclone(name)))
					json_object_set(out_record, c"callee", json_string(strclone(word)))
					json_object_set(out_record, c"file", json_string(strclone(file)))
					json_object_set(out_record, c"line", json_int(line))
					json_object_set(out_record, c"column", json_int(column))
					windex_emit(out, out_record)
					json_free(out_record)
		json_free(occ)


# Textual re-parse of 'import a.b[.*][ as alias]' lines (column 0 only);
# there is no persistent importer/imported graph in the compiler to reuse.
# Stateless: does not need a windex_index, matching imports_for's contract.
void windex_cmd_imports(char* file, string_builder* out):
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
			windex_emit(out, record)
			json_free(record)
			free(content)
		while ((text[pos] != 0) & (text[pos] != '\n')):
			pos = pos + 1
		if (text[pos] == '\n'):
			pos = pos + 1
		line = line + 1
	free(text)


# Runs one of the named subcommands (symbol/type/struct/references/
# callers/callees) against idx, appending NDJSON to out. Returns 0 for an
# unknown subcommand, 1 otherwise.
int windex_dispatch(windex_index* idx, char* subcommand, char* name, string_builder* out):
	if (strcmp(subcommand, c"symbol") == 0):
		windex_cmd_symbol(idx, name, out)
	else if (strcmp(subcommand, c"references") == 0):
		windex_cmd_references(idx, name, out)
	else if (strcmp(subcommand, c"type") == 0):
		windex_cmd_type(idx, name, out)
	else if (strcmp(subcommand, c"struct") == 0):
		windex_cmd_struct(idx, name, out)
	else if (strcmp(subcommand, c"callers") == 0):
		windex_cmd_callers(idx, name, out)
	else if (strcmp(subcommand, c"callees") == 0):
		windex_cmd_callees(idx, name, out)
	else:
		return 0
	return 1
