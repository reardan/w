/*
Shared harness for the libs/extras/grammars demo tests
(tests/grammars/<name>_demo.w). Each demo imports this module, the
grammar's lexer matchers and the parser bin/parser_generator_grammars
generated from libs/extras/grammars/<name>.pg (see that file's own
`# wbuild:` target), then feeds sample inputs through expect_clean /
expect_errors and returns grammar_demo_finish() from main.
*/
import lib.lib
import lib.utf8
import libs.extras.parser_generator.runtime


type grammar_demo_parse_fn = fn(char*, char*, pg_diagnostics*) -> pg_ast_node*

grammar_demo_parse_fn* grammar_demo_parse
char* grammar_demo_filename
int grammar_demo_total
int grammar_demo_failed


void grammar_demo_begin(grammar_demo_parse_fn* parse, char* filename):
	grammar_demo_parse = parse
	grammar_demo_filename = filename
	grammar_demo_total = 0
	grammar_demo_failed = 0


void expect_clean(char* source):
	grammar_demo_total = grammar_demo_total + 1
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = grammar_demo_parse(source, grammar_demo_filename, diagnostics)
	if ((root == 0) || (pg_diagnostics_count(diagnostics) != 0)):
		grammar_demo_failed = grammar_demo_failed + 1
		println2(cstr(f"FAIL (expected clean parse): {source}"))
		pg_diagnostics_print(diagnostics)
	else:
		println2(cstr(f"ok: {source}"))


void expect_errors(char* source):
	grammar_demo_total = grammar_demo_total + 1
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = grammar_demo_parse(source, grammar_demo_filename, diagnostics)
	if ((root != 0) && (pg_diagnostics_count(diagnostics) == 0)):
		grammar_demo_failed = grammar_demo_failed + 1
		println2(cstr(f"FAIL (expected a syntax error): {source}"))
	else:
		println2(cstr(f"ok (rejected): {source}"))


# Prints the tally; returns main's exit status (1 when any case failed).
int grammar_demo_finish():
	println2(cstr(f"{grammar_demo_total - grammar_demo_failed}/{grammar_demo_total} passed"))
	if (grammar_demo_failed > 0):
		return 1
	return 0
