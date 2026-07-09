# Cursor postToolUse hook: after an agent edits a W source file, run
# './bin/wv2 check --json' on it and emit {"additional_context": ...} so
# the agent sees compiler diagnostics immediately, without being asked.
#
# Wired up by .cursor/hooks.json via .cursor/hooks/check_after_edit.sh,
# which bootstraps bin/wv2 and this binary (bin/whook) and pipes the hook
# payload through. Output is one JSON object on stdout: {} when there is
# nothing to report, or {"additional_context": "<diagnostics>"}.
#
# The payload's tool_input field names are tool-specific and not
# exhaustively documented, so the hook scans tool_input's string members
# for a path ending in '.w' instead of hard-coding one key. It also
# accepts afterFileEdit-style payloads that carry file_path at top level.
import lib.lib
import lib.env
import lib.path
import lib.process
import lib.stream
import structures.string
import structures.json


int whook_check_timeout_ms():
	return 30000


# Cap the diagnostics block so a pathological file cannot flood the
# agent's context.
int whook_max_diagnostics_length():
	return 8000


int whook_lower(int c):
	if ((c >= 'A') & (c <= 'Z')):
		return c + 32
	return c


int whook_contains_nocase(char* text, char* needle):
	if (text == 0):
		return 0
	int i = 0
	while (text[i]):
		int j = 0
		while (needle[j]):
			if (whook_lower(text[i + j]) != whook_lower(needle[j])):
				break
			j = j + 1
		if (needle[j] == 0):
			return 1
		if (text[i + j] == 0):
			return 0
		i = i + 1
	return 0


# Tool names are not exhaustively documented (Write, StrReplace, ...);
# treat any tool whose name mentions writing, editing or replacing as an
# edit so reads and searches never trigger a check.
int whook_is_edit_tool(char* name):
	if (name == 0):
		return 0
	if (whook_contains_nocase(name, c"write")):
		return 1
	if (whook_contains_nocase(name, c"edit")):
		return 1
	if (whook_contains_nocase(name, c"replace")):
		return 1
	return 0


# Hook payload paths are usually absolute; strip the project root (the
# hook runs from the repo root) so the compiler-tree mapping below works.
char* whook_relative(char* file_path):
	char* root = env_get(c"CURSOR_PROJECT_DIR")
	if (root == 0):
		return file_path
	int length = strlen(root)
	if (length == 0):
		return file_path
	if (starts_with(file_path, root) == 0):
		return file_path
	if (file_path[length] == '/'):
		return file_path + length + 1
	return file_path


# Modules under the compiler tree do not compile standalone (grammar
# rules reference symbols from sibling modules), so check the whole
# compiler through its entry point instead. Same idea for the debugger.
char* whook_check_target(char* file_path):
	if (strcmp(file_path, c"w.w") == 0):
		return c"w.w"
	if (strcmp(file_path, c"grammar.w") == 0):
		return c"w.w"
	if (strcmp(file_path, c"codegen.w") == 0):
		return c"w.w"
	if (starts_with(file_path, c"compiler/")):
		return c"w.w"
	if (starts_with(file_path, c"grammar/")):
		return c"w.w"
	if (starts_with(file_path, c"code_generator/")):
		return c"w.w"
	if (starts_with(file_path, c"debugger/")):
		return c"debugger/debugger.w"
	return file_path


# Warning/error fixtures trip diagnostics on purpose; checking them after
# every edit would only produce noise.
int whook_should_skip(char* file_path):
	if (ends_with(file_path, c".w") == 0):
		return 1
	if (whook_contains_nocase(file_path, c"fixture")):
		return 1
	return 0


char* whook_string_member(json_value* object, char* key):
	if (object == 0):
		return 0
	if (object.type != json_type_object()):
		return 0
	json_value* value = json_object_get(object, key)
	if (value == 0):
		return 0
	if (value.type != json_type_string()):
		return 0
	return value.string_value


# The edited path: afterFileEdit payloads carry file_path at top level;
# postToolUse payloads carry the tool's own input object, whose string
# members are scanned for the first existing '.w' path.
char* whook_edited_path(json_value* payload):
	char* direct = whook_string_member(payload, c"file_path")
	if (direct != 0):
		if (ends_with(direct, c".w")):
			return direct
	json_value* input = json_object_get(payload, c"tool_input")
	if (input == 0):
		return 0
	if (input.type != json_type_object()):
		return 0
	for char* key in input.object_values:
		char* value = whook_string_member(input, key)
		if (value != 0):
			if (ends_with(value, c".w")):
				if (path_exists(whook_relative(value))):
					return value
	return 0


# Appends up to limit chars of text (all non-empty lines joined by
# newlines), with a truncation note when the cap is hit.
void whook_append_capped(string_builder* out, char* text, int limit):
	int i = 0
	int written = 0
	while (text[i]):
		if (written >= limit):
			string_append(out, c"\n... truncated ...")
			return
		if (text[i] != '\r'):
			string_append_char(out, text[i])
			written = written + 1
		i = i + 1


int whook_count_lines(char* text):
	int count = 0
	int saw_char = 0
	int i = 0
	while (text[i]):
		if (text[i] == '\n'):
			if (saw_char):
				count = count + 1
			saw_char = 0
		else if (text[i] != '\r'):
			saw_char = 1
		i = i + 1
	if (saw_char):
		count = count + 1
	return count


void whook_emit(char* text):
	wstream* out = stdout_writer()
	stream_write_cstr(out, text)
	stream_write_cstr(out, c"\n")
	stream_flush(out)


void whook_emit_empty():
	whook_emit(c"{}")


void whook_emit_context(string_builder* message):
	json_value* response = json_object()
	json_object_set(response, c"additional_context", json_string(message.data))
	char* text = json_stringify(response)
	whook_emit(text)
	free(text)
	json_free(response)


int main(int argc, int argv):
	wstream* in = stdin_reader()
	string_builder* body = string_new()
	stream_read_all(in, body)
	json_value* payload = json_parse(body.data)
	string_free(body)
	if (payload == 0):
		whook_emit_empty()
		return 0
	if (payload.type != json_type_object()):
		whook_emit_empty()
		return 0

	char* event = whook_string_member(payload, c"hook_event_name")
	int is_file_edit_event = 0
	if (event != 0):
		if (strcmp(event, c"afterFileEdit") == 0):
			is_file_edit_event = 1
	if (is_file_edit_event == 0):
		if (whook_is_edit_tool(whook_string_member(payload, c"tool_name")) == 0):
			whook_emit_empty()
			return 0

	char* edited = whook_edited_path(payload)
	if (edited == 0):
		whook_emit_empty()
		return 0
	char* file_path = whook_relative(edited)
	if (whook_should_skip(file_path)):
		whook_emit_empty()
		return 0
	if (path_exists(file_path) == 0):
		whook_emit_empty()
		return 0
	char* target = whook_check_target(file_path)

	char** check_argv = strv_new(4)
	strv_set(check_argv, 0, c"./bin/wv2")
	strv_set(check_argv, 1, c"check")
	strv_set(check_argv, 2, c"--json")
	strv_set(check_argv, 3, target)
	process_result* result = process_run(c"./bin/wv2", check_argv, 0, 0, whook_check_timeout_ms())
	free(cast(void*, check_argv))
	if (result == 0):
		whook_emit_empty()
		return 0

	int diagnostics = whook_count_lines(result.stdout_text)
	if ((diagnostics == 0) & (result.status == 0)):
		process_result_free(result)
		whook_emit_empty()
		return 0

	string_builder* message = string_new()
	string_append(message, c"Automatic W toolchain hook (.cursor/hooks.json): './bin/wv2 check --json ")
	string_append(message, target)
	string_append(message, c"' after the edit to ")
	string_append(message, file_path)
	if (strcmp(target, file_path) != 0):
		string_append(message, c" (checked through its entry point; the module does not compile standalone)")
	if (diagnostics > 0):
		string_append(message, c" reported ")
		string_append_int(message, diagnostics)
		string_append(message, c" diagnostic(s):\n")
		whook_append_capped(message, result.stdout_text, whook_max_diagnostics_length())
	else:
		string_append(message, c" failed (exit ")
		string_append_int(message, result.status)
		string_append(message, c"), stderr:\n")
		whook_append_capped(message, result.stderr_text, whook_max_diagnostics_length())
	string_append(message, c"\nFix warnings as well as errors: the self-host build stages compile with --strict, so stray warnings fail './wbuild build' (and 'make build'). Re-run './bin/wv2 check --json <file>' after fixing.")
	whook_emit_context(message)
	string_free(message)
	process_result_free(result)
	return 0
