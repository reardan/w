# wbuild: binary=antlr_audit_driver
import tools.host_tools
import lib.str

json_value* aa_finding(json_value* findings, char* code, char* owner = 0):
	for json_value* finding in findings.array_values:
		if (strcmp(ht_text(finding, c"code"), code) == 0 && (owner == 0 || strcmp(ht_text(finding, c"rule"), owner) == 0)): return finding
	return 0

json_value* aa_run(list[char*] command, char* audit, int ok):
	process_result* result = ht_run(command, 0, 0, 90000)
	if ((result.status == 0) != ok):
		print2(result.stderr_text)
		ht_require(0, c"unexpected audit translation status")
	return ht_field(ht_json(audit), c"findings")

int main():
	char* directory = ht_temp()
	char* source = path_join(directory, c"Proof.g4")
	char* output = path_join(directory, c"out.pg")
	char* audit = path_join(directory, c"audit.json")
	file_write_text(source, c"grammar Proof; root: A EOF; A: 'a' {host();};")
	file_write_text(output, c"sentinel")
	list[char*] command = ht_argv(c"bin/antlr_to_pg", source, c"-o", output, c"--strict", c"--audit-json", audit)
	json_value* findings = aa_run(command, audit, 0)
	ht_equal_file(output, c"sentinel")
	ht_require(ht_number(ht_json(audit), c"schema_version") == 1, c"unsupported audit schema")
	json_value* finding = aa_finding(findings, c"AT_HOST_SITE")
	ht_require(finding != 0 && strcmp(ht_text(finding, c"rule"), c"A") == 0 && strcmp(ht_text(finding, c"file"), source) == 0 && ht_number(finding, c"line") == 1 && ht_number(finding, c"column") > 0 && strcmp(ht_text(finding, c"classification"), c"unsupported") == 0, c"host-site finding lacks actionable location")
	file_write_text(source, c"grammar Proof; import Missing; root: 'a' EOF;")
	ht_require(aa_finding(aa_run(command, audit, 0), c"AT_DEPENDENCY") != 0, c"missing dependency finding")
	file_write_text(source, c"grammar Proof; root: 'a' EOF; WS: [ \\t\\r\\n]+ -> skip;")
	ht_require(aa_run(command, audit, 1).array_values.length == 0, c"clean grammar has audit findings")
	file_write_text(source, c"grammar Proof; root: MISSING EOF; A: 'a';")
	findings = aa_run(command, audit, 0)
	ht_require(aa_finding(findings, c"AT_INFERRED_TOKEN") != 0 && aa_finding(findings, c"AT_TOKEN_NO_LEXER") != 0, c"missing token findings")
	list[char*] permissive = new list[char*]
	for char* arg in command:
		if (strcmp(arg, c"--strict") != 0): permissive.push(arg)
	aa_run(permissive, audit, 1)
	char* generated = path_join(directory, c"generated.w")
	ht_checked(ht_argv(c"bin/parser_generator_grammars", output, c"-o", generated))
	char* driver = path_join(directory, c"driver.w")
	file_write_text(driver, c"import generated\nint main():\n\treturn 0\n")
	ht_checked(ht_argv(c"bin/wv2", c"--strict", c"--import-root", directory, driver, c"-o", path_join(directory, c"driver")))
	file_write_text(source, c"grammar Proof; root: item EOF; item: other 'a' | 'b'; other: item;")
	file_write_text(output, c"sentinel")
	findings = aa_run(command, audit, 0)
	ht_equal_file(output, c"sentinel")
	ht_require(aa_finding(findings, c"AT_LEFT_RECURSION") != 0 && aa_finding(findings, c"AT_PARSER_CONTINUATION") == 0, c"unsafe recursion admitted continuation proof")
	list[char*] exact = new list[char*]
	for char* arg in command: exact.push(arg)
	exact.push(c"--exact-lexer")
	exact.push(c"--prediction")
	char* report = path_join(directory, c"out.report")
	char* matchers = path_join(directory, c"out_matchers.w")
	exact.push(c"--report")
	exact.push(report)
	exact.push(c"--matchers")
	exact.push(matchers)
	list[char*] grammars = ht_split(c"root: expr EOF; expr: expr expr | 'x';\nroot: expr EOF; expr: expr ','? expr | 'x';\nroot: expr EOF; expr: expr '+' expr | ;\nroot: item EOF; item: other 'a' | 'b'; other: item;", 10)
	list[char*] reasons = split(c"operator_prefix_not_proven operator_prefix_not_proven empty_alternative primary_nullable_prefix_cycle")
	for i in range(4):
		file_write_text(source, strjoin(c"grammar Proof; ", grammars[i]))
		for char* path in ht_argv(output, report, matchers): file_write_text(path, c"sentinel")
		findings = aa_run(exact, audit, 0)
		for char* path in ht_argv(output, report, matchers): ht_equal_file(path, c"sentinel")
		char* owner = c"expr"
		char* cycle = c"[\"expr\",\"expr\"]"
		if (i == 3):
			owner = c"item"
			cycle = c"[\"item\",\"other\",\"item\"]"
		finding = aa_finding(findings, c"AT_LEFT_RECURSION", owner)
		ht_require(finding != 0, c"missing recursion finding")
		json_value* details = ht_field(finding, c"details")
		int guard_found = 0
		for json_value* guard in ht_field(details, c"normalization_guards").array_values:
			if (strcmp(ht_text(guard, c"normalizer"), c"prediction_expression") == 0):
				ht_require(strcmp(ht_text(guard, c"reason_code"), reasons[i]) == 0, c"normalization guard reason changed")
				guard_found = 1
		ht_require(guard_found, c"missing normalization guard")
		json_value* graph = ht_field(details, c"remaining_graph")
		ht_require(ht_field(graph, c"complete").int_value && ht_field(graph, c"cycles").array_values.length > 0, c"incomplete remaining cycle graph")
		int found = 0
		for json_value* item in ht_field(graph, c"cycles").array_values:
			if (strcmp(json_stringify(ht_field(item, c"path")), cycle) == 0 && ht_field(item, c"mutual").int_value == (i == 3)): found = 1
		ht_require(found, c"expected recursion cycle absent")
		json_value* src = ht_field(details, c"source")
		json_value* plan = ht_field(src, c"plan")
		ht_require(ht_field(plan, c"complete").int_value, c"incomplete source plan")
		if (i != 3):
			json_value* binary = ht_field(plan, c"alternatives").array_values[0]
			ht_require(strcmp(ht_text(binary, c"kind"), c"binary") == 0 && ht_number(binary, c"precedence") == 2, c"incorrect binary precedence plan")
			json_value* occurrences = ht_field(binary, c"occurrences")
			ht_require(ht_number(occurrences.array_values[occurrences.array_values.length - 1], c"binding") == 3, c"incorrect recursive binding")
			for json_value* item in ht_field(ht_field(src, c"graph"), c"cycles").array_values: ht_require(!ht_field(item, c"mutual").int_value, c"unexpected mutual source cycle")
	char* lexer = path_join(directory, c"EmptyLexer.g4")
	char* parser = path_join(directory, c"EmptyParser.g4")
	file_write_text(parser, c"parser grammar EmptyParser; options {tokenVocab=EmptyLexer;} root: A EOF;")
	for char* commands in ht_split(c"mode(DEFAULT_MODE), channel(HIDDEN)|mode(NEXT)", '|'):
		file_write_text(lexer, strjoin(strjoin(c"lexer grammar EmptyLexer; A: 'a'; EMPTY: -> ", commands), c"; mode NEXT; B: 'b';"))
		file_write_text(output, c"sentinel")
		findings = aa_run(ht_argv(c"bin/antlr_to_pg", lexer, parser, c"--strict", c"--exact-lexer", c"--prediction", c"-o", output, c"--audit-json", audit), audit, 0)
		ht_equal_file(output, c"sentinel")
		ht_require(aa_finding(findings, c"AT_LEXER_EMPTY") != 0, c"missing empty lexer finding")
	ht_cleanup()
	println(c"structured ANTLR audit: passed")
	return 0
