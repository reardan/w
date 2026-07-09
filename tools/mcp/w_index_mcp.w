# Stdio MCP server exposing the semantic index (tools/index/w_index.w) as
# agent tools: find_symbol, find_references, get_type, get_struct_fields,
# imports_for, callers, callees, changed_file_test_targets. Shells out to
# bin/windex and bin/wtest exactly like w-toolchain-mcp shells to bin/wv2;
# see docs/projects/semantic_index.md for the index's contract and known
# gaps (textual reference finding, indentation-approximated call spans).
# Protocol plumbing lives in tools/mcp/mcp_server.w, shared with
# w-toolchain-mcp and w-debug-mcp.
#
# Build and register (see .cursor/mcp.json):
#   ./wbuild wimcp && ./bin/wimcp
import lib.lib
import lib.args
import structures.string
import structures.json
import tools.mcp.mcp_server


int imcp_default_timeout_ms():
	return 60000


int imcp_ensure_windex():
	return mcp_ensure_built(c"bin/windex", c"windex", 180000)


int imcp_ensure_wtest():
	return mcp_ensure_built(c"bin/wtest", c"wtest", 180000)


# Non-empty list of entry files from args.files, or 0 (with mcp_error
# set) when missing/empty/non-string.
list[char*] imcp_arg_files(json_value* args):
	json_value* files = mcp_arg_array(args, c"files")
	if (files == 0):
		mcp_fail(c"files must be a non-empty array")
		return 0
	if (json_array_length(files) == 0):
		mcp_fail(c"files must be a non-empty array")
		return 0
	list[char*] result = new list[char*]
	int i = 0
	while (i < json_array_length(files)):
		json_value* file = json_array_get(files, i)
		if (file.type != json_type_string()):
			mcp_fail(c"files entries must be strings")
			return 0
		result.push(file.string_value)
		i = i + 1
	return result


# Runs './bin/windex <subcommand> <name> <files...>' and returns
# {exit_code, stdout, stderr, records}, or 0 (with mcp_error set) on
# failure to spawn/build or malformed output.
json_value* imcp_run_windex(char* subcommand, char* name, list[char*] files):
	if (imcp_ensure_windex() == 0):
		return 0
	list[char*] words = new list[char*]
	words.push(c"./bin/windex")
	words.push(subcommand)
	words.push(name)
	int i = 0
	while (i < files.length):
		words.push(files[i])
		i = i + 1
	json_value* result = mcp_run_cmd(words, 0, imcp_default_timeout_ms())
	if (result == 0):
		return 0
	json_value* stdout_value = json_object_get(result, c"stdout")
	json_value* records = mcp_parse_ndjson(stdout_value.string_value)
	if (records == 0):
		json_free(result)
		return 0
	json_object_set(result, c"records", records)
	return result


/* tool handlers */


json_value* imcp_named_tool(char* subcommand, json_value* args):
	char* name = mcp_arg_string(args, c"name")
	if (name == 0):
		mcp_fail(c"name is required")
		return 0
	list[char*] files = imcp_arg_files(args)
	if (files == 0):
		return 0
	return imcp_run_windex(subcommand, name, files)


json_value* imcp_tool_find_symbol(json_value* args):
	return imcp_named_tool(c"symbol", args)


json_value* imcp_tool_find_references(json_value* args):
	return imcp_named_tool(c"references", args)


json_value* imcp_tool_get_type(json_value* args):
	return imcp_named_tool(c"type", args)


json_value* imcp_tool_get_struct_fields(json_value* args):
	return imcp_named_tool(c"struct", args)


json_value* imcp_tool_callers(json_value* args):
	return imcp_named_tool(c"callers", args)


json_value* imcp_tool_callees(json_value* args):
	return imcp_named_tool(c"callees", args)


json_value* imcp_tool_imports_for(json_value* args):
	if (imcp_ensure_windex() == 0):
		return 0
	char* file = mcp_arg_string(args, c"file")
	if (file == 0):
		mcp_fail(c"file is required")
		return 0
	list[char*] words = new list[char*]
	words.push(c"./bin/windex")
	words.push(c"imports")
	words.push(file)
	json_value* result = mcp_run_cmd(words, 0, imcp_default_timeout_ms())
	if (result == 0):
		return 0
	json_value* stdout_value = json_object_get(result, c"stdout")
	json_value* records = mcp_parse_ndjson(stdout_value.string_value)
	if (records == 0):
		json_free(result)
		return 0
	json_object_set(result, c"records", records)
	return result


json_value* imcp_tool_changed_file_test_targets(json_value* args):
	if (imcp_ensure_wtest() == 0):
		return 0
	list[char*] words = new list[char*]
	words.push(c"./bin/wtest")
	words.push(c"changed")
	json_value* files = mcp_arg_array(args, c"files")
	if (files != 0):
		int i = 0
		while (i < json_array_length(files)):
			json_value* file = json_array_get(files, i)
			if (file.type != json_type_string()):
				mcp_fail(c"files entries must be strings")
				return 0
			words.push(file.string_value)
			i = i + 1
	json_value* result = mcp_run_cmd(words, 0, imcp_default_timeout_ms())
	if (result == 0):
		return 0
	json_value* targets = json_array()
	json_value* stdout_value = json_object_get(result, c"stdout")
	char* text = stdout_value.string_value
	string_builder* line = string_new()
	int i = 0
	while (1):
		int c = text[i]
		if ((c == '\n') | (c == 0)):
			if (line.length > 0):
				json_array_push(targets, json_string(line.data))
			string_clear(line)
			if (c == 0):
				break
		else if (c != '\r'):
			string_append_char(line, c)
		i = i + 1
	string_free(line)
	json_object_set(result, c"targets", targets)
	return result


json_value* imcp_call_tool(char* name, json_value* args):
	if (strcmp(name, c"find_symbol") == 0):
		return imcp_tool_find_symbol(args)
	if (strcmp(name, c"find_references") == 0):
		return imcp_tool_find_references(args)
	if (strcmp(name, c"get_type") == 0):
		return imcp_tool_get_type(args)
	if (strcmp(name, c"get_struct_fields") == 0):
		return imcp_tool_get_struct_fields(args)
	if (strcmp(name, c"imports_for") == 0):
		return imcp_tool_imports_for(args)
	if (strcmp(name, c"callers") == 0):
		return imcp_tool_callers(args)
	if (strcmp(name, c"callees") == 0):
		return imcp_tool_callees(args)
	if (strcmp(name, c"changed_file_test_targets") == 0):
		return imcp_tool_changed_file_test_targets(args)
	return 0


int imcp_tool_known(char* name):
	if (strcmp(name, c"find_symbol") == 0):
		return 1
	if (strcmp(name, c"find_references") == 0):
		return 1
	if (strcmp(name, c"get_type") == 0):
		return 1
	if (strcmp(name, c"get_struct_fields") == 0):
		return 1
	if (strcmp(name, c"imports_for") == 0):
		return 1
	if (strcmp(name, c"callers") == 0):
		return 1
	if (strcmp(name, c"callees") == 0):
		return 1
	if (strcmp(name, c"changed_file_test_targets") == 0):
		return 1
	return 0


/* tools/list schemas */


json_value* imcp_name_files_properties():
	json_value* properties = json_object()
	json_object_set(properties, c"name", mcp_string_property())
	json_object_set(properties, c"files", mcp_string_array_property())
	return properties


json_value* imcp_tool_schemas():
	json_value* tools = json_array()

	char* find_symbol_desc = c"Declaration(s) of 'name' reachable from 'files' via wv2 symbols --json"
	json_array_push(tools, mcp_tool_schema(c"find_symbol", find_symbol_desc, imcp_name_files_properties()))
	char* find_references_desc = c"Every textual occurrence of 'name' across the files 'files' compiles in, with is_declaration flagged"
	json_array_push(tools, mcp_tool_schema(c"find_references", find_references_desc, imcp_name_files_properties()))
	char* get_type_desc = c"Declared type/kind of 'name' (same data as find_symbol, kept separate for query intent)"
	json_array_push(tools, mcp_tool_schema(c"get_type", get_type_desc, imcp_name_files_properties()))
	char* get_struct_fields_desc = c"Field name/type/offset for the struct or union named 'name'"
	json_array_push(tools, mcp_tool_schema(c"get_struct_fields", get_struct_fields_desc, imcp_name_files_properties()))
	char* callers_desc = c"Functions with a call site to 'name', approximated from indentation-based function spans"
	json_array_push(tools, mcp_tool_schema(c"callers", callers_desc, imcp_name_files_properties()))
	char* callees_desc = c"Functions called from within 'name', approximated from indentation-based function spans"
	json_array_push(tools, mcp_tool_schema(c"callees", callees_desc, imcp_name_files_properties()))

	json_value* imports_properties = json_object()
	json_object_set(imports_properties, c"file", mcp_string_property())
	char* imports_for_desc = c"Import statements in 'file' (module path, alias, line), parsed textually"
	json_array_push(tools, mcp_tool_schema(c"imports_for", imports_for_desc, imports_properties))

	json_value* changed_properties = json_object()
	json_object_set(changed_properties, c"files", mcp_string_array_property())
	char* changed_desc = c"Map changed files to focused test targets (delegates to bin/wtest changed)"
	json_array_push(tools, mcp_tool_schema(c"changed_file_test_targets", changed_desc, changed_properties))

	return tools


int main(int argc, int argv):
	args_init(argc, argv)
	mcp_chdir_root()
	mcp_server_init(c"w-index", c"0.1.0", imcp_tool_known, imcp_call_tool, imcp_tool_schemas)
	return mcp_serve()
