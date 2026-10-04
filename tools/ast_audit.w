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
	if (ast_audit_prefix(path, c"./")): path = path + 2
	return strcmp(path, c"bin/wv2") == 0 || strcmp(path, c"bin/wv3") == 0 || strcmp(path, c"bin/wv4") == 0 || strcmp(path, c"bin/wv5") == 0 || strcmp(path, c"bin/wv2_64") == 0 || strcmp(path, c"bin/wv3_64") == 0 || strcmp(path, c"bin/wv4_64") == 0 || strcmp(path, c"bin/wv5_64") == 0 || strcmp(path, c"bin/wv2_darwin") == 0 || strcmp(path, c"bin/wv3_darwin") == 0 || strcmp(path, c"bin/wv4_darwin") == 0 || strcmp(path, c"bin/wv5_darwin") == 0


# Recognize env without interpreting shell text or unknown env options.
char* ast_audit_arg(json_value* cmd, int index):
	if (cmd == 0 || cmd.type != json_type_array()): return c""
	if (index < 0 || index >= json_array_length(cmd)): return c""
	json_value* arg = json_array_get(cmd, index)
	if (arg.type != json_type_string()): return c""
	return arg.string_value


int ast_audit_program_index(json_value* cmd):
	char* first = ast_audit_arg(cmd, 0)
	if (strcmp(first, c"env") != 0 && strcmp(first, c"/usr/bin/env") != 0 && strcmp(first, c"/bin/env") != 0): return 0
	int index = 1
	while (index < json_array_length(cmd)):
		char* arg = ast_audit_arg(cmd, index)
		if (strcmp(arg, c"--") == 0): return index + 1
		if (strcmp(arg, c"-u") == 0 || strcmp(arg, c"--unset") == 0): index = index + 2
		else if (strcmp(arg, c"-i") == 0 || strcmp(arg, c"--ignore-environment") == 0 || ast_audit_prefix(arg, c"--unset=")): index = index + 1
		else:
			int n = 0
			while ((arg[n] >= 'A' && arg[n] <= 'Z') || (arg[n] >= 'a' && arg[n] <= 'z') || arg[n] == '_' || (n > 0 && arg[n] >= '0' && arg[n] <= '9')): n = n + 1
			if (n == 0 || arg[n] != '='): return index
			index = index + 1
	return index


# 0: other command; 1: eligible; 2: explicit AST mode; 3: query/help or
# no source. Append the flag so check's own option prefix is left intact.
int ast_audit_command_kind(json_value* cmd):
	if (cmd == 0 || cmd.type != json_type_array()): return 0
	if (json_array_length(cmd) == 0): return 0
	int program = ast_audit_program_index(cmd)
	if (program >= json_array_length(cmd)): return 0
	json_value* first = json_array_get(cmd, program)
	if (first.type != json_type_string()): return 0
	if (ast_audit_compiler(first.string_value) == 0): return 0
	int source = 0
	int query = 0
	int explicit_mode = 0
	for i in range(program + 1, json_array_length(cmd)):
		json_value* arg = json_array_get(cmd, i)
		if (arg.type != json_type_string()): return 3
		char* text = arg.string_value
		if (strcmp(text, c"-o") == 0 || strcmp(text, c"--import-root") == 0):
			i = i + 1
			continue
		if (text[0] != '-' && ast_audit_source(text)): source = 1
		if (ast_audit_prefix(text, c"--ast-")): explicit_mode = 1
		if (strcmp(text, c"deps") == 0 || strcmp(text, c"symbols") == 0 || strcmp(text, c"defhash") == 0 || strcmp(text, c"tree") == 0 || strcmp(text, c"--help") == 0 || strcmp(text, c"-h") == 0 || strcmp(text, c"--version") == 0): query = 1
	if (explicit_mode): return 2
	if (query || source == 0): return 3
	return 1


# Mutates only selected cmd arrays. Report counts are about direct manifest
# steps, not targets, executed steps, expressions or nested driver launches.
json_value* ast_audit_manifest_mode(json_value* root, int required):
	if (root == 0 || root.type != json_type_object()): return 0
	json_value* targets = jfield_array(root, c"targets")
	if (targets == 0): return 0
	int required_steps = 0
	int expected_failures = 0
	int fixture_groups = 0
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
			int fixture = 0
			if (required && cmd != 0):
				int program = ast_audit_program_index(cmd)
				char* executable = ast_audit_arg(cmd, program)
				if ((strcmp(executable, c"bin/wfixture") == 0 || strcmp(executable, c"./bin/wfixture") == 0) && ast_audit_compiler(ast_audit_arg(cmd, program + 1))):
					json_value* rewritten = json_array()
					for k in range(json_array_length(cmd)):
						json_array_push(rewritten, json_clone(json_array_get(cmd, k)))
						if (k == program): json_array_push(rewritten, json_string(c"--ast-expressions"))
					json_object_set(step, c"cmd", rewritten)
					cmd = rewritten
					fixture = 1
					fixture_groups = fixture_groups + 1
			if (kind == 1 || fixture):
				if (fixture == 0):
					char* flag = c"--ast-full-expressions"
					if (required):
						if (jfield_flag(step, c"expect_fail") || jfield_int(step, c"expect_status", 0) != 0): expected_failures = expected_failures + 1
						else:
							flag = c"--ast-required"
							required_steps = required_steps + 1
					json_array_push(cmd, json_string(flag))
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
	json_object_set(report, c"required_steps", json_int(required_steps))
	json_object_set(report, c"expected_failure_steps", json_int(expected_failures))
	json_object_set(report, c"fixture_groups", json_int(fixture_groups))
	json_object_set(report, c"schema", json_int(1))
	json_object_set(report, c"changed_steps", json_int(changed))
	json_object_set(report, c"explicit_ast_steps", json_int(explicit_mode))
	json_object_set(report, c"query_or_sourceless_steps", json_int(queries))
	json_object_set(report, c"other_steps", json_int(other))
	json_object_set(report, c"selected", selected)
	json_object_set(report, c"scope", json_string(c"Production-compiler compile/check steps, including recognized env prefixes; required mode also gates diagnostic fixture groups; implicit imports inherit the flag. Nested compiler launches remain controlled by their test drivers. Seeds and explicit AST modes are unchanged."))
	return report


json_value* ast_audit_manifest(json_value* root):
	return ast_audit_manifest_mode(root, 0)


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


int ast_audit_known_counter(char* label):
	return strcmp(label, c"AST expressions") == 0 || strcmp(label, c"AST expression roots") == 0 || strcmp(label, c"Streaming expression roots") == 0 || strcmp(label, c"AST return statements") == 0 || strcmp(label, c"Streaming return statements") == 0 || strcmp(label, c"AST expression statements") == 0 || strcmp(label, c"Streaming expression statements") == 0 || strcmp(label, c"AST if headers") == 0 || strcmp(label, c"Streaming if headers") == 0 || strcmp(label, c"AST while headers") == 0 || strcmp(label, c"Streaming while headers") == 0 || strcmp(label, c"AST GPU captures") == 0 || strcmp(label, c"AST GPU header values") == 0 || strcmp(label, c"AST GPU launches") == 0 || strcmp(label, c"AST GPU loops") == 0 || strcmp(label, c"AST blocks") == 0 || strcmp(label, c"AST conditional branches") == 0 || strcmp(label, c"AST constant expressions") == 0 || strcmp(label, c"AST cursor loops") == 0 || strcmp(label, c"AST debugger statements") == 0 || strcmp(label, c"AST deferred expressions") == 0 || strcmp(label, c"AST enum values") == 0 || strcmp(label, c"AST extern functions") == 0 || strcmp(label, c"AST extern objects") == 0 || strcmp(label, c"AST functions") == 0 || strcmp(label, c"AST generators") == 0 || strcmp(label, c"AST global initializers") == 0 || strcmp(label, c"AST globals") == 0 || strcmp(label, c"AST goto/label statements") == 0 || strcmp(label, c"AST if regions") == 0 || strcmp(label, c"AST iteration values") == 0 || strcmp(label, c"AST kernel parameters") == 0 || strcmp(label, c"AST kernels") == 0 || strcmp(label, c"AST local declarations") == 0 || strcmp(label, c"AST range loops") == 0 || strcmp(label, c"AST raw-asm statements") == 0 || strcmp(label, c"AST scripts") == 0 || strcmp(label, c"AST simple statements") == 0 || strcmp(label, c"AST switch case values") == 0 || strcmp(label, c"AST switch regions") == 0 || strcmp(label, c"AST switch selectors") == 0 || strcmp(label, c"AST thread locals") == 0 || strcmp(label, c"AST while loops") == 0 || strcmp(label, c"AST yield statements") == 0


# Parse and add without signed wrap on either compiler host width. Return
# -1 for malformed input or either a single-value or accumulated overflow.
int ast_audit_counter_sum(char* text, int previous):
	if (text[0] == 0): return -1
	int value = 0
	int i = 0
	int limit = json_int_max()
	while (text[i] != 0):
		int digit = cast(int, text[i]) - '0'
		if (digit < 0 || digit > 9): return -1
		if (value > (limit - digit) / 10): return -1
		value = value * 10 + digit
		i = i + 1
	if (value > limit - previous): return -1
	return previous + value


# One log may contain several compiler invocations; counters are summed.
# Missing stats stay absent, and absence of fallbacks is not labeled success.
json_value* ast_audit_census(char* text):
	json_value* files = json_object()
	json_value* tokens = json_object()
	json_value* counters = json_object()
	int records = 0
	int invalid = 0
	int invalid_counters = 0
	int ignored = 0
	int start = 0
	int length = strlen(text)
	for end in range(length + 1):
		if (end < length && text[end] != '\n'): continue
		if (end == start):
			start = end + 1
			continue
		int stop = end
		if (stop > start && text[stop - 1] == '\r'): stop = stop - 1
		char* line = substring(text, start, stop)
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
			recognized = 1
			char* separator = ast_audit_find(line, c": ")
			int valid = 0
			if (separator != 0):
				char* label = substring(line, 0, separator - line)
				if (ast_audit_known_counter(label)):
					int total = ast_audit_counter_sum(separator + 2, jfield_int(counters, label, 0))
					if (total >= 0):
						json_object_set(counters, label, json_int(total))
						valid = 1
				free(label)
			if (valid == 0):
				invalid = invalid + 1
				invalid_counters = invalid_counters + 1
		if (recognized == 0): ignored = ignored + 1
		free(line)
	json_value* report = json_object()
	json_object_set(report, c"schema", json_int(1))
	json_object_set(report, c"fallback_records", json_int(records))
	json_object_set(report, c"invalid_records", json_int(invalid))
	json_object_set(report, c"invalid_counters", json_int(invalid_counters))
	json_object_set(report, c"ignored_lines", json_int(ignored))
	json_value* matching = json_null()
	if (invalid_counters == 0 && json_object_has(counters, c"Streaming expression roots")):
		json_free(matching)
		matching = json_bool(records == jfield_int(counters, c"Streaming expression roots", 0))
	json_object_set(report, c"records_match_streaming_roots", matching)
	json_object_set(report, c"counters", ast_audit_sorted_counts(counters, c"counter"))
	json_object_set(report, c"by_file", ast_audit_sorted_counts(files, c"file"))
	json_object_set(report, c"by_token", ast_audit_sorted_counts(tokens, c"token"))
	json_object_set(report, c"scope", json_string(c"Counters and fallback records are aggregated across invocations. Consistency is unknown without valid streaming-root stats and does not establish log completeness or compiler success. Counts are parser entries, including nested fallback entries, not source coverage percentages."))
	json_free(files)
	json_free(tokens)
	json_free(counters)
	return report
