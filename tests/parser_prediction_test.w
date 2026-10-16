# wbuild: x64
import lib.assert
import libs.extras.parser_generator.grammar_reader
import libs.extras.parser_generator.analysis
import libs.extras.parser_generator.prediction_build


pg_grammar* prediction_grammar(char* rules):
	string source = f"parser predict\nliteral A \"a\"\nliteral B \"b\"\nliteral C \"c\"\nstart start\n{rules}"
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_grammar* grammar = pg_grammar_read(source.data, c"prediction.pg", diagnostics)
	assert1(grammar != 0)
	assert_equal(0, diagnostics.items.length)
	assert_equal(0, pg_grammar_safety_check(grammar))
	pg_diagnostics_free(diagnostics)
	free(source.data)
	free(cast(char*, cast(int, source)))
	return grammar


pg_token_stream* prediction_tokens(char* text):
	pg_token_stream* stream = pg_token_stream_new()
	for i in range(strlen(text)):
		int kind = cast(int, text[i]) - 'a' + 1
		pg_token_stream_add(stream, pg_token_make(kind, text, i, 1, c"input", 1, i + 1))
	pg_token_stream_add(stream, pg_token_eof(strlen(text), c"input", 1, strlen(text) + 1))
	return stream


void prediction_case(char* rules, char* input, int accepted, int alternative):
	pg_grammar* grammar = prediction_grammar(rules)
	pg_prediction_program* program = pg_prediction_build(grammar)
	pg_token_stream* stream = prediction_tokens(input)
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = pg_prediction_parse(program, 0, stream, diagnostics)
	assert_equal(accepted, root != 0)
	assert_equal(0, diagnostics.items.length)
	if (root != 0):
		assert1(pg_token_stream_done(stream))
		assert_equal(alternative, pg_ast_get_metadata(root.children[0], c"pg_alternative", -1))
		pg_ast_free(root)
	else:
		assert_equal(0, stream.index)
		assert_equal(0, stream.ast_allocation_count)
	pg_prediction_free(program)
	pg_grammar_free(grammar)
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)


void prediction_adversarial():
	pg_grammar* grammar = prediction_grammar(c"rule start = item B EOF\nrule item = A item | A item | A\n")
	pg_prediction_program* program = pg_prediction_build(grammar)
	pg_token_stream* stream = prediction_tokens(c"aaaaaaaaaaaaaaaaaaaac")
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	assert1(pg_prediction_parse_limit(program, 0, stream, diagnostics, 1000) == 0)
	assert_equal(1001, program.steps)
	assert1(program.peak_branches > 0)
	assert1(stream.resource_failed)
	assert_equal(1, diagnostics.items.length)
	assert_equal(0, stream.ast_allocation_count)
	assert_equal(0, stream.index)
	pg_prediction_free(program)
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)
	pg_grammar_free(grammar)


void prediction_linear():
	pg_grammar* grammar = prediction_grammar(c"rule start = item EOF\nrule item = A item | B\n")
	pg_prediction_program* program = pg_prediction_build(grammar)
	char* text = cast(char*, malloc(302))
	for i in range(300): text[i] = 'a'
	text[300] = 'b'
	text[301] = 0
	pg_token_stream* stream = prediction_tokens(text)
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = pg_prediction_parse(program, 0, stream, diagnostics)
	assert1(root != 0)
	assert1(program.steps < 4000)
	assert1(program.frames < 400)
	assert1(program.events < 1000)
	assert1(program.peak_branches < 400)
	assert_equal(0, diagnostics.items.length)
	pg_ast_free(root)
	pg_prediction_free(program)
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)
	pg_grammar_free(grammar)
	free(text)


int main():
	prediction_case(c"rule start = item\nrule item = A | A B\n", c"ab", 1, 2)
	prediction_case(c"rule start = item\nrule item = A | A B\n", c"aba", 0, 0)
	prediction_case(c"rule start = item EOF\nrule item = A | A B\n", c"ab", 1, 2)
	prediction_case(c"rule start = item EOF\nrule item = A | A B\n", c"a", 1, 1)
	prediction_case(c"rule start = item EOF\nrule item = A | A B\n", c"ac", 0, 0)
	prediction_case(c"rule start = item B EOF\nrule item = A B | A\n", c"ab", 1, 2)
	prediction_case(c"rule start = item EOF\nrule item = A? A\n", c"a", 1, 1)
	prediction_case(c"rule start = item EOF\nrule item = A* A\n", c"aaa", 1, 1)
	prediction_case(c"rule start = item EOF\nrule item = A+ A\n", c"aaa", 1, 1)
	prediction_case(c"rule start = item EOF\nrule item = A+ A\n", c"a", 0, 0)
	prediction_case(c"rule start = item EOF\nrule item = empty A | A\nrule empty =\n", c"a", 1, 1)
	prediction_case(c"rule start = item EOF\nrule item = short | long\nrule short = A\nrule long = A B\n", c"ab", 1, 2)
	prediction_case(c"rule start = item EOF\nrule item = A | A\n", c"a", 1, 1)
	pg_grammar* grammar = prediction_grammar(c"rule start = item EOF\nrule item = A item B | A\n")
	pg_prediction_program* program = pg_prediction_build(grammar)
	pg_token_stream* stream = prediction_tokens(c"aaabbb")
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	assert1(pg_prediction_parse_limit(program, 0, stream, diagnostics, 8) == 0)
	assert1(stream.resource_failed)
	assert_equal(1, diagnostics.items.length)
	assert_equal(0, stream.ast_allocation_count)
	assert_equal(0, stream.index)
	pg_prediction_free(program)
	pg_grammar_free(grammar)
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)
	prediction_adversarial()
	prediction_linear()
	println(c"continuation prediction, priority, rollback and bounded failure passed")
	return 0
