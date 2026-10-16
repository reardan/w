# Stable, additive diagnostic records. Human messages are not classification keys.
import libs.extras.grammars.antlr_to_pg.types
import structures.json
import lib.utf8

json_value* g_at_audit_findings

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
