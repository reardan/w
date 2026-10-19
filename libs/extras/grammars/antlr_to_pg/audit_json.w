# Stable, additive diagnostic records. Human messages are not classification keys.
import libs.extras.grammars.antlr_to_pg.types
import structures.json
import lib.utf8

json_value* g_at_audit_findings
map[char*, json_value*] g_at_normalization_guards
map[char*, json_value*] g_at_lr_source_details
map[char*, json_value*] g_at_lr_remaining_details

# Record the actual first guard reached by each attempted normalizer. These
# describe an implementation refusal, not a proof of a recursive call cycle.
int at_normalization_guard(at_rule* rule, char* normalizer, int alternative, char* reason_code):
	if (g_at_normalization_guards == 0): g_at_normalization_guards = new map[char*, json_value*]
	json_value* guards = g_at_normalization_guards.get(rule.name, 0)
	if (guards == 0):
		guards = json_array()
		g_at_normalization_guards[rule.name] = guards
	json_value* guard = json_object()
	json_object_set(guard, c"normalizer", json_string(normalizer))
	json_object_set(guard, c"reason_code", json_string(reason_code))
	json_object_set(guard, c"source_alternative", json_int(alternative))
	json_array_push(guards, guard)
	return 0

void at_finding(char* code, char* stage, char* feature, char* classification, char* filename, int line, int column, char* rule_name, char* reason):
	if (g_at_audit_findings == 0): g_at_audit_findings = json_array()
	json_value* finding = json_object()
	json_object_set(finding, c"code", json_string(code))
	json_object_set(finding, c"stage", json_string(stage))
	json_object_set(finding, c"feature", json_string(feature))
	json_object_set(finding, c"classification", json_string(classification))
	json_object_set(finding, c"file", json_string(filename))
	json_object_set(finding, c"line", json_int(line))
	json_object_set(finding, c"column", json_int(column))
	json_object_set(finding, c"rule", json_string(rule_name))
	json_object_set(finding, c"reason", json_string(reason))
	if (strcmp(code, c"AT_LEFT_RECURSION") == 0):
		json_value* details = json_object()
		json_object_set(details, c"reason_code", json_string(c"remaining_nullable_prefix_cycle"))
		json_value* guards = 0
		if (g_at_normalization_guards != 0): guards = g_at_normalization_guards.get(rule_name, 0)
		if (guards != 0): json_object_set(details, c"normalization_guards", json_clone(guards))
		else: json_object_set(details, c"normalization_guards", json_array())
		if ((g_at_lr_source_details != 0) && (rule_name in g_at_lr_source_details)):
			json_object_set(details, c"source", json_clone(g_at_lr_source_details[rule_name]))
		else if ((g_at_lr_source_details != 0) && (c"" in g_at_lr_source_details)):
			json_object_set(details, c"source", json_clone(g_at_lr_source_details[c""]))
		if ((g_at_lr_remaining_details != 0) && (rule_name in g_at_lr_remaining_details)):
			json_object_set(details, c"remaining_graph", json_clone(g_at_lr_remaining_details[rule_name]))
		else if ((g_at_lr_remaining_details != 0) && (c"" in g_at_lr_remaining_details)):
			json_object_set(details, c"remaining_graph", json_clone(g_at_lr_remaining_details[c""]))
		json_object_set(finding, c"details", details)
	json_array_push(g_at_audit_findings, finding)

int at_write_audit_json(char* path):
	if (path == 0): return 1
	if (g_at_audit_findings == 0): g_at_audit_findings = json_array()
	json_value* document = json_object()
	json_object_set(document, c"schema_version", json_int(1))
	json_object_set(document, c"findings", json_clone(g_at_audit_findings))
	char* content = json_stringify(document)
	int ok = file_write_text(path, content)
	free(content)
	json_free(document)
	if (ok == 0): println2(cstr(f"antlr_to_pg: could not write {path}"))
	return ok


void at_lowering_finding(char* rule_name, char* code, char* feature, char* reason):
	char* filename = c"<grammar>"
	int line = 1
	int column = 1
	if (g_at_source_rules != 0):
		for at_rule* rule in g_at_source_rules:
			if ((strcmp(rule.name, rule_name) == 0) && (rule.first != 0)):
				filename = rule.first.filename
				line = rule.first.line
				column = rule.first.column
	at_finding(code, c"lower", feature, c"unsupported", filename, line, column, rule_name, reason)
