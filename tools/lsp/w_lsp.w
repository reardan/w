# Minimal stdio LSP server for the W toolchain: JSON-RPC 2.0 over
# Content-Length framing. Diagnostics come from 'wv2 check --json' on
# didOpen/didSave; textDocument/definition resolves through
# 'wv2 symbols --json' (globals, functions and user types only — the
# symbols dump has no locals or parameters). See docs/projects/lsp.md.
#
# Build and run (the server speaks LSP on stdin/stdout):
#   ./wbuild wlsp && ./bin/wlsp
import lib.lib
import lib.args
import lib.path
import lib.file
import lib.framing
import lib.process
import structures.string
import structures.json


int lsp_check_timeout_ms():
	return 60000


# Open document text keyed by URI, kept current by didOpen/didChange so
# definition requests can extract the identifier under the cursor.
map[char*, char*] lsp_documents

# URIs that received diagnostics on the last check of a given document
# (a check can surface records in imported files), so the next check of
# the same document can clear the ones that no longer produce records.
map[char*, list[char*]] lsp_published

int lsp_exit_requested


/* URI <-> path conversion */


int lsp_hex_digit(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	if ((c >= 'a') & (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') & (c <= 'F')):
		return c - 'A' + 10
	return 0 - 1


# file:// URI to a filesystem path: strips the scheme (and empty host)
# and decodes %XX escapes. Returns a malloc'd path, or 0 for URIs with
# another scheme.
char* lsp_uri_to_path(char* uri):
	char* prefix = c"file://"
	int i = 0
	while (prefix[i]):
		if (uri[i] != prefix[i]):
			return 0
		i = i + 1
	string_builder* out = string_new()
	while (uri[i]):
		int c = uri[i] & 255
		if (c == '%'):
			int hi = lsp_hex_digit(uri[i + 1] & 255)
			int lo = 0 - 1
			if (hi >= 0):
				lo = lsp_hex_digit(uri[i + 2] & 255)
			if (lo >= 0):
				string_append_char(out, hi * 16 + lo)
				i = i + 3
				continue
		string_append_char(out, c)
		i = i + 1
	char* path = out.data
	free(out)
	return path


# Path to a file:// URI. Relative paths (the compiler reports imports
# relative to its working directory) are resolved against the current
# directory. Paths in this repo are plain ASCII, so no percent-encoding.
char* lsp_path_to_uri(char* path):
	string_builder* out = string_from(c"file://")
	if (path[0] != '/'):
		char* cwd = malloc(4096)
		getcwd(cwd, 4096)
		string_append(out, cwd)
		string_append(out, c"/")
		free(cwd)
	string_append(out, path)
	char* uri = out.data
	free(out)
	return uri


/* JSON helpers */


# Object member, or 0 when value is not an object or the key is absent.
json_value* lsp_member(json_value* value, char* key):
	if (value == 0):
		return 0
	if (value.type != json_type_object()):
		return 0
	return json_object_get(value, key)


char* lsp_string_member(json_value* value, char* key):
	json_value* member = lsp_member(value, key)
	if (member == 0):
		return 0
	if (member.type != json_type_string()):
		return 0
	return member.string_value


int lsp_int_member(json_value* value, char* key, int missing):
	json_value* member = lsp_member(value, key)
	if (member == 0):
		return missing
	if ((member.type != json_type_int()) & (member.type != json_type_bool())):
		return missing
	return member.int_value


# Splits subprocess stdout into non-blank lines and parses each as one
# JSON record; lines that do not parse are skipped so stray output
# cannot take the whole request down.
json_value* lsp_parse_ndjson(char* text):
	json_value* records = json_array()
	string_builder* line = string_new()
	int i = 0
	while (1):
		int c = text[i]
		if ((c == '\n') | (c == 0)):
			if (line.length > 0):
				json_value* record = json_parse(line.data)
				if (record != 0):
					json_array_push(records, record)
			string_clear(line)
			if (c == 0):
				string_free(line)
				return records
		else if (c != '\r'):
			string_append_char(line, c)
		i = i + 1
	return records


/* response plumbing */


void lsp_send(json_value* message):
	char* body = json_stringify(message)
	frame_write_cstr(1, body)
	free(body)
	json_free(message)


json_value* lsp_clone_id(json_value* id):
	if (id == 0):
		return json_null()
	return json_clone(id)


void lsp_success(json_value* id, json_value* result):
	json_value* response = json_object()
	json_object_set(response, c"jsonrpc", json_string(c"2.0"))
	json_object_set(response, c"id", lsp_clone_id(id))
	json_object_set(response, c"result", result)
	lsp_send(response)


void lsp_respond_error(json_value* id, int code, char* message):
	json_value* error = json_object()
	json_object_set(error, c"code", json_int(code))
	json_object_set(error, c"message", json_string(message))
	json_value* response = json_object()
	json_object_set(response, c"jsonrpc", json_string(c"2.0"))
	json_object_set(response, c"id", lsp_clone_id(id))
	json_object_set(response, c"error", error)
	lsp_send(response)


void lsp_notify(char* method, json_value* params):
	json_value* message = json_object()
	json_object_set(message, c"jsonrpc", json_string(c"2.0"))
	json_object_set(message, c"method", json_string(method))
	json_object_set(message, c"params", params)
	lsp_send(message)


/* document store */


void lsp_store_document(char* uri, char* text):
	if (uri in lsp_documents):
		free(lsp_documents[uri])
	lsp_documents[uri] = strclone(text)


void lsp_drop_document(char* uri):
	if (uri in lsp_documents):
		free(lsp_documents[uri])
		lsp_documents[uri] = 0


# Current text for uri: the stored open-document text, or the file on
# disk. Returns a malloc'd copy, or 0 when neither exists.
char* lsp_document_text(char* uri):
	if (uri in lsp_documents):
		char* stored = lsp_documents[uri]
		if (stored != 0):
			return strclone(stored)
	char* path = lsp_uri_to_path(uri)
	if (path == 0):
		return 0
	char* text = file_read_text(path)
	free(path)
	return text


/* compiler subprocess */


# Runs './bin/wv2 <subcommand> --json <path>' from the repo root and
# returns the captured result, or 0 when the spawn failed.
process_result* lsp_run_wv2(char* subcommand, char* path):
	char** argv = strv_new(4)
	strv_set(argv, 0, c"./bin/wv2")
	strv_set(argv, 1, subcommand)
	strv_set(argv, 2, c"--json")
	strv_set(argv, 3, path)
	process_result* result = process_run(c"./bin/wv2", argv, 0, 0, lsp_check_timeout_ms())
	free(cast(void*, argv))
	return result


# Runs './bin/windex <subcommand> <name> <path>' from the repo root (see
# docs/projects/semantic_index.md). Used for references and rename, which
# need occurrences beyond the declarations 'wv2 symbols --json' has.
process_result* lsp_run_windex(char* subcommand, char* name, char* path):
	char** argv = strv_new(4)
	strv_set(argv, 0, c"./bin/windex")
	strv_set(argv, 1, subcommand)
	strv_set(argv, 2, name)
	strv_set(argv, 3, path)
	process_result* result = process_run(c"./bin/windex", argv, 0, 0, lsp_check_timeout_ms())
	free(cast(void*, argv))
	return result


/* diagnostics */


# Compiler line/column are 1-based; LSP positions are 0-based. The range
# spans token_length characters on one line.
json_value* lsp_range(int line, int column, int token_length):
	if (line < 1):
		line = 1
	if (column < 1):
		column = 1
	json_value* start = json_object()
	json_object_set(start, c"line", json_int(line - 1))
	json_object_set(start, c"character", json_int(column - 1))
	json_value* stop = json_object()
	json_object_set(stop, c"line", json_int(line - 1))
	json_object_set(stop, c"character", json_int(column - 1 + token_length))
	json_value* range = json_object()
	json_object_set(range, c"start", start)
	json_object_set(range, c"end", stop)
	return range


int lsp_severity_number(char* severity):
	if (severity == 0):
		return 2
	if (strcmp(severity, c"error") == 0):
		return 1
	return 2


# One 'w check --json' record to one LSP Diagnostic.
json_value* lsp_diagnostic(json_value* record):
	int token_length = 1
	char* token = lsp_string_member(record, c"token")
	if (token != 0):
		if (token[0] != 0):
			token_length = strlen(token)
	json_value* diagnostic = json_object()
	int line = lsp_int_member(record, c"line", 1)
	int column = lsp_int_member(record, c"column", 1)
	json_object_set(diagnostic, c"range", lsp_range(line, column, token_length))
	json_object_set(diagnostic, c"severity", json_int(lsp_severity_number(lsp_string_member(record, c"severity"))))
	json_object_set(diagnostic, c"source", json_string(c"w check"))
	char* message = lsp_string_member(record, c"message")
	if (message == 0):
		message = c""
	json_object_set(diagnostic, c"message", json_string(message))
	return diagnostic


void lsp_publish(char* uri, json_value* diagnostics):
	json_value* params = json_object()
	json_object_set(params, c"uri", json_string(uri))
	json_object_set(params, c"diagnostics", diagnostics)
	lsp_notify(c"textDocument/publishDiagnostics", params)


int lsp_list_contains(list[char*] items, char* value):
	int i = 0
	while (i < items.length):
		if (strcmp(items[i], value) == 0):
			return 1
		i = i + 1
	return 0


# Runs 'wv2 check --json' for uri, groups the records by file, publishes
# one diagnostics notification per file, and clears any URI that got
# diagnostics on the previous check of this document but not on this one.
void lsp_check_document(char* uri):
	char* path = lsp_uri_to_path(uri)
	if (path == 0):
		return
	process_result* result = lsp_run_wv2(c"check", path)
	free(path)
	if (result == 0):
		return
	json_value* records = lsp_parse_ndjson(result.stdout_text)
	process_result_free(result)

	# Group diagnostics by file URI; the checked document always gets an
	# entry so a now-clean file has its old diagnostics replaced.
	json_value* by_uri = json_object()
	json_object_set(by_uri, uri, json_array())
	int i = 0
	while (i < json_array_length(records)):
		json_value* record = json_array_get(records, i)
		char* file = lsp_string_member(record, c"file")
		if (file != 0):
			char* file_uri = lsp_path_to_uri(file)
			json_value* group = json_object_get(by_uri, file_uri)
			if (group == 0):
				group = json_array()
				json_object_set(by_uri, file_uri, group)
			json_array_push(group, lsp_diagnostic(record))
			free(file_uri)
		i = i + 1
	json_free(records)

	list[char*] published = new list[char*]
	for char* group_uri, json_value* group in by_uri.object_values:
		lsp_publish(group_uri, json_clone(group))
		published.push(strclone(group_uri))
	json_free(by_uri)

	if (uri in lsp_published):
		list[char*] previous = lsp_published[uri]
		i = 0
		while (i < previous.length):
			if (lsp_list_contains(published, previous[i]) == 0):
				lsp_publish(previous[i], json_array())
			free(previous[i])
			i = i + 1
	lsp_published[uri] = published


# Clears every URI published for this document (used on didClose).
void lsp_clear_diagnostics(char* uri):
	if (uri in lsp_published):
		list[char*] previous = lsp_published[uri]
		int i = 0
		while (i < previous.length):
			lsp_publish(previous[i], json_array())
			free(previous[i])
			i = i + 1
		lsp_published[uri] = new list[char*]
	else:
		lsp_publish(uri, json_array())


/* go to definition */


int lsp_is_word_char(int c):
	if ((c >= 'a') & (c <= 'z')):
		return 1
	if ((c >= 'A') & (c <= 'Z')):
		return 1
	if ((c >= '0') & (c <= '9')):
		return 1
	return c == '_'


# The identifier spanning the 0-based line/character position in text,
# as a malloc'd string, or 0 when the position is not on an identifier.
char* lsp_identifier_at(char* text, int line, int character):
	int i = 0
	int current = 0
	while ((current < line) & (text[i] != 0)):
		if (text[i] == '\n'):
			current = current + 1
		i = i + 1
	if (current < line):
		return 0
	int line_start = i
	int col = 0
	while ((col < character) & (text[i] != 0) & (text[i] != '\n')):
		i = i + 1
		col = col + 1
	int start = i
	while (start > line_start):
		if (lsp_is_word_char(text[start - 1] & 255) == 0):
			break
		start = start - 1
	int stop = i
	while (lsp_is_word_char(text[stop] & 255)):
		stop = stop + 1
	if (stop == start):
		return 0
	return path_clone_range(text + start, stop - start)


# Identifier at a didOpen/didChange-tracked document's position (or the
# file on disk), as a malloc'd string, or 0 when there is none.
char* lsp_identifier_at_position(char* uri, json_value* position):
	char* text = lsp_document_text(uri)
	if (text == 0):
		return 0
	int line = lsp_int_member(position, c"line", 0)
	int character = lsp_int_member(position, c"character", 0)
	char* name = lsp_identifier_at(text, line, character)
	free(text)
	return name


# Matching 'wv2 symbols --json' records as an array of LSP Locations.
json_value* lsp_symbol_locations(json_value* records, char* name):
	json_value* locations = json_array()
	int i = 0
	while (i < json_array_length(records)):
		json_value* record = json_array_get(records, i)
		char* record_name = lsp_string_member(record, c"name")
		char* file = lsp_string_member(record, c"file")
		if ((record_name != 0) & (file != 0)):
			if (strcmp(record_name, name) == 0):
				json_value* location = json_object()
				char* file_uri = lsp_path_to_uri(file)
				json_object_set(location, c"uri", json_string(file_uri))
				free(file_uri)
				int line = lsp_int_member(record, c"line", 1)
				int column = lsp_int_member(record, c"column", 1)
				json_object_set(location, c"range", lsp_range(line, column, strlen(name)))
				json_array_push(locations, location)
		i = i + 1
	return locations


# Records (whole objects, not Locations) whose "name" equals name.
list[json_value*] lsp_filter_records(json_value* records, char* name):
	list[json_value*] matches = new list[json_value*]
	int i = 0
	while (i < json_array_length(records)):
		json_value* record = json_array_get(records, i)
		char* record_name = lsp_string_member(record, c"name")
		if (record_name != 0):
			if (strcmp(record_name, name) == 0):
				matches.push(record)
		i = i + 1
	return matches


void lsp_handle_definition(json_value* id, json_value* params):
	char* uri = lsp_string_member(lsp_member(params, c"textDocument"), c"uri")
	json_value* position = lsp_member(params, c"position")
	if ((uri == 0) | (position == 0)):
		lsp_success(id, json_null())
		return
	char* name = lsp_identifier_at_position(uri, position)
	if (name == 0):
		lsp_success(id, json_null())
		return

	char* path = lsp_uri_to_path(uri)
	if (path == 0):
		free(name)
		lsp_success(id, json_null())
		return
	process_result* result = lsp_run_wv2(c"symbols", path)
	free(path)
	if (result == 0):
		free(name)
		lsp_success(id, json_null())
		return
	# Nonzero exit means the compile failed before the symbol dump ran.
	if (result.status != 0):
		process_result_free(result)
		free(name)
		lsp_success(id, json_null())
		return
	json_value* records = lsp_parse_ndjson(result.stdout_text)
	process_result_free(result)
	json_value* locations = lsp_symbol_locations(records, name)
	json_free(records)
	free(name)
	if (json_array_length(locations) == 0):
		json_free(locations)
		lsp_success(id, json_null())
		return
	lsp_success(id, locations)


/* hover */


# One-line plaintext summary of a 'wv2 symbols --json' record: "kind
# name: type", plus "{ field: type, ... }" for struct/union records
# (which carry a "fields" array; see docs/projects/semantic_index.md).
char* lsp_hover_content(json_value* record):
	string_builder* out = string_from(lsp_string_member(record, c"kind"))
	string_append(out, c" ")
	string_append(out, lsp_string_member(record, c"name"))
	string_append(out, c": ")
	string_append(out, lsp_string_member(record, c"type"))
	json_value* fields = lsp_member(record, c"fields")
	if (fields != 0):
		string_append(out, c" { ")
		int i = 0
		while (i < json_array_length(fields)):
			if (i > 0):
				string_append(out, c", ")
			json_value* field = json_array_get(fields, i)
			string_append(out, lsp_string_member(field, c"name"))
			string_append(out, c": ")
			string_append(out, lsp_string_member(field, c"type"))
			i = i + 1
		string_append(out, c" }")
	char* content = out.data
	free(out)
	return content


# The richest match for name: prefers a struct/union/enum/function/alias
# record over a plain "object" one, since a type's own object symbol and
# its type-table entry can share a name (see tests/symbols_fixture.w's
# sym_fixture_point, dumped once as "object" and once as "struct").
json_value* lsp_best_record(list[json_value*] matches):
	json_value* best = matches[0]
	int i = 0
	while (i < matches.length):
		if (strcmp(lsp_string_member(matches[i], c"kind"), c"object") != 0):
			return matches[i]
		i = i + 1
	return best


void lsp_handle_hover(json_value* id, json_value* params):
	char* uri = lsp_string_member(lsp_member(params, c"textDocument"), c"uri")
	json_value* position = lsp_member(params, c"position")
	if ((uri == 0) | (position == 0)):
		lsp_success(id, json_null())
		return
	char* name = lsp_identifier_at_position(uri, position)
	if (name == 0):
		lsp_success(id, json_null())
		return
	char* path = lsp_uri_to_path(uri)
	if (path == 0):
		free(name)
		lsp_success(id, json_null())
		return
	process_result* result = lsp_run_wv2(c"symbols", path)
	free(path)
	if (result == 0):
		free(name)
		lsp_success(id, json_null())
		return
	if (result.status != 0):
		process_result_free(result)
		free(name)
		lsp_success(id, json_null())
		return
	json_value* records = lsp_parse_ndjson(result.stdout_text)
	process_result_free(result)
	list[json_value*] matches = lsp_filter_records(records, name)
	free(name)
	if (matches.length == 0):
		json_free(records)
		lsp_success(id, json_null())
		return
	char* content = lsp_hover_content(lsp_best_record(matches))
	json_free(records)
	json_value* markup = json_object()
	json_object_set(markup, c"kind", json_string(c"plaintext"))
	json_object_set(markup, c"value", json_string_take(content))
	json_value* hover = json_object()
	json_object_set(hover, c"contents", markup)
	lsp_success(id, hover)


/* references and rename */


# find_references-style records ({name, file, line, column,
# is_declaration}) for the identifier at uri/position, via
# './bin/windex references' — or 0 (nothing resolvable) when the position
# is not on an identifier, the path can't be resolved, or windex fails.
json_value* lsp_reference_records(json_value* params):
	char* uri = lsp_string_member(lsp_member(params, c"textDocument"), c"uri")
	json_value* position = lsp_member(params, c"position")
	if ((uri == 0) | (position == 0)):
		return 0
	char* name = lsp_identifier_at_position(uri, position)
	if (name == 0):
		return 0
	char* path = lsp_uri_to_path(uri)
	if (path == 0):
		free(name)
		return 0
	process_result* result = lsp_run_windex(c"references", name, path)
	free(path)
	free(name)
	if (result == 0):
		return 0
	if (result.status != 0):
		process_result_free(result)
		return 0
	json_value* records = lsp_parse_ndjson(result.stdout_text)
	process_result_free(result)
	return records


void lsp_handle_references(json_value* id, json_value* params):
	json_value* records = lsp_reference_records(params)
	if (records == 0):
		lsp_success(id, json_array())
		return
	int include_declaration = 1
	json_value* context = lsp_member(params, c"context")
	if (context != 0):
		json_value* include = json_object_get(context, c"includeDeclaration")
		if (include != 0):
			include_declaration = include.int_value
	json_value* locations = json_array()
	int i = 0
	while (i < json_array_length(records)):
		json_value* record = json_array_get(records, i)
		int is_declaration = lsp_int_member(record, c"is_declaration", 0)
		char* file = lsp_string_member(record, c"file")
		char* record_name = lsp_string_member(record, c"name")
		if ((is_declaration == 0) | include_declaration):
			if ((file != 0) & (record_name != 0)):
				json_value* location = json_object()
				char* file_uri = lsp_path_to_uri(file)
				json_object_set(location, c"uri", json_string(file_uri))
				free(file_uri)
				int line = lsp_int_member(record, c"line", 1)
				int column = lsp_int_member(record, c"column", 1)
				json_object_set(location, c"range", lsp_range(line, column, strlen(record_name)))
				json_array_push(locations, location)
		i = i + 1
	json_free(records)
	lsp_success(id, locations)


void lsp_handle_rename(json_value* id, json_value* params):
	char* new_name = lsp_string_member(params, c"newName")
	if (new_name == 0):
		lsp_respond_error(id, -32602, c"invalid params: newName is required")
		return
	json_value* records = lsp_reference_records(params)
	if (records == 0):
		lsp_respond_error(id, -32803, c"no renameable symbol at this position")
		return
	if (json_array_length(records) == 0):
		json_free(records)
		lsp_respond_error(id, -32803, c"no renameable symbol at this position")
		return

	# Group one TextEdit per occurrence by file URI.
	json_value* by_uri = json_object()
	int i = 0
	while (i < json_array_length(records)):
		json_value* record = json_array_get(records, i)
		char* file = lsp_string_member(record, c"file")
		char* record_name = lsp_string_member(record, c"name")
		if ((file != 0) & (record_name != 0)):
			char* file_uri = lsp_path_to_uri(file)
			json_value* edits = json_object_get(by_uri, file_uri)
			if (edits == 0):
				edits = json_array()
				json_object_set(by_uri, file_uri, edits)
			int line = lsp_int_member(record, c"line", 1)
			int column = lsp_int_member(record, c"column", 1)
			json_value* edit = json_object()
			json_object_set(edit, c"range", lsp_range(line, column, strlen(record_name)))
			json_object_set(edit, c"newText", json_string(strclone(new_name)))
			json_array_push(edits, edit)
			free(file_uri)
		i = i + 1
	json_free(records)

	json_value* changes = json_object()
	for char* group_uri, json_value* group in by_uri.object_values:
		json_object_set(changes, group_uri, json_clone(group))
	json_free(by_uri)

	json_value* workspace_edit = json_object()
	json_object_set(workspace_edit, c"changes", changes)
	lsp_success(id, workspace_edit)


/* lifecycle and dispatch */


void lsp_handle_initialize(json_value* id):
	json_value* sync = json_object()
	json_object_set(sync, c"openClose", json_bool(1))
	json_object_set(sync, c"change", json_int(1))
	json_object_set(sync, c"save", json_bool(1))
	json_value* capabilities = json_object()
	json_object_set(capabilities, c"textDocumentSync", sync)
	json_object_set(capabilities, c"definitionProvider", json_bool(1))
	json_object_set(capabilities, c"hoverProvider", json_bool(1))
	json_object_set(capabilities, c"referencesProvider", json_bool(1))
	json_object_set(capabilities, c"renameProvider", json_bool(1))
	json_value* server_info = json_object()
	json_object_set(server_info, c"name", json_string(c"w-lsp"))
	json_object_set(server_info, c"version", json_string(c"0.1.0"))
	json_value* result = json_object()
	json_object_set(result, c"capabilities", capabilities)
	json_object_set(result, c"serverInfo", server_info)
	lsp_success(id, result)


void lsp_handle_did_open(json_value* params):
	json_value* text_document = lsp_member(params, c"textDocument")
	char* uri = lsp_string_member(text_document, c"uri")
	if (uri == 0):
		return
	char* text = lsp_string_member(text_document, c"text")
	if (text != 0):
		lsp_store_document(uri, text)
	lsp_check_document(uri)


# Full sync (change = 1): the last content change carries the whole text.
void lsp_handle_did_change(json_value* params):
	char* uri = lsp_string_member(lsp_member(params, c"textDocument"), c"uri")
	json_value* changes = lsp_member(params, c"contentChanges")
	if ((uri == 0) | (changes == 0)):
		return
	if (changes.type != json_type_array()):
		return
	if (json_array_length(changes) == 0):
		return
	json_value* last = json_array_get(changes, json_array_length(changes) - 1)
	char* text = lsp_string_member(last, c"text")
	if (text != 0):
		lsp_store_document(uri, text)


void lsp_handle_did_save(json_value* params):
	char* uri = lsp_string_member(lsp_member(params, c"textDocument"), c"uri")
	if (uri == 0):
		return
	# didSave may carry the saved text when the client includes it.
	char* text = lsp_string_member(params, c"text")
	if (text != 0):
		lsp_store_document(uri, text)
	lsp_check_document(uri)


void lsp_handle_did_close(json_value* params):
	char* uri = lsp_string_member(lsp_member(params, c"textDocument"), c"uri")
	if (uri == 0):
		return
	lsp_drop_document(uri)
	lsp_clear_diagnostics(uri)


void lsp_handle(json_value* request):
	char* method = 0
	json_value* id = 0
	if (request.type == json_type_object()):
		method = lsp_string_member(request, c"method")
		id = json_object_get(request, c"id")
	if (method == 0):
		lsp_respond_error(id, -32600, c"invalid request")
		return
	json_value* params = lsp_member(request, c"params")
	if (strcmp(method, c"initialize") == 0):
		lsp_handle_initialize(id)
	else if (strcmp(method, c"initialized") == 0):
		return
	else if (strcmp(method, c"shutdown") == 0):
		lsp_success(id, json_null())
	else if (strcmp(method, c"exit") == 0):
		lsp_exit_requested = 1
	else if (strcmp(method, c"textDocument/didOpen") == 0):
		lsp_handle_did_open(params)
	else if (strcmp(method, c"textDocument/didChange") == 0):
		lsp_handle_did_change(params)
	else if (strcmp(method, c"textDocument/didSave") == 0):
		lsp_handle_did_save(params)
	else if (strcmp(method, c"textDocument/didClose") == 0):
		lsp_handle_did_close(params)
	else if (strcmp(method, c"textDocument/definition") == 0):
		lsp_handle_definition(id, params)
	else if (strcmp(method, c"textDocument/hover") == 0):
		lsp_handle_hover(id, params)
	else if (strcmp(method, c"textDocument/references") == 0):
		lsp_handle_references(id, params)
	else if (strcmp(method, c"textDocument/rename") == 0):
		lsp_handle_rename(id, params)
	else if (id != 0):
		char* message = strjoin(c"method not found: ", method)
		lsp_respond_error(id, -32601, message)
		free(message)
	# Unknown notifications (including $/ ones) are ignored.


# The binary lives in bin/, so when launched by a path ending in bin/
# hop to the parent — the repo root — so ./bin/wv2 resolves. Any other
# launch keeps the current directory.
void lsp_chdir_root():
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
	lsp_chdir_root()
	lsp_documents = new map[char*, char*]
	lsp_published = new map[char*, list[char*]]
	lsp_exit_requested = 0
	frame_reader* r = frame_reader_new(0)
	while (lsp_exit_requested == 0):
		int length = 0
		char* body = frame_read_message(r, &length)
		if (body == 0):
			break
		json_value* request = json_parse(body)
		free(body)
		if (request == 0):
			lsp_respond_error(0, -32700, c"parse error")
		else:
			lsp_handle(request)
			json_free(request)
	frame_reader_free(r)
	return 0
