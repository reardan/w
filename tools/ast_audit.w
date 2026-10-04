# Shared transformations for wast_audit. Neither entry point runs a compiler.
import tools.manifest_json
import lib.str


int ast_audit_prefix(char* text, char* prefix):
	int i = 0
	while (prefix[i] != 0):
		if (text[i] != prefix[i]): return 0
		i = i + 1
	return 1


int ast_audit_source(char* text):
	int n = strlen(text)
	return n >= 2 && strcmp(text + n - 2, c".w") == 0


char* ast_audit_find(char* text, char* needle):
	int i = 0
	while (text[i] != 0):
		if (ast_audit_prefix(text + i, needle)): return text + i
		i = i + 1
	return 0


# Deliberately recognize exact production bootstrap names, never a seed,
# wrapper, shell command or user executable that merely contains "wv2".
int ast_audit_compiler(char* path):
	return strcmp(path, c"bin/wv2") == 0 || strcmp(path, c"bin/wv3") == 0 || strcmp(path, c"bin/wv4") == 0 || strcmp(path, c"bin/wv5") == 0 || strcmp(path, c"bin/wv2_64") == 0 || strcmp(path, c"bin/wv3_64") == 0 || strcmp(path, c"bin/wv4_64") == 0 || strcmp(path, c"bin/wv5_64") == 0 || strcmp(path, c"bin/wv2_darwin") == 0 || strcmp(path, c"bin/wv3_darwin") == 0 || strcmp(path, c"bin/wv4_darwin") == 0 || strcmp(path, c"bin/wv5_darwin") == 0


# 0: other command; 1: eligible; 2: explicit AST mode; 3: query/help or
# no source. Append the flag so check's own option prefix is left intact.
int ast_audit_command_kind(json_value* cmd):
	if (cmd == 0 || cmd.type != json_type_array()): return 0
	if (json_array_length(cmd) == 0): return 0
	json_value* first = json_array_get(cmd, 0)
	if (first.type != json_type_string()): return 0
	if (ast_audit_compiler(first.string_value) == 0): return 0
	int source = 0
	int query = 0
	int explicit_mode = 0
	for i in range(1, json_array_length(cmd)):
		json_value* arg = json_array_get(cmd, i)
		if (arg.type != json_type_string()): return 3
		char* text = arg.string_value
		if (strcmp(text, c"-o") == 0 || strcmp(text, c"--import-root") == 0):
			i = i + 1
			continue
		if (text[0] != '-' && ast_audit_source(text)): source = 1
		if (ast_audit_prefix(text, c"--ast-")): explicit_mode = 1
		if (strcmp(text, c"deps") == 0 || strcmp(text, c"symbols") == 0 || strcmp(text, c"defhash") == 0 || strcmp(text, c"--help") == 0 || strcmp(text, c"-h") == 0 || strcmp(text, c"--version") == 0): query = 1
	if (explicit_mode): return 2
	if (query || source == 0): return 3
	return 1


# Mutates only selected cmd arrays. Report counts are about direct manifest
# steps, not targets, executed steps, expressions or nested driver launches.
json_value* ast_audit_manifest(json_value* root):
	if (root == 0 || root.type != json_type_object()): return 0
	json_value* targets = jfield_array(root, c"targets")
	if (targets == 0): return 0
	int changed = 0
	int explicit_mode = 0
	int queries = 0
	int other = 0
	json_value* selected = json_array()
	for i in range(json_array_length(targets)):
		json_value* target = json_array_get(targets, i)
		if (target.type != json_type_object()):
			json_free(selected)
			return 0
		json_value* steps = jfield_array(target, c"steps")
		if (steps == 0): continue
		for j in range(json_array_length(steps)):
			json_value* step = json_array_get(steps, j)
			if (step.type != json_type_object()):
				json_free(selected)
				return 0
			json_value* cmd = jfield_array(step, c"cmd")
			int kind = ast_audit_command_kind(cmd)
			if (kind == 1):
				json_array_push(cmd, json_string(c"--ast-full-expressions"))
				changed = changed + 1
				json_value* entry = json_object()
				char* name = jfield_string(target, c"name")
				if (name == 0): name = c""
				json_object_set(entry, c"target", json_string(name))
				json_object_set(entry, c"step", json_int(j))
				json_array_push(selected, entry)
			else if (kind == 2): explicit_mode = explicit_mode + 1
			else if (kind == 3): queries = queries + 1
			else: other = other + 1
	json_value* report = json_object()
	json_object_set(report, c"schema", json_int(1))
	json_object_set(report, c"changed_steps", json_int(changed))
	json_object_set(report, c"explicit_ast_steps", json_int(explicit_mode))
	json_object_set(report, c"query_or_sourceless_steps", json_int(queries))
	json_object_set(report, c"other_steps", json_int(other))
	json_object_set(report, c"selected", selected)
	json_object_set(report, c"scope", json_string(c"Direct production-compiler compile/check steps only; implicit imports inherit the flag. Nested compiler launches remain controlled by their test drivers. Seeds and explicit AST modes are unchanged."))
	return report


void ast_audit_count(json_value* counts, char* key):
	json_object_set(counts, key, json_int(jfield_int(counts, key, 0) + 1))


json_value* ast_audit_sorted_counts(json_value* counts, char* field):
	list[char*] keys = new list[char*]
	for char* key, json_value* value in counts.object_values:
		if (value != 0): keys.push(key)
	keys.sort()
	json_value* result = json_array()
	for char* key in keys:
		json_value* row = json_object()
		json_object_set(row, field, json_string(key))
		json_object_set(row, c"count", json_clone(json_object_get(counts, key)))
		json_array_push(result, row)
	keys.free()
	return result


# One log may contain several compiler invocations; counters are summed.
# Missing stats stay absent, and absence of fallbacks is not labeled success.
json_value* ast_audit_census(char* text):
	json_value* files = json_object()
	json_value* tokens = json_object()
	json_value* counters = json_object()
	int records = 0
	int invalid = 0
	int ignored = 0
	int start = 0
	int length = strlen(text)
	for end in range(length + 1):
		if (end < length && text[end] != '\n'): continue
		if (end == start):
			start = end + 1
			continue
		char* line = substring(text, start, end)
		start = end + 1
		int recognized = 0
		if (line[0] == '{'):
			json_value* record = json_parse(line)
			if (record != 0 && record.type == json_type_object()):
				json_value* marker = json_object_get(record, c"ast_fallback")
				if (marker != 0):
					recognized = 1
					char* file = jfield_string(record, c"file")
					char* token_text = jfield_string(record, c"token")
					if (marker.type != json_type_bool() || marker.int_value != 1 || file == 0 || token_text == 0 || jfield_int(record, c"line", 0) <= 0 || jfield_int(record, c"column", 0) <= 0): invalid = invalid + 1
					else:
						records = records + 1
						ast_audit_count(files, file)
						ast_audit_count(tokens, token_text)
			else if (ast_audit_find(line, c"ast_fallback") != 0):
				recognized = 1
				invalid = invalid + 1
			json_free(record)
		if (ast_audit_prefix(line, c"AST ") || ast_audit_prefix(line, c"Streaming ")):
			char* separator = ast_audit_find(line, c": ")
			if (separator != 0):
				char* label = substring(line, 0, separator - line)
				char* number = separator + 2
				int valid = number[0] != 0
				for i in range(strlen(number)):
					if (number[i] < '0' || number[i] > '9'): valid = 0
				if (valid):
					json_object_set(counters, label, json_int(jfield_int(counters, label, 0) + atoi(number)))
					# Counters are parser entry counts, not source percentages.
				else: invalid = invalid + 1
				recognized = 1
				free(label)
		if (recognized == 0): ignored = ignored + 1
		free(line)
	json_value* report = json_object()
	json_object_set(report, c"schema", json_int(1))
	json_object_set(report, c"fallback_records", json_int(records))
	json_object_set(report, c"invalid_records", json_int(invalid))
	json_object_set(report, c"ignored_lines", json_int(ignored))
	json_object_set(report, c"counters", ast_audit_sorted_counts(counters, c"counter"))
	json_object_set(report, c"by_file", ast_audit_sorted_counts(files, c"file"))
	json_object_set(report, c"by_token", ast_audit_sorted_counts(tokens, c"token"))
	json_object_set(report, c"scope", json_string(c"Parser-entry counts, including nested entries after fallback; not source coverage percentages. Log completeness and compiler exit status must be checked separately."))
	json_free(files)
	json_free(tokens)
	json_free(counters)
	return report
