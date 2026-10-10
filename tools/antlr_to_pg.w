# wbuild: target=grammars_parser_generator dep=wv2 input=tools/parser_generator.w input=libs/extras/parser_generator/ output=bin/parser_generator_grammars
# wbuild: step="bin/wv2 tools/parser_generator.w -o bin/parser_generator_grammars"
# wbuild: target=antlr_to_pg dep=wv2 dep=grammars_parser_generator input=tools/antlr_to_pg.w input=libs/extras/grammars/antlr_to_pg/ input=libs/extras/parser_generator/ output=bin/antlr_to_pg
# wbuild: step="bin/parser_generator_grammars libs/extras/grammars/antlr_to_pg/antlr4.pg -o bin/generated_antlr4_parser.w"
# wbuild: step="bin/parser_generator_grammars libs/extras/grammars/antlr_to_pg/pg.pg -o bin/generated_pg_parser.w"
# wbuild: step="bin/wv2 tools/antlr_to_pg.w -o bin/antlr_to_pg"
# wbuild: target=antlr_to_pg_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/antlr_to_pg libs/extras/grammars/antlr_to_pg/testdata/antlr/json/JSON.g4 -o bin/antlr_to_pg_json.pg --parser-name json --report bin/antlr_to_pg_json.pg.report --matchers bin/antlr_to_pg_json_matchers.w"
# wbuild: step="cmp bin/antlr_to_pg_json.pg libs/extras/grammars/json.pg"
# wbuild: step="cmp bin/antlr_to_pg_json.pg.report libs/extras/grammars/json.pg.report"
# wbuild: step="cmp bin/antlr_to_pg_json_matchers.w libs/extras/grammars/json_matchers.w"
# wbuild: step="bin/antlr_to_pg libs/extras/grammars/antlr_to_pg/testdata/antlr/csv/CSV.g4 -o bin/antlr_to_pg_csv.pg --parser-name csv --report bin/antlr_to_pg_csv.pg.report --matchers bin/antlr_to_pg_csv_matchers.w"
# wbuild: step="cmp bin/antlr_to_pg_csv.pg libs/extras/grammars/csv.pg"
# wbuild: step="cmp bin/antlr_to_pg_csv.pg.report libs/extras/grammars/csv.pg.report"
# wbuild: step="cmp bin/antlr_to_pg_csv_matchers.w libs/extras/grammars/csv_matchers.w"
# wbuild: target=grammars_refresh dep=antlr_to_pg
# wbuild: step="bin/antlr_to_pg libs/extras/grammars/antlr_to_pg/testdata/antlr/json/JSON.g4 -o libs/extras/grammars/json.pg --parser-name json --report libs/extras/grammars/json.pg.report --matchers libs/extras/grammars/json_matchers.w"
# wbuild: step="bin/antlr_to_pg libs/extras/grammars/antlr_to_pg/testdata/antlr/csv/CSV.g4 -o libs/extras/grammars/csv.pg --parser-name csv --report libs/extras/grammars/csv.pg.report --matchers libs/extras/grammars/csv_matchers.w"
/*
antlr_to_pg: best-effort translator from ANTLR4 grammars to the
ParserGenerator .pg DSL (libs/extras/grammars/antlr_to_pg/README.md).

	bin/antlr_to_pg GRAMMAR.g4 [GRAMMAR2.g4 ...] -o out.pg [--parser-name NAME]
		[--report FILE] [--matchers FILE] [--strict] [--audit FILE]

`./wbuild antlr_to_pg` generates the antlr4.pg and pg.pg parsers into bin/
and builds bin/antlr_to_pg; antlr_to_pg_test re-translates the vendored
JSON/CSV grammars and compares the results with the committed
libs/extras/grammars/{json,csv}.pg, their reports and matcher modules
(`./wbuild grammars_refresh` rewrites them after an intended change).
*/
import bin.generated_antlr4_parser
import bin.generated_pg_parser
import libs.extras.grammars.antlr_to_pg.types
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.audit
import libs.extras.grammars.antlr_to_pg.charsets
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.emit
import libs.extras.grammars.antlr_to_pg.matchers_ascii
import libs.extras.grammars.antlr_to_pg.matchers_analyze
import libs.extras.grammars.antlr_to_pg.matchers_emit
import lib.utf8
import libs.extras.parser_generator.grammar_reader
import libs.extras.parser_generator.analysis

# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------
void at_usage():
	println2(c"usage: antlr_to_pg GRAMMAR.g4 [GRAMMAR2.g4 ...] -o out.pg [--parser-name NAME] [--report FILE] [--matchers FILE] [--strict] [--audit FILE]")


int main(int argc, int argv):
	args_init(argc, argv)
	int strict = args_has_bool_flag(c"strict")
	g_at_dependencies = new list[at_site*]
	g_fragments = new map[char*, at_rule*]
	g_lexer_rules = new map[char*, at_rule*]
	g_all_rule_names = new map[char*, int]
	g_used_names = new map[char*, int]
	g_text_to_name = new map[char*, char*]
	g_literal_text = new map[char*, char*]
	g_rule_alts = new map[char*, list[list[at_term*]]]
	g_group_counter = new map[char*, int]
	g_name_remap = new map[char*, char*]
	g_parser_refs = new map[char*, int]
	g_seen_rule_names = new map[char*, int]
	g_negset_text_to_name = new map[char*, char*]
	g_literal_order = new list[char*]
	g_token_names = new list[char*]
	g_token_matchers = new list[char*]
	g_skip_names = new list[char*]
	g_skip_matchers = new list[char*]
	g_parser_rule_names = new list[char*]
	g_report_lines = new list[char*]
	g_grammar_name = 0
	g_any_token_name = 0
	g_negset_counter = 0
	g_matchers_out = string_new()
	g_generated_frags = new map[char*, int]
	g_frag_generating = new map[char*, int]
	g_matcher_tmp = 0
	g_matcher_parser_prefix = c"grammar"
	string_append(g_matchers_out, c"/* Generated lexer matchers from antlr_to_pg -- do not edit. */\n")

	int file_count = args_positional_count()
	if (file_count < 1):
		at_usage()
		return 1
	char* out_path = args_value(c"o")
	if (out_path == 0):
		out_path = args_value(c"output")
	if (out_path == 0):
		at_usage()
		return 1
	char* name_override = args_value(c"parser-name")
	char* report_path = args_value(c"report")
	char* matchers_path = args_value(c"matchers")

	list[at_rule*] all_rules = new list[at_rule*]
	int fi = 0
	while (fi < file_count):
		char* path = args_positional(fi)
		char* source = file_read_text(path)
		if (source == 0):
			println2(cstr(f"antlr_to_pg: could not read {path}"))
			return 1
		pg_diagnostics* diagnostics = pg_diagnostics_new()
		pg_ast_node* root = antlr4_parse(source, path, diagnostics)
		if ((root == 0) | (pg_diagnostics_count(diagnostics) != 0)):
			println2(cstr(f"antlr_to_pg: failed to parse {path}"))
			pg_diagnostics_print(diagnostics)
			return 1
		g_at_source = source
		list[at_rule*] rules = at_collect_rules(root)
		int ri = 0
		while (ri < rules.length):
			all_rules.push(rules[ri])
			ri = ri + 1
		fi = fi + 1

	char* parser_name = name_override
	if (parser_name == 0):
		if (g_grammar_name != 0):
			parser_name = at_lowercase_clone(g_grammar_name)
		else:
			parser_name = c"grammar"
	g_matcher_parser_prefix = parser_name

	int i = 0
	while (i < all_rules.length):
		at_rule* r = all_rules[i]
		if (r.is_fragment):
			g_fragments[r.name] = r
		if (r.is_lexer):
			g_lexer_rules[r.name] = r
		i = i + 1

	int unsafe = at_audit(all_rules)
	at_collect_parser_refs(all_rules)
	at_audit_lexer_contract(all_rules)
	at_print_audit(args_value(c"audit"))
	if (unsafe || (strict && (g_at_semantic_losses > 0))):
		println2(c"antlr_to_pg: semantic audit failed; output files left unchanged")
		return 1

	at_collect_rule_names(all_rules)
	at_collect_parser_refs(all_rules)
	# Resolve ~(TokenA|TokenB|...) to charsets before matcher/classify so
	# PG_NEGSET generation and lexer refuse see folded text.
	at_fold_negated_token_refs(all_rules)
	at_classify_all_lexer_rules(all_rules)
	at_translate_all_parser_rules(all_rules)

	# Every legacy lowering warning is a strict failure, except informative
	# generated-matcher notices. No parser/matcher output has been published.
	if (strict):
		i = 0
		int lowering_losses = 0
		while (i < g_report_lines.length):
			char* report_line = g_report_lines[i]
			if ((starts_with(report_line, c"GENERATED matcher for ") == 0) && (starts_with(report_line, c"DROPPED lexer rule ") == 0)):
				println2(report_line)
				lowering_losses = lowering_losses + 1
			i = i + 1
		if (lowering_losses > 0):
			println2(c"antlr_to_pg: strict lowering failed; output files left unchanged")
			return 1

	if (g_parser_rule_names.length == 0):
		string_builder* report = string_new()
		string_append(report, c"0 parser rules, 0 token rules, 0 skip rules, 0 literals emitted\n")
		string_append(report, c"ERROR: no parser rules emitted -- refusing to write an empty .pg\n")
		i = 0
		while (i < g_report_lines.length):
			string_append(report, g_report_lines[i])
			string_append_char(report, 10)
			i = i + 1
		print2(report.data)
		if (report_path != 0):
			file_write_text(report_path, report.data)
		return 1

	string_builder* out = string_new()
	at_emit(out, parser_name)

	pg_diagnostics* self_check_diagnostics = pg_diagnostics_new()
	pg_ast_node* self_check_root = pg_parse(out.data, c"<generated .pg>", self_check_diagnostics)
	if ((self_check_root == 0) | (pg_diagnostics_count(self_check_diagnostics) != 0)):
		print2(c"antlr_to_pg: internal error -- emitted .pg failed its own pg.pg self-check:\n")
		pg_diagnostics_print(self_check_diagnostics)
		return 1

	if (strict):
		pg_diagnostics* grammar_diagnostics = pg_diagnostics_new()
		pg_grammar* grammar = pg_grammar_read(out.data, c"<strict generated .pg>", grammar_diagnostics)
		if ((grammar == 0) || (pg_diagnostics_count(grammar_diagnostics) > 0)):
			pg_diagnostics_print(grammar_diagnostics)
			return 1
		if (pg_grammar_safety_check(grammar) != 0): return 1

	if (file_write_text(out_path, out.data) == 0):
		println2(cstr(f"antlr_to_pg: could not write {out_path}"))
		return 1

	if (matchers_path != 0):
		if (file_write_text(matchers_path, g_matchers_out.data) == 0):
			println2(cstr(f"antlr_to_pg: could not write {matchers_path}"))
			return 1
		println2(cstr(f"generated matchers {matchers_path}"))

	string_builder* report = string_new()
	string_append(report, cstr(f"{g_parser_rule_names.length} parser rules, {g_token_names.length} token rules, {g_skip_names.length} skip rules, {g_literal_order.length} literals emitted\n"))
	i = 0
	while (i < g_report_lines.length):
		string_append(report, g_report_lines[i])
		string_append_char(report, 10)
		i = i + 1
	print2(report.data)

	if (report_path != 0):
		file_write_text(report_path, report.data)

	println2(cstr(f"generated {out_path}"))
	return 0
