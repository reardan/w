# Smoke-test the stdio LSP server: spawn bin/wlsp, run the initialize
# handshake, open the warning fixture and assert publishDiagnostics,
# resolve a definition in the symbols fixture, and shut down cleanly.
import lib.lib
import lib.assert
import lib.file
import lib.framing
import lib.process
import structures.string
import structures.json


process* lsp_test_server


void lsp_test_write(json_value* message):
	char* body = json_stringify(message)
	frame_write_cstr(lsp_test_server.stdin_fd, body)
	free(body)
	json_free(message)


json_value* lsp_test_read(frame_reader* r):
	int length = 0
	char* body = frame_read_message(r, &length)
	asserts(c"server closed stdout", body != 0)
	json_value* message = json_parse(body)
	free(body)
	asserts(c"server output is valid json", message != 0)
	return message


json_value* lsp_test_message(int id, char* method, json_value* params):
	json_value* message = json_object()
	json_object_set(message, c"jsonrpc", json_string(c"2.0"))
	if (id > 0):
		json_object_set(message, c"id", json_int(id))
	json_object_set(message, c"method", json_string(method))
	if (params != 0):
		json_object_set(message, c"params", params)
	return message


# Sends a request and reads until its response arrives, skipping any
# server notifications in between. Returns the whole response message.
json_value* lsp_test_request(frame_reader* r, int id, char* method, json_value* params):
	lsp_test_write(lsp_test_message(id, method, params))
	while (1):
		json_value* message = lsp_test_read(r)
		json_value* message_id = json_object_get(message, c"id")
		if (message_id != 0):
			if (message_id.type == json_type_int()):
				if (message_id.int_value == id):
					asserts(c"response carries no error", json_object_has(message, c"error") == 0)
					return message
		json_free(message)
	return 0


# Reads until a publishDiagnostics notification for uri arrives and
# returns the whole message (params still attached).
json_value* lsp_test_wait_diagnostics(frame_reader* r, char* uri):
	while (1):
		json_value* message = lsp_test_read(r)
		json_value* method = json_object_get(message, c"method")
		if (method != 0):
			if (strcmp(method.string_value, c"textDocument/publishDiagnostics") == 0):
				json_value* params = json_object_get(message, c"params")
				json_value* message_uri = json_object_get(params, c"uri")
				if (strcmp(message_uri.string_value, uri) == 0):
					return message
		json_free(message)
	return 0


# file:// URI for a path relative to the current directory.
char* lsp_test_uri(char* relative):
	char* cwd = malloc(4096)
	getcwd(cwd, 4096)
	string_builder* out = string_from(c"file://")
	string_append(out, cwd)
	string_append(out, c"/")
	string_append(out, relative)
	free(cwd)
	char* uri = out.data
	free(out)
	return uri


json_value* lsp_test_text_document(char* uri):
	json_value* text_document = json_object()
	json_object_set(text_document, c"uri", json_string(uri))
	return text_document


int main(int argc, int argv):
	char** server_argv = strv_new(1)
	strv_set(server_argv, 0, c"./bin/wlsp")
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_pipe()
	opts.stdout_mode = process_pipe()
	opts.stderr_mode = process_inherit()
	lsp_test_server = process_spawn(c"./bin/wlsp", server_argv, opts)
	free(opts)
	free(cast(void*, server_argv))
	asserts(c"server spawned", lsp_test_server != 0)
	frame_reader* r = frame_reader_new(lsp_test_server.stdout_fd)

	# initialize: capabilities and server identity
	json_value* init_params = json_object()
	json_object_set(init_params, c"processId", json_null())
	json_object_set(init_params, c"capabilities", json_object())
	json_value* init = lsp_test_request(r, 1, c"initialize", init_params)
	json_value* init_result = json_object_get(init, c"result")
	json_value* server_info = json_object_get(init_result, c"serverInfo")
	json_value* server_name = json_object_get(server_info, c"name")
	assert_strings_equal(c"w-lsp", server_name.string_value)
	json_value* capabilities = json_object_get(init_result, c"capabilities")
	json_value* definition_provider = json_object_get(capabilities, c"definitionProvider")
	assert_equal(1, definition_provider.int_value)
	json_free(init)

	lsp_test_write(lsp_test_message(0, c"initialized", json_object()))

	# didOpen of the warning fixture publishes its check diagnostics
	char* warning_uri = lsp_test_uri(c"tests/warning_fixture.w")
	json_value* open_params = json_object()
	json_object_set(open_params, c"textDocument", lsp_test_text_document(warning_uri))
	lsp_test_write(lsp_test_message(0, c"textDocument/didOpen", open_params))
	json_value* published = lsp_test_wait_diagnostics(r, warning_uri)
	json_value* diagnostics = json_object_get(json_object_get(published, c"params"), c"diagnostics")
	asserts(c"warning fixture has diagnostics", json_array_length(diagnostics) > 0)
	json_value* first = json_array_get(diagnostics, 0)
	json_value* severity = json_object_get(first, c"severity")
	assert_equal(2, severity.int_value)
	json_value* message = json_object_get(first, c"message")
	assert_strings_equal(c"assignment type mismatch: expected 'char*', got 'int*'", message.string_value)
	json_value* range = json_object_get(first, c"range")
	json_value* start = json_object_get(range, c"start")
	json_value* start_line = json_object_get(start, c"line")
	asserts(c"diagnostic has a line", start_line.int_value > 0)
	json_free(published)

	# didClose clears the previously published diagnostics
	json_value* close_params = json_object()
	json_object_set(close_params, c"textDocument", lsp_test_text_document(warning_uri))
	lsp_test_write(lsp_test_message(0, c"textDocument/didClose", close_params))
	json_value* cleared = lsp_test_wait_diagnostics(r, warning_uri)
	json_value* cleared_diagnostics = json_object_get(json_object_get(cleared, c"params"), c"diagnostics")
	assert_equal(0, json_array_length(cleared_diagnostics))
	json_free(cleared)

	# didOpen of a clean file (text included) publishes an empty set
	char* symbols_uri = lsp_test_uri(c"tests/symbols_fixture.w")
	char* symbols_text = file_read_text(c"tests/symbols_fixture.w")
	asserts(c"symbols fixture readable", symbols_text != 0)
	json_value* symbols_document = lsp_test_text_document(symbols_uri)
	json_object_set(symbols_document, c"text", json_string(symbols_text))
	json_value* symbols_open = json_object()
	json_object_set(symbols_open, c"textDocument", symbols_document)
	lsp_test_write(lsp_test_message(0, c"textDocument/didOpen", symbols_open))
	json_value* clean = lsp_test_wait_diagnostics(r, symbols_uri)
	json_value* clean_diagnostics = json_object_get(json_object_get(clean, c"params"), c"diagnostics")
	assert_equal(0, json_array_length(clean_diagnostics))
	json_free(clean)
	free(symbols_text)

	# definition on the sym_fixture_add call site (0-based 14:10) lands
	# on its declaration at 1-based 11:5 -> 0-based 10:4
	json_value* definition_params = json_object()
	json_object_set(definition_params, c"textDocument", lsp_test_text_document(symbols_uri))
	json_value* position = json_object()
	json_object_set(position, c"line", json_int(14))
	json_object_set(position, c"character", json_int(10))
	json_object_set(definition_params, c"position", position)
	json_value* definition = lsp_test_request(r, 2, c"textDocument/definition", definition_params)
	json_value* locations = json_object_get(definition, c"result")
	asserts(c"definition returns locations", locations.type == json_type_array())
	assert_equal(1, json_array_length(locations))
	json_value* location = json_array_get(locations, 0)
	json_value* location_uri = json_object_get(location, c"uri")
	assert_strings_equal(symbols_uri, location_uri.string_value)
	json_value* location_start = json_object_get(json_object_get(location, c"range"), c"start")
	assert_equal(10, json_object_get(location_start, c"line").int_value)
	assert_equal(4, json_object_get(location_start, c"character").int_value)
	json_free(definition)

	# definition on a non-identifier position returns null
	json_value* miss_params = json_object()
	json_object_set(miss_params, c"textDocument", lsp_test_text_document(symbols_uri))
	json_value* miss_position = json_object()
	json_object_set(miss_position, c"line", json_int(12))
	json_object_set(miss_position, c"character", json_int(0))
	json_object_set(miss_params, c"position", miss_position)
	json_value* miss = lsp_test_request(r, 3, c"textDocument/definition", miss_params)
	json_value* miss_result = json_object_get(miss, c"result")
	assert_equal(json_type_null(), miss_result.type)
	json_free(miss)

	# hover on a call site (line 11, 1-based) reports the callee's kind/type
	char* index_uri = lsp_test_uri(c"tests/index_fixture.w")
	json_value* hover_params = json_object()
	json_object_set(hover_params, c"textDocument", lsp_test_text_document(index_uri))
	json_value* hover_position = json_object()
	json_object_set(hover_position, c"line", json_int(10))
	json_object_set(hover_position, c"character", json_int(10))
	json_object_set(hover_params, c"position", hover_position)
	json_value* hover = lsp_test_request(r, 5, c"textDocument/hover", hover_params)
	json_value* hover_result = json_object_get(hover, c"result")
	json_value* hover_value = json_object_get(json_object_get(hover_result, c"contents"), c"value")
	assert_strings_equal(c"function index_fixture_helper: int", hover_value.string_value)
	json_free(hover)

	# references on the same identifier: declaration + two call sites
	json_value* refs_params = json_object()
	json_object_set(refs_params, c"textDocument", lsp_test_text_document(index_uri))
	json_value* refs_position = json_object()
	json_object_set(refs_position, c"line", json_int(10))
	json_object_set(refs_position, c"character", json_int(10))
	json_object_set(refs_params, c"position", refs_position)
	json_value* refs_context = json_object()
	json_object_set(refs_context, c"includeDeclaration", json_bool(1))
	json_object_set(refs_params, c"context", refs_context)
	json_value* refs = lsp_test_request(r, 6, c"textDocument/references", refs_params)
	json_value* refs_locations = json_object_get(refs, c"result")
	assert_equal(3, json_array_length(refs_locations))
	json_free(refs)

	# excluding the declaration drops to the two call sites
	json_value* refs_no_decl_params = json_object()
	json_object_set(refs_no_decl_params, c"textDocument", lsp_test_text_document(index_uri))
	json_value* refs_no_decl_position = json_object()
	json_object_set(refs_no_decl_position, c"line", json_int(10))
	json_object_set(refs_no_decl_position, c"character", json_int(10))
	json_object_set(refs_no_decl_params, c"position", refs_no_decl_position)
	json_value* refs_no_decl_context = json_object()
	json_object_set(refs_no_decl_context, c"includeDeclaration", json_bool(0))
	json_object_set(refs_no_decl_params, c"context", refs_no_decl_context)
	json_value* refs_no_decl = lsp_test_request(r, 7, c"textDocument/references", refs_no_decl_params)
	json_value* refs_no_decl_locations = json_object_get(refs_no_decl, c"result")
	assert_equal(2, json_array_length(refs_no_decl_locations))
	json_free(refs_no_decl)

	# rename produces a WorkspaceEdit with one TextEdit per occurrence
	json_value* rename_params = json_object()
	json_object_set(rename_params, c"textDocument", lsp_test_text_document(index_uri))
	json_value* rename_position = json_object()
	json_object_set(rename_position, c"line", json_int(10))
	json_object_set(rename_position, c"character", json_int(10))
	json_object_set(rename_params, c"position", rename_position)
	json_object_set(rename_params, c"newName", json_string(c"index_fixture_helper_renamed"))
	json_value* rename = lsp_test_request(r, 8, c"textDocument/rename", rename_params)
	json_value* workspace_edit = json_object_get(rename, c"result")
	json_value* changes = json_object_get(workspace_edit, c"changes")
	json_value* index_edits = json_object_get(changes, index_uri)
	asserts(c"rename edits the fixture file", index_edits != 0)
	assert_equal(3, json_array_length(index_edits))
	json_value* first_edit = json_array_get(index_edits, 0)
	json_value* first_edit_text = json_object_get(first_edit, c"newText")
	assert_strings_equal(c"index_fixture_helper_renamed", first_edit_text.string_value)
	json_free(rename)
	free(index_uri)

	# shutdown answers null; exit ends the process
	json_value* shutdown = lsp_test_request(r, 4, c"shutdown", 0)
	json_value* shutdown_result = json_object_get(shutdown, c"result")
	assert_equal(json_type_null(), shutdown_result.type)
	json_free(shutdown)
	lsp_test_write(lsp_test_message(0, c"exit", 0))

	int status = process_wait_or_kill(lsp_test_server, 5000)
	assert_equal(0, status)
	process_free(lsp_test_server)
	frame_reader_free(r)
	free(warning_uri)
	free(symbols_uri)
	println2(c"lsp test OK")
	return 0
