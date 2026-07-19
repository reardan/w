/*
W source generator for the first ParserGenerator milestone.
*/
import lib.lib
import lib.container
import structures.string
import libs.extras.parser_generator.token
import libs.extras.parser_generator.grammar_model
import libs.extras.parser_generator.analysis
import libs.extras.parser_generator.lexer
import libs.extras.parser_generator.source_writer


void pg_emit_token_kind_call(pg_source_writer* writer, pg_grammar* grammar, char* name):
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_token_")
	pg_source_append(writer, name)
	pg_source_append(writer, c"()")


void pg_emit_ast_kind_call(pg_source_writer* writer, pg_grammar* grammar, char* name):
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_ast_")
	pg_source_append(writer, name)
	pg_source_append(writer, c"()")


void pg_emit_rule_call(pg_source_writer* writer, pg_grammar* grammar, char* name):
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_parse_")
	pg_source_append(writer, name)
	pg_source_append(writer, c"(stream, diagnostics)")


void pg_emit_c_string_literal(pg_source_writer* writer, char* text):
	pg_source_append_char(writer, 'c')
	pg_source_append_w_string(writer, text)


void pg_emit_term_call(pg_source_writer* writer, pg_grammar* grammar, pg_term* term):
	if (pg_grammar_is_token_term(grammar, term.name)):
		pg_source_append(writer, grammar.name)
		pg_source_append(writer, c"_match_token(stream, ")
		pg_emit_token_kind_call(writer, grammar, term.name)
		pg_source_append(writer, c", ")
		pg_emit_c_string_literal(writer, term.name)
		pg_source_append(writer, c")")
	else:
		pg_emit_rule_call(writer, grammar, term.name)


void pg_emit_dynamic_line_start(pg_source_writer* writer):
	pg_source_tabs(writer)


void pg_emit_dynamic_line_end(pg_source_writer* writer):
	pg_source_append_char(writer, 10)


# Extra "import <dotted.path>" lines from the grammar's own "import"
# directives (issue #329 milestone 4). Actions/predicates that call
# host-provided functions declare the module providing them this way; a
# grammar that declares none (every grammar before milestone 4) emits
# nothing extra here, so its generated output is unaffected.
void pg_emit_grammar_imports(pg_source_writer* writer, pg_grammar* grammar):
	int i = 0
	while (i < grammar.imports.length):
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"import ")
		pg_source_append(writer, grammar.imports[i])
		pg_emit_dynamic_line_end(writer)
		i = i + 1
	if (grammar.imports.length > 0):
		pg_source_blank(writer)


void pg_emit_matcher_name(pg_source_writer* writer, pg_grammar* grammar, char* name):
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_matcher_")
	pg_source_append(writer, name)


void pg_emit_matcher_call(pg_source_writer* writer, pg_grammar* grammar, char* name):
	pg_emit_matcher_name(writer, grammar, name)
	pg_source_append(writer, c"(input, position)")


int pg_matcher_reference_is_expression(pg_grammar* grammar, char* name):
	pg_token_def* token = pg_grammar_find_token(grammar, name)
	if (token != 0):
		return token.expression != 0
	return pg_grammar_find_fragment(grammar, name) != 0


void pg_emit_matcher_reference_call(pg_source_writer* writer, pg_grammar* grammar, char* name):
	pg_token_def* token = pg_grammar_find_token(grammar, name)
	if (token != 0):
		if (token.expression == 0):
			pg_source_append(writer, c"pg_lexer_matcher_")
			pg_source_append(writer, token.matcher)
			pg_source_append(writer, c"(input, position)")
		else:
			pg_emit_matcher_call(writer, grammar, name)
	else:
		pg_emit_matcher_call(writer, grammar, name)


void pg_emit_temp_name(pg_source_writer* writer, char* prefix, int index):
	pg_source_append(writer, prefix)
	pg_source_append_int(writer, index)


# Membership test of the current byte against a charset, as a
# disjunction of byte ranges. Short-circuit spellings: the operands are
# pure comparisons of the matcher_char_ local, so '||'/'&&' change only
# how many comparisons run, never what matches.
void pg_emit_matcher_charset_condition(pg_source_writer* writer, pg_match_expr* expression, int temp):
	int first_condition = 1
	int start = 1
	while (start < 128):
		if (expression.charset[start] == 0):
			start = start + 1
		else:
			int end = start
			while ((end + 1 < 128) && (expression.charset[end + 1] != 0)):
				end = end + 1
			if (first_condition == 0):
				pg_source_append(writer, c" || ")
			if (start == end):
				pg_source_append_char(writer, '(')
				pg_emit_temp_name(writer, c"matcher_char_", temp)
				pg_source_append(writer, c" == ")
				pg_source_append_int(writer, start)
				pg_source_append_char(writer, ')')
			else:
				pg_source_append(writer, c"((")
				pg_emit_temp_name(writer, c"matcher_char_", temp)
				pg_source_append(writer, c" >= ")
				pg_source_append_int(writer, start)
				pg_source_append(writer, c") && (")
				pg_emit_temp_name(writer, c"matcher_char_", temp)
				pg_source_append(writer, c" <= ")
				pg_source_append_int(writer, end)
				pg_source_append(writer, c"))")
			first_condition = 0
			start = end + 1
	if (first_condition):
		pg_source_append_char(writer, '0')


void pg_emit_match_expression(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* expression, int* next_temp);


void pg_emit_matcher_string(pg_source_writer* writer, pg_match_expr* expression):
	pg_source_line(writer, c"if (matched):")
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"if (starts_with(input + position, ")
	pg_emit_c_string_literal(writer, expression.text)
	pg_source_append(writer, c")):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"position = position + ")
	pg_source_append_int(writer, strlen(expression.text))
	pg_emit_dynamic_line_end(writer)
	pg_source_dedent(writer)
	pg_source_line(writer, c"else:")
	pg_source_indent(writer)
	pg_source_line(writer, c"matched = 0")
	pg_source_dedent(writer)
	pg_source_dedent(writer)


void pg_emit_matcher_charset(pg_source_writer* writer, pg_match_expr* expression, int* next_temp):
	int temp = next_temp[0]
	next_temp[0] = temp + 1
	pg_source_line(writer, c"if (matched):")
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_emit_temp_name(writer, c"matcher_char_", temp)
	pg_source_append(writer, c" = input[position] & 255")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"if (")
	pg_emit_matcher_charset_condition(writer, expression, temp)
	pg_source_append(writer, c"):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_source_line(writer, c"position = position + 1")
	pg_source_dedent(writer)
	pg_source_line(writer, c"else:")
	pg_source_indent(writer)
	pg_source_line(writer, c"matched = 0")
	pg_source_dedent(writer)
	pg_source_dedent(writer)


void pg_emit_matcher_reference(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* expression, int* next_temp):
	int temp = next_temp[0]
	next_temp[0] = temp + 1
	pg_source_line(writer, c"if (matched):")
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_emit_temp_name(writer, c"matcher_length_", temp)
	pg_source_append(writer, c" = ")
	pg_emit_matcher_reference_call(writer, grammar, expression.text)
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"if (")
	pg_emit_temp_name(writer, c"matcher_length_", temp)
	if (pg_matcher_reference_is_expression(grammar, expression.text)):
		pg_source_append(writer, c" >= 0):")
	else:
		pg_source_append(writer, c" > 0):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"position = position + ")
	pg_emit_temp_name(writer, c"matcher_length_", temp)
	pg_emit_dynamic_line_end(writer)
	pg_source_dedent(writer)
	pg_source_line(writer, c"else:")
	pg_source_indent(writer)
	pg_source_line(writer, c"matched = 0")
	pg_source_dedent(writer)
	pg_source_dedent(writer)


void pg_emit_matcher_alternation(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* expression, int* next_temp):
	int temp = next_temp[0]
	next_temp[0] = temp + 1
	pg_source_line(writer, c"if (matched):")
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_emit_temp_name(writer, c"matcher_start_", temp)
	pg_source_append(writer, c" = position")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_emit_temp_name(writer, c"matcher_best_", temp)
	pg_source_append(writer, c" = -1")
	pg_emit_dynamic_line_end(writer)
	int i = 0
	while (i < expression.children.length):
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"position = ")
		pg_emit_temp_name(writer, c"matcher_start_", temp)
		pg_emit_dynamic_line_end(writer)
		pg_source_line(writer, c"matched = 1")
		pg_emit_match_expression(writer, grammar, expression.children[i], next_temp)
		pg_source_line(writer, c"if (matched):")
		pg_source_indent(writer)
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"if (position > ")
		pg_emit_temp_name(writer, c"matcher_best_", temp)
		pg_source_append(writer, c"):")
		pg_emit_dynamic_line_end(writer)
		pg_source_indent(writer)
		pg_emit_dynamic_line_start(writer)
		pg_emit_temp_name(writer, c"matcher_best_", temp)
		pg_source_append(writer, c" = position")
		pg_emit_dynamic_line_end(writer)
		pg_source_dedent(writer)
		pg_source_dedent(writer)
		i = i + 1
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"if (")
	pg_emit_temp_name(writer, c"matcher_best_", temp)
	pg_source_append(writer, c" >= 0):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"position = ")
	pg_emit_temp_name(writer, c"matcher_best_", temp)
	pg_emit_dynamic_line_end(writer)
	pg_source_line(writer, c"matched = 1")
	pg_source_dedent(writer)
	pg_source_line(writer, c"else:")
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"position = ")
	pg_emit_temp_name(writer, c"matcher_start_", temp)
	pg_emit_dynamic_line_end(writer)
	pg_source_line(writer, c"matched = 0")
	pg_source_dedent(writer)
	pg_source_dedent(writer)


void pg_emit_matcher_optional(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* expression, int* next_temp):
	int temp = next_temp[0]
	next_temp[0] = temp + 1
	pg_source_line(writer, c"if (matched):")
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_emit_temp_name(writer, c"matcher_start_", temp)
	pg_source_append(writer, c" = position")
	pg_emit_dynamic_line_end(writer)
	pg_emit_match_expression(writer, grammar, expression.children[0], next_temp)
	pg_source_line(writer, c"if (matched == 0):")
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"position = ")
	pg_emit_temp_name(writer, c"matcher_start_", temp)
	pg_emit_dynamic_line_end(writer)
	pg_source_line(writer, c"matched = 1")
	pg_source_dedent(writer)
	pg_source_dedent(writer)


void pg_emit_matcher_repeat_tail(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* child, int* next_temp):
	int temp = next_temp[0]
	next_temp[0] = temp + 1
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_emit_temp_name(writer, c"matcher_repeating_", temp)
	pg_source_append(writer, c" = 1")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"while (")
	pg_emit_temp_name(writer, c"matcher_repeating_", temp)
	pg_source_append(writer, c"):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_emit_temp_name(writer, c"matcher_start_", temp)
	pg_source_append(writer, c" = position")
	pg_emit_dynamic_line_end(writer)
	pg_source_line(writer, c"matched = 1")
	pg_emit_match_expression(writer, grammar, child, next_temp)
	pg_source_line(writer, c"if (matched == 0):")
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"position = ")
	pg_emit_temp_name(writer, c"matcher_start_", temp)
	pg_emit_dynamic_line_end(writer)
	pg_source_line(writer, c"matched = 1")
	pg_emit_dynamic_line_start(writer)
	pg_emit_temp_name(writer, c"matcher_repeating_", temp)
	pg_source_append(writer, c" = 0")
	pg_emit_dynamic_line_end(writer)
	pg_source_dedent(writer)
	pg_source_dedent(writer)


void pg_emit_matcher_repetition(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* expression, int* next_temp):
	pg_source_line(writer, c"if (matched):")
	pg_source_indent(writer)
	if (expression.kind == pg_match_expr_one_or_more_kind()):
		pg_emit_match_expression(writer, grammar, expression.children[0], next_temp)
		pg_source_line(writer, c"if (matched):")
		pg_source_indent(writer)
		pg_emit_matcher_repeat_tail(writer, grammar, expression.children[0], next_temp)
		pg_source_dedent(writer)
	else:
		pg_emit_matcher_repeat_tail(writer, grammar, expression.children[0], next_temp)
	pg_source_dedent(writer)


void pg_emit_match_expression(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* expression, int* next_temp):
	if (expression.kind == pg_match_expr_string_kind()):
		pg_emit_matcher_string(writer, expression)
	else if (expression.kind == pg_match_expr_charset_kind()):
		pg_emit_matcher_charset(writer, expression, next_temp)
	else if (expression.kind == pg_match_expr_reference_kind()):
		pg_emit_matcher_reference(writer, grammar, expression, next_temp)
	else if (expression.kind == pg_match_expr_sequence_kind()):
		int i = 0
		while (i < expression.children.length):
			pg_emit_match_expression(writer, grammar, expression.children[i], next_temp)
			i = i + 1
	else if (expression.kind == pg_match_expr_alternation_kind()):
		pg_emit_matcher_alternation(writer, grammar, expression, next_temp)
	else if (expression.kind == pg_match_expr_optional_kind()):
		pg_emit_matcher_optional(writer, grammar, expression, next_temp)
	else:
		pg_emit_matcher_repetition(writer, grammar, expression, next_temp)


void pg_emit_expression_matcher(pg_source_writer* writer, pg_grammar* grammar, char* name, pg_match_expr* expression):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_emit_matcher_name(writer, grammar, name)
	pg_source_append(writer, c"(char* input, int index):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_source_line(writer, c"int position = index")
	pg_source_line(writer, c"int matched = 1")
	int next_temp = 0
	pg_emit_match_expression(writer, grammar, expression, &next_temp)
	pg_source_line(writer, c"if (matched):")
	pg_source_indent(writer)
	pg_source_line(writer, c"return position - index")
	pg_source_dedent(writer)
	pg_source_line(writer, c"return -1")
	pg_source_dedent(writer)
	pg_source_blank(writer)


void pg_emit_expression_matchers(pg_source_writer* writer, pg_grammar* grammar):
	int i = 0
	while (i < grammar.tokens.length):
		pg_token_def* token = grammar.tokens[i]
		if (token.expression != 0):
			pg_emit_expression_matcher(writer, grammar, token.name, token.expression)
		i = i + 1
	i = 0
	while (i < grammar.skips.length):
		pg_token_def* skip = grammar.skips[i]
		if (skip.expression != 0):
			pg_emit_expression_matcher(writer, grammar, skip.name, skip.expression)
		i = i + 1
	i = 0
	while (i < grammar.fragments.length):
		pg_fragment_def* fragment = grammar.fragments[i]
		pg_emit_expression_matcher(writer, grammar, fragment.name, fragment.expression)
		i = i + 1


void pg_emit_lexer_matcher_call(pg_source_writer* writer, pg_grammar* grammar, pg_token_def* token):
	if (token.expression != 0):
		pg_emit_matcher_name(writer, grammar, token.name)
	else:
		pg_source_append(writer, c"pg_lexer_matcher_")
		pg_source_append(writer, token.matcher)
	pg_source_append(writer, c"(input, index)")


void pg_emit_token_constants(pg_source_writer* writer, pg_grammar* grammar):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_token_EOF():")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_source_line(writer, c"return 0")
	pg_source_dedent(writer)
	pg_source_blank(writer)

	int i = 0
	while (i < grammar.tokens.length):
		pg_token_def* token = grammar.tokens[i]
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"int ")
		pg_source_append(writer, grammar.name)
		pg_source_append(writer, c"_token_")
		pg_source_append(writer, token.name)
		pg_source_append(writer, c"():")
		pg_emit_dynamic_line_end(writer)
		pg_source_indent(writer)
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"return ")
		pg_source_append_int(writer, token.kind)
		pg_emit_dynamic_line_end(writer)
		pg_source_dedent(writer)
		pg_source_blank(writer)
		i = i + 1

	i = 0
	while (i < grammar.literals.length):
		pg_literal_def* literal = grammar.literals[i]
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"int ")
		pg_source_append(writer, grammar.name)
		pg_source_append(writer, c"_token_")
		pg_source_append(writer, literal.name)
		pg_source_append(writer, c"():")
		pg_emit_dynamic_line_end(writer)
		pg_source_indent(writer)
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"return ")
		pg_source_append_int(writer, literal.kind)
		pg_emit_dynamic_line_end(writer)
		pg_source_dedent(writer)
		pg_source_blank(writer)
		i = i + 1

	i = 0
	while (i < grammar.skips.length):
		pg_token_def* skip = grammar.skips[i]
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"int ")
		pg_source_append(writer, grammar.name)
		pg_source_append(writer, c"_token_")
		pg_source_append(writer, skip.name)
		pg_source_append(writer, c"():")
		pg_emit_dynamic_line_end(writer)
		pg_source_indent(writer)
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"return ")
		pg_source_append_int(writer, skip.kind)
		pg_emit_dynamic_line_end(writer)
		pg_source_dedent(writer)
		pg_source_blank(writer)
		i = i + 1


void pg_emit_ast_constants(pg_source_writer* writer, pg_grammar* grammar):
	int i = 0
	while (i < grammar.rules.length):
		pg_rule* rule = grammar.rules[i]
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"int ")
		pg_source_append(writer, grammar.name)
		pg_source_append(writer, c"_ast_")
		pg_source_append(writer, rule.name)
		pg_source_append(writer, c"():")
		pg_emit_dynamic_line_end(writer)
		pg_source_indent(writer)
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"return ")
		pg_source_append_int(writer, rule.kind)
		pg_emit_dynamic_line_end(writer)
		pg_source_dedent(writer)
		pg_source_blank(writer)
		i = i + 1


void pg_emit_token_name(pg_source_writer* writer, pg_grammar* grammar):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"char* ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_token_name(int kind):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_source_line(writer, c"if (kind == 0):")
	pg_source_indent(writer)
	pg_source_line(writer, c"return c\"EOF\"")
	pg_source_dedent(writer)
	int i = 0
	while (i < grammar.tokens.length):
		pg_token_def* token = grammar.tokens[i]
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"else if (kind == ")
		pg_emit_token_kind_call(writer, grammar, token.name)
		pg_source_append(writer, c"):")
		pg_emit_dynamic_line_end(writer)
		pg_source_indent(writer)
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"return ")
		pg_emit_c_string_literal(writer, token.name)
		pg_emit_dynamic_line_end(writer)
		pg_source_dedent(writer)
		i = i + 1
	i = 0
	while (i < grammar.literals.length):
		pg_literal_def* literal = grammar.literals[i]
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"else if (kind == ")
		pg_emit_token_kind_call(writer, grammar, literal.name)
		pg_source_append(writer, c"):")
		pg_emit_dynamic_line_end(writer)
		pg_source_indent(writer)
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"return ")
		pg_emit_c_string_literal(writer, literal.name)
		pg_emit_dynamic_line_end(writer)
		pg_source_dedent(writer)
		i = i + 1
	i = 0
	while (i < grammar.skips.length):
		pg_token_def* skip = grammar.skips[i]
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"else if (kind == ")
		pg_emit_token_kind_call(writer, grammar, skip.name)
		pg_source_append(writer, c"):")
		pg_emit_dynamic_line_end(writer)
		pg_source_indent(writer)
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"return ")
		pg_emit_c_string_literal(writer, skip.name)
		pg_emit_dynamic_line_end(writer)
		pg_source_dedent(writer)
		i = i + 1
	pg_source_line(writer, c"else if (kind == pg_token_whitespace_kind()):")
	pg_source_indent(writer)
	pg_source_line(writer, c"return c\"WHITESPACE\"")
	pg_source_dedent(writer)
	pg_source_line(writer, c"return c\"<invalid>\"")
	pg_source_dedent(writer)
	pg_source_blank(writer)


# Matcher-function forward declarations: shared by AST and streaming
# generation, since both emit the same expression-matcher-backed lexer.
void pg_emit_matcher_forward_declarations(pg_source_writer* writer, pg_grammar* grammar):
	int i = 0
	while (i < grammar.tokens.length):
		pg_token_def* token = grammar.tokens[i]
		if (token.expression != 0):
			pg_emit_dynamic_line_start(writer)
			pg_source_append(writer, c"int ")
			pg_emit_matcher_name(writer, grammar, token.name)
			pg_source_append(writer, c"(char* input, int index);")
			pg_emit_dynamic_line_end(writer)
		i = i + 1
	i = 0
	while (i < grammar.skips.length):
		pg_token_def* skip = grammar.skips[i]
		if (skip.expression != 0):
			pg_emit_dynamic_line_start(writer)
			pg_source_append(writer, c"int ")
			pg_emit_matcher_name(writer, grammar, skip.name)
			pg_source_append(writer, c"(char* input, int index);")
			pg_emit_dynamic_line_end(writer)
		i = i + 1
	i = 0
	while (i < grammar.fragments.length):
		pg_fragment_def* fragment = grammar.fragments[i]
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"int ")
		pg_emit_matcher_name(writer, grammar, fragment.name)
		pg_source_append(writer, c"(char* input, int index);")
		pg_emit_dynamic_line_end(writer)
		i = i + 1
	pg_source_blank(writer)


void pg_emit_rule_forward_declarations(pg_source_writer* writer, pg_grammar* grammar):
	int i = 0
	while (i < grammar.rules.length):
		pg_rule* rule = grammar.rules[i]
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"pg_ast_node* ")
		pg_source_append(writer, grammar.name)
		pg_source_append(writer, c"_parse_")
		pg_source_append(writer, rule.name)
		pg_source_append(writer, c"(pg_token_stream* stream, pg_diagnostics* diagnostics);")
		pg_emit_dynamic_line_end(writer)
		i = i + 1
	pg_source_blank(writer)


void pg_emit_forward_declarations(pg_source_writer* writer, pg_grammar* grammar):
	pg_emit_matcher_forward_declarations(writer, grammar)
	pg_emit_rule_forward_declarations(writer, grammar)


void pg_emit_advance_position(pg_source_writer* writer, pg_grammar* grammar):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"void ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_advance_position(char* input, int start, int length, int* linep, int* columnp):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_source_line(writer, c"int i = 0")
	pg_source_line(writer, c"while (i < length):")
	pg_source_indent(writer)
	pg_source_line(writer, c"if (input[start + i] == 10):")
	pg_source_indent(writer)
	pg_source_line(writer, c"linep[0] = linep[0] + 1")
	pg_source_line(writer, c"columnp[0] = 1")
	pg_source_dedent(writer)
	pg_source_line(writer, c"else:")
	pg_source_indent(writer)
	pg_source_line(writer, c"columnp[0] = columnp[0] + 1")
	pg_source_dedent(writer)
	pg_source_line(writer, c"i = i + 1")
	pg_source_dedent(writer)
	pg_source_dedent(writer)
	pg_source_blank(writer)


void pg_emit_lex_success(pg_source_writer* writer, pg_grammar* grammar, char* name):
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_token_stream_add(stream, pg_token_make(")
	pg_emit_token_kind_call(writer, grammar, name)
	pg_source_append(writer, c", input, start, length, filename, start_line, start_column))")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_advance_position(input, start, length, &line, &column)")
	pg_emit_dynamic_line_end(writer)
	pg_source_line(writer, c"index = index + length")
	pg_source_dedent(writer)


# --- dispatch-table lexer generation -------------------------------------
#
# The generated _lex function used to try every skip, token, and literal
# matcher at every input position to implement longest-match. The emitters
# below keep those matcher attempts byte-for-byte identical but wrap them
# in a first-byte dispatch: each candidate only runs at positions whose
# first byte it could possibly match. Literals sharing a first byte become
# a nested comparison trie, and identifier-shaped literals (keywords) are
# matched by scanning the identifier once and probing a length-bucketed
# keyword chain. Selection semantics are unchanged: longest match wins,
# declaration order breaks token/skip ties, and a literal displaces an
# equal-length token or skip match.


# One lexer candidate (a skip or token definition) in attempt order, with
# the set of first bytes at which its matcher can return a positive length.
struct pg_lexgen_matcher:
	pg_token_def* token
	int is_skip
	char* first_bytes


struct pg_lexgen_literal:
	pg_literal_def* literal
	int text_length
	int first_byte
	int keyword


# An inclusive first-byte range whose bytes all share the same candidate
# set. Ranges are what the generated dispatch tree branches on.
struct pg_lexgen_span:
	int lo
	int hi


void pg_lexgen_bytes_add(char* bytes, int lo, int hi):
	int i = lo
	while (i <= hi):
		bytes[i] = 1
		i = i + 1


# First bytes at which a built-in pg_lexer_matcher_* helper can match.
# These mirror the helpers in libs/extras/parser_generator/lexer.w; an
# unknown helper never prunes, so dispatch stays a pure optimization.
void pg_lexgen_builtin_first_bytes(char* bytes, char* matcher):
	if ((strcmp(matcher, c"letters") == 0) | (strcmp(matcher, c"identifier") == 0)):
		pg_lexgen_bytes_add(bytes, 'a', 'z')
		pg_lexgen_bytes_add(bytes, 'A', 'Z')
		pg_lexgen_bytes_add(bytes, '_', '_')
	else if ((strcmp(matcher, c"digits") == 0) | (strcmp(matcher, c"number") == 0)):
		pg_lexgen_bytes_add(bytes, '0', '9')
	else if (strcmp(matcher, c"c_number") == 0):
		pg_lexgen_bytes_add(bytes, '0', '9')
		pg_lexgen_bytes_add(bytes, '.', '.')
	else if (strcmp(matcher, c"newline") == 0):
		pg_lexgen_bytes_add(bytes, 10, 10)
	else if ((strcmp(matcher, c"tabs") == 0) | (strcmp(matcher, c"inline_tabs") == 0)):
		pg_lexgen_bytes_add(bytes, 9, 9)
	else if (strcmp(matcher, c"c_control") == 0):
		pg_lexgen_bytes_add(bytes, 1, 8)
		pg_lexgen_bytes_add(bytes, 11, 12)
		pg_lexgen_bytes_add(bytes, 14, 31)
	else if ((strcmp(matcher, c"line_comment") == 0) | (strcmp(matcher, c"c_preprocessor") == 0)):
		pg_lexgen_bytes_add(bytes, '#', '#')
	else if ((strcmp(matcher, c"block_comment") == 0) | (strcmp(matcher, c"c_line_comment") == 0)):
		pg_lexgen_bytes_add(bytes, '/', '/')
	else if (strcmp(matcher, c"sql_line_comment") == 0):
		pg_lexgen_bytes_add(bytes, '-', '-')
	else if (strcmp(matcher, c"c_string") == 0):
		pg_lexgen_bytes_add(bytes, '"', '"')
		pg_lexgen_bytes_add(bytes, 'u', 'u')
		pg_lexgen_bytes_add(bytes, 'U', 'U')
		pg_lexgen_bytes_add(bytes, 'L', 'L')
	else if (strcmp(matcher, c"c_char_literal") == 0):
		pg_lexgen_bytes_add(bytes, 39, 39)
		pg_lexgen_bytes_add(bytes, 'u', 'u')
		pg_lexgen_bytes_add(bytes, 'U', 'U')
		pg_lexgen_bytes_add(bytes, 'L', 'L')
	else if (strcmp(matcher, c"string") == 0):
		pg_lexgen_bytes_add(bytes, '"', '"')
		pg_lexgen_bytes_add(bytes, 's', 's')
		pg_lexgen_bytes_add(bytes, 'c', 'c')
		pg_lexgen_bytes_add(bytes, 'f', 'f')
	else if ((strcmp(matcher, c"char_literal") == 0) | (strcmp(matcher, c"doubled_quote_string") == 0)):
		pg_lexgen_bytes_add(bytes, 39, 39)
	else if (strcmp(matcher, c"doubled_double_quote_string") == 0):
		pg_lexgen_bytes_add(bytes, '"', '"')
	else if (strcmp(matcher, c"operator") == 0):
		pg_lexgen_bytes_add(bytes, '<', '<')
		pg_lexgen_bytes_add(bytes, '=', '=')
		pg_lexgen_bytes_add(bytes, '>', '>')
		pg_lexgen_bytes_add(bytes, '|', '|')
		pg_lexgen_bytes_add(bytes, '&', '&')
		pg_lexgen_bytes_add(bytes, '!', '!')
	else:
		pg_lexgen_bytes_add(bytes, 1, 255)


int pg_lexgen_path_contains(list[char*] path, char* name):
	int i = 0
	while (i < path.length):
		if (strcmp(path[i], name) == 0):
			return 1
		i = i + 1
	return 0


# Collect the possible first bytes of a matcher expression into bytes and
# return whether the expression can match empty. Mirrors the shape of
# pg_reader_matcher_nullable; the reader has already rejected cyclic and
# unknown references, so those paths conservatively stop pruning.
int pg_lexgen_expr_first_bytes(pg_grammar* grammar, pg_match_expr* expression, char* bytes, list[char*] path):
	if (expression.kind == pg_match_expr_string_kind()):
		if (strlen(expression.text) == 0):
			return 1
		bytes[expression.text[0] & 255] = 1
		return 0
	if (expression.kind == pg_match_expr_charset_kind()):
		int i = 1
		while (i < 128):
			if (expression.charset[i] != 0):
				bytes[i] = 1
			i = i + 1
		return 0
	if (expression.kind == pg_match_expr_reference_kind()):
		if (pg_lexgen_path_contains(path, expression.text)):
			pg_lexgen_bytes_add(bytes, 1, 255)
			return 0
		pg_token_def* token = pg_grammar_find_token(grammar, expression.text)
		if (token != 0):
			if (token.expression == 0):
				pg_lexgen_builtin_first_bytes(bytes, token.matcher)
				return 0
			path.push(token.name)
			int nullable = pg_lexgen_expr_first_bytes(grammar, token.expression, bytes, path)
			path.pop()
			return nullable
		pg_fragment_def* fragment = pg_grammar_find_fragment(grammar, expression.text)
		if (fragment == 0):
			pg_lexgen_bytes_add(bytes, 1, 255)
			return 0
		path.push(fragment.name)
		int nullable = pg_lexgen_expr_first_bytes(grammar, fragment.expression, bytes, path)
		path.pop()
		return nullable
	if (expression.kind == pg_match_expr_sequence_kind()):
		int i = 0
		while (i < expression.children.length):
			if (pg_lexgen_expr_first_bytes(grammar, expression.children[i], bytes, path) == 0):
				return 0
			i = i + 1
		return 1
	if (expression.kind == pg_match_expr_alternation_kind()):
		int any_nullable = 0
		int i = 0
		while (i < expression.children.length):
			any_nullable = any_nullable | pg_lexgen_expr_first_bytes(grammar, expression.children[i], bytes, path)
			i = i + 1
		return any_nullable
	if ((expression.kind == pg_match_expr_optional_kind()) | (expression.kind == pg_match_expr_zero_or_more_kind())):
		pg_lexgen_expr_first_bytes(grammar, expression.children[0], bytes, path)
		return 1
	return pg_lexgen_expr_first_bytes(grammar, expression.children[0], bytes, path)


pg_lexgen_matcher* pg_lexgen_matcher_new(pg_grammar* grammar, pg_token_def* token, int is_skip):
	pg_lexgen_matcher* candidate = new pg_lexgen_matcher()
	candidate.token = token
	candidate.is_skip = is_skip
	char* bytes = malloc(256)
	int i = 0
	while (i < 256):
		bytes[i] = 0
		i = i + 1
	if (token.expression != 0):
		list[char*] path = new list[char*]
		path.push(token.name)
		pg_lexgen_expr_first_bytes(grammar, token.expression, bytes, path)
		list_free[char*](path)
	else:
		pg_lexgen_builtin_first_bytes(bytes, token.matcher)
	candidate.first_bytes = bytes
	return candidate


# Keyword bucketing is only sound when the built-in identifier matcher is
# among the candidates: it guarantees best_length already covers the whole
# identifier run when the keyword probes execute.
int pg_lexgen_keyword_mode(pg_grammar* grammar):
	int i = 0
	while (i < grammar.tokens.length):
		pg_token_def* token = grammar.tokens[i]
		if (token.expression == 0):
			if (strcmp(token.matcher, c"identifier") == 0):
				return 1
		i = i + 1
	i = 0
	while (i < grammar.skips.length):
		pg_token_def* skip = grammar.skips[i]
		if (skip.expression == 0):
			if (strcmp(skip.matcher, c"identifier") == 0):
				return 1
		i = i + 1
	return 0


int pg_lexgen_literal_is_ident_shaped(char* text):
	if (pg_lexer_is_ident_start(text[0] & 255) == 0):
		return 0
	int i = 1
	while (text[i] != 0):
		if (pg_lexer_is_ident_part(text[i] & 255) == 0):
			return 0
		i = i + 1
	return 1


void pg_lexgen_collect_literals(pg_grammar* grammar, list[pg_lexgen_literal*] literals, int keyword_mode):
	int i = 0
	while (i < grammar.literals.length):
		pg_literal_def* literal = grammar.literals[i]
		int text_length = strlen(literal.text)
		if (text_length > 0):
			# A duplicate text replaces the earlier declaration, matching
			# the last-wins '>=' update order of the linear sweep.
			int replaced = 0
			int j = 0
			while (j < literals.length):
				pg_lexgen_literal* existing = literals[j]
				if (strcmp(existing.literal.text, literal.text) == 0):
					existing.literal = literal
					replaced = 1
				j = j + 1
			if (replaced == 0):
				pg_lexgen_literal* entry = new pg_lexgen_literal()
				entry.literal = literal
				entry.text_length = text_length
				entry.first_byte = literal.text[0] & 255
				entry.keyword = 0
				if (keyword_mode):
					entry.keyword = pg_lexgen_literal_is_ident_shaped(literal.text)
				literals.push(entry)
		i = i + 1


int pg_lexgen_byte_has_candidates(list[pg_lexgen_matcher*] matchers, list[pg_lexgen_literal*] literals, int b):
	int i = 0
	while (i < matchers.length):
		pg_lexgen_matcher* candidate = matchers[i]
		if (candidate.first_bytes[b] != 0):
			return 1
		i = i + 1
	i = 0
	while (i < literals.length):
		pg_lexgen_literal* entry = literals[i]
		if (entry.first_byte == b):
			return 1
		i = i + 1
	return 0


int pg_lexgen_same_candidates(list[pg_lexgen_matcher*] matchers, list[pg_lexgen_literal*] literals, int a, int b):
	int i = 0
	while (i < matchers.length):
		pg_lexgen_matcher* candidate = matchers[i]
		if (candidate.first_bytes[a] != candidate.first_bytes[b]):
			return 0
		i = i + 1
	# A literal belongs to exactly one first byte, so two bytes can only
	# share a candidate set when neither has literals.
	i = 0
	while (i < literals.length):
		pg_lexgen_literal* entry = literals[i]
		if ((entry.first_byte == a) || (entry.first_byte == b)):
			return 0
		i = i + 1
	return 1


void pg_lexgen_collect_spans(list[pg_lexgen_matcher*] matchers, list[pg_lexgen_literal*] literals, list[pg_lexgen_span*] spans):
	int b = 1
	while (b < 256):
		if (pg_lexgen_byte_has_candidates(matchers, literals, b)):
			int merged = 0
			if (spans.length > 0):
				pg_lexgen_span* last = spans[spans.length - 1]
				if (last.hi == b - 1):
					if (pg_lexgen_same_candidates(matchers, literals, b - 1, b)):
						last.hi = b
						merged = 1
			if (merged == 0):
				pg_lexgen_span* span = new pg_lexgen_span()
				span.lo = b
				span.hi = b
				spans.push(span)
		b = b + 1


# One skip/token matcher attempt: identical to the block the linear sweep
# used to emit for every candidate at every position.
void pg_emit_lexer_attempt(pg_source_writer* writer, pg_grammar* grammar, pg_token_def* token, int is_skip):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"length = ")
	pg_emit_lexer_matcher_call(writer, grammar, token)
	pg_emit_dynamic_line_end(writer)
	pg_source_line(writer, c"if (length > best_length):")
	pg_source_indent(writer)
	pg_source_line(writer, c"best_length = length")
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"best_kind = ")
	pg_emit_token_kind_call(writer, grammar, token.name)
	pg_emit_dynamic_line_end(writer)
	if (is_skip):
		pg_source_line(writer, c"best_skip = 1")
	else:
		pg_source_line(writer, c"best_skip = 0")
	pg_source_dedent(writer)


# Nested comparison trie over literals sharing a first byte. depth bytes
# are already known to match when a node is entered; a literal ending at
# this depth records itself before longer literals get a chance to
# overwrite it, which implements longest-match with prefix fallback.
void pg_emit_lexer_literal_trie(pg_source_writer* writer, pg_grammar* grammar, list[pg_lexgen_literal*] group, int depth):
	int i = 0
	while (i < group.length):
		pg_lexgen_literal* accept = group[i]
		if (accept.text_length == depth):
			pg_emit_dynamic_line_start(writer)
			pg_source_append(writer, c"length = ")
			pg_source_append_int(writer, depth)
			pg_emit_dynamic_line_end(writer)
			pg_emit_dynamic_line_start(writer)
			pg_source_append(writer, c"literal_kind = ")
			pg_emit_token_kind_call(writer, grammar, accept.literal.name)
			pg_emit_dynamic_line_end(writer)
		i = i + 1
	int first_child = 1
	i = 0
	while (i < group.length):
		pg_lexgen_literal* entry = group[i]
		if (entry.text_length > depth):
			int c = entry.literal.text[depth] & 255
			int seen = 0
			int j = 0
			while (j < i):
				pg_lexgen_literal* earlier = group[j]
				if (earlier.text_length > depth):
					if ((earlier.literal.text[depth] & 255) == c):
						seen = 1
				j = j + 1
			if (seen == 0):
				pg_emit_dynamic_line_start(writer)
				if (first_child):
					pg_source_append(writer, c"if (")
				else:
					pg_source_append(writer, c"else if (")
				if (c < 128):
					pg_source_append(writer, c"input[index + ")
					pg_source_append_int(writer, depth)
					pg_source_append(writer, c"] == ")
					pg_source_append_int(writer, c)
				else:
					pg_source_append(writer, c"(input[index + ")
					pg_source_append_int(writer, depth)
					pg_source_append(writer, c"] & 255) == ")
					pg_source_append_int(writer, c)
				pg_source_append(writer, c"):")
				pg_emit_dynamic_line_end(writer)
				pg_source_indent(writer)
				list[pg_lexgen_literal*] subgroup = new list[pg_lexgen_literal*]
				int k = 0
				while (k < group.length):
					pg_lexgen_literal* member = group[k]
					if (member.text_length > depth):
						if ((member.literal.text[depth] & 255) == c):
							subgroup.push(member)
					k = k + 1
				pg_emit_lexer_literal_trie(writer, grammar, subgroup, depth + 1)
				list_free[pg_lexgen_literal*](subgroup)
				pg_source_dedent(writer)
				first_child = 0
		i = i + 1


void pg_emit_lexer_literal_group(pg_source_writer* writer, pg_grammar* grammar, list[pg_lexgen_literal*] group):
	int has_root_accept = 0
	int i = 0
	while (i < group.length):
		pg_lexgen_literal* entry = group[i]
		if (entry.text_length == 1):
			has_root_accept = 1
		i = i + 1
	if (has_root_accept == 0):
		pg_source_line(writer, c"length = 0")
	pg_emit_lexer_literal_trie(writer, grammar, group, 1)
	pg_source_line(writer, c"if ((length > 0) && (length >= best_length)):")
	pg_source_indent(writer)
	pg_source_line(writer, c"best_length = length")
	pg_source_line(writer, c"best_kind = literal_kind")
	pg_source_line(writer, c"best_skip = 0")
	pg_source_dedent(writer)


# Identifier-shaped literals: scan the identifier once, then probe only
# the keywords whose length equals the identifier run. A shorter keyword
# prefix can never win here because the identifier candidate has already
# pushed best_length to the full run length.
void pg_emit_lexer_keyword_buckets(pg_source_writer* writer, pg_grammar* grammar, list[pg_lexgen_literal*] group, int have_ident_length):
	if (have_ident_length == 0):
		pg_source_line(writer, c"length = pg_lexer_matcher_identifier(input, index)")
	int max_length = 0
	int i = 0
	while (i < group.length):
		pg_lexgen_literal* entry = group[i]
		if (entry.text_length > max_length):
			max_length = entry.text_length
		i = i + 1
	int first_bucket = 1
	int n = 1
	while (n <= max_length):
		int bucket_size = 0
		i = 0
		while (i < group.length):
			pg_lexgen_literal* entry = group[i]
			if (entry.text_length == n):
				bucket_size = bucket_size + 1
			i = i + 1
		if (bucket_size > 0):
			pg_emit_dynamic_line_start(writer)
			if (first_bucket):
				pg_source_append(writer, c"if (length == ")
			else:
				pg_source_append(writer, c"else if (length == ")
			pg_source_append_int(writer, n)
			pg_source_append(writer, c"):")
			pg_emit_dynamic_line_end(writer)
			pg_source_indent(writer)
			int first_keyword = 1
			i = 0
			while (i < group.length):
				pg_lexgen_literal* entry = group[i]
				if (entry.text_length == n):
					pg_emit_dynamic_line_start(writer)
					if (first_keyword):
						pg_source_append(writer, c"if (starts_with(input + index, ")
					else:
						pg_source_append(writer, c"else if (starts_with(input + index, ")
					pg_emit_c_string_literal(writer, entry.literal.text)
					pg_source_append(writer, c")):")
					pg_emit_dynamic_line_end(writer)
					pg_source_indent(writer)
					pg_source_line(writer, c"if (length >= best_length):")
					pg_source_indent(writer)
					pg_source_line(writer, c"best_length = length")
					pg_emit_dynamic_line_start(writer)
					pg_source_append(writer, c"best_kind = ")
					pg_emit_token_kind_call(writer, grammar, entry.literal.name)
					pg_emit_dynamic_line_end(writer)
					pg_source_line(writer, c"best_skip = 0")
					pg_source_dedent(writer)
					pg_source_dedent(writer)
					first_keyword = 0
				i = i + 1
			pg_source_dedent(writer)
			first_bucket = 0
		n = n + 1


void pg_emit_lexer_byte_body(pg_source_writer* writer, pg_grammar* grammar, list[pg_lexgen_matcher*] matchers, list[pg_lexgen_literal*] literals, int b):
	int last_is_identifier = 0
	int i = 0
	while (i < matchers.length):
		pg_lexgen_matcher* candidate = matchers[i]
		if (candidate.first_bytes[b] != 0):
			pg_emit_lexer_attempt(writer, grammar, candidate.token, candidate.is_skip)
			last_is_identifier = 0
			pg_token_def* token = candidate.token
			if (token.expression == 0):
				if (strcmp(token.matcher, c"identifier") == 0):
					last_is_identifier = 1
		i = i + 1
	list[pg_lexgen_literal*] group = new list[pg_lexgen_literal*]
	i = 0
	while (i < literals.length):
		pg_lexgen_literal* entry = literals[i]
		if ((entry.first_byte == b) && (entry.keyword == 0)):
			group.push(entry)
		i = i + 1
	if (group.length > 0):
		pg_emit_lexer_literal_group(writer, grammar, group)
		last_is_identifier = 0
	list_free[pg_lexgen_literal*](group)
	list[pg_lexgen_literal*] keywords = new list[pg_lexgen_literal*]
	i = 0
	while (i < literals.length):
		pg_lexgen_literal* entry = literals[i]
		if ((entry.first_byte == b) && (entry.keyword != 0)):
			keywords.push(entry)
		i = i + 1
	if (keywords.length > 0):
		pg_emit_lexer_keyword_buckets(writer, grammar, keywords, last_is_identifier)
	list_free[pg_lexgen_literal*](keywords)


# Binary dispatch over the first-byte ranges: log-depth comparisons on
# first_byte select the single range whose candidate set can match here.
# Bytes outside every range have no possible match and fall through with
# best_length still 0, exactly like the linear sweep.
void pg_emit_lexer_dispatch(pg_source_writer* writer, pg_grammar* grammar, list[pg_lexgen_matcher*] matchers, list[pg_lexgen_literal*] literals, list[pg_lexgen_span*] spans, int lo, int hi):
	if (lo == hi):
		pg_lexgen_span* span = spans[lo]
		pg_emit_dynamic_line_start(writer)
		if (span.lo == span.hi):
			pg_source_append(writer, c"if (first_byte == ")
			pg_source_append_int(writer, span.lo)
			pg_source_append(writer, c"):")
		else:
			pg_source_append(writer, c"if ((first_byte >= ")
			pg_source_append_int(writer, span.lo)
			pg_source_append(writer, c") && (first_byte <= ")
			pg_source_append_int(writer, span.hi)
			pg_source_append(writer, c")):")
		pg_emit_dynamic_line_end(writer)
		pg_source_indent(writer)
		pg_emit_lexer_byte_body(writer, grammar, matchers, literals, span.lo)
		pg_source_dedent(writer)
		return
	int mid = (lo + hi + 1) / 2
	pg_lexgen_span* pivot = spans[mid]
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"if (first_byte < ")
	pg_source_append_int(writer, pivot.lo)
	pg_source_append(writer, c"):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_lexer_dispatch(writer, grammar, matchers, literals, spans, lo, mid - 1)
	pg_source_dedent(writer)
	pg_source_line(writer, c"else:")
	pg_source_indent(writer)
	pg_emit_lexer_dispatch(writer, grammar, matchers, literals, spans, mid, hi)
	pg_source_dedent(writer)


void pg_emit_lexer(pg_source_writer* writer, pg_grammar* grammar):
	list[pg_lexgen_matcher*] matchers = new list[pg_lexgen_matcher*]
	int i = 0
	while (i < grammar.skips.length):
		matchers.push(pg_lexgen_matcher_new(grammar, grammar.skips[i], 1))
		i = i + 1
	i = 0
	while (i < grammar.tokens.length):
		matchers.push(pg_lexgen_matcher_new(grammar, grammar.tokens[i], 0))
		i = i + 1
	int keyword_mode = pg_lexgen_keyword_mode(grammar)
	list[pg_lexgen_literal*] literals = new list[pg_lexgen_literal*]
	pg_lexgen_collect_literals(grammar, literals, keyword_mode)
	list[pg_lexgen_span*] spans = new list[pg_lexgen_span*]
	pg_lexgen_collect_spans(matchers, literals, spans)
	int has_trie_literals = 0
	i = 0
	while (i < literals.length):
		pg_lexgen_literal* entry = literals[i]
		if (entry.keyword == 0):
			has_trie_literals = 1
		i = i + 1
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_token_stream* ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_lex(char* input, char* filename, pg_diagnostics* diagnostics):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_source_line(writer, c"pg_token_stream* stream = pg_token_stream_new()")
	pg_source_line(writer, c"int index = 0")
	pg_source_line(writer, c"int line = 1")
	pg_source_line(writer, c"int column = 1")
	pg_source_line(writer, c"while (input[index] != 0):")
	pg_source_indent(writer)
	pg_source_line(writer, c"int start = index")
	pg_source_line(writer, c"int start_line = line")
	pg_source_line(writer, c"int start_column = column")
	pg_source_line(writer, c"int length = 0")
	pg_source_line(writer, c"int best_kind = 0")
	pg_source_line(writer, c"int best_length = 0")
	pg_source_line(writer, c"int best_skip = 0")
	if (has_trie_literals):
		pg_source_line(writer, c"int literal_kind = 0")
	if (spans.length > 0):
		pg_source_line(writer, c"int first_byte = input[index] & 255")
		pg_emit_lexer_dispatch(writer, grammar, matchers, literals, spans, 0, spans.length - 1)
	i = 0
	while (i < matchers.length):
		pg_lexgen_matcher* candidate = matchers[i]
		free(candidate.first_bytes)
		free(candidate)
		i = i + 1
	list_free[pg_lexgen_matcher*](matchers)
	i = 0
	while (i < literals.length):
		pg_lexgen_literal* entry = literals[i]
		free(entry)
		i = i + 1
	list_free[pg_lexgen_literal*](literals)
	i = 0
	while (i < spans.length):
		pg_lexgen_span* span = spans[i]
		free(span)
		i = i + 1
	list_free[pg_lexgen_span*](spans)
	pg_source_line(writer, c"if (best_length > 0):")
	pg_source_indent(writer)
	pg_source_line(writer, c"if (best_skip == 0):")
	pg_source_indent(writer)
	pg_source_line(writer, c"pg_token_stream_add(stream, pg_token_make(best_kind, input, start, best_length, filename, start_line, start_column))")
	pg_source_dedent(writer)
	pg_source_line(writer, c"else:")
	pg_source_indent(writer)
	pg_source_line(writer, c"pg_token_stream_add(stream, pg_token_hide(pg_token_make(best_kind, input, start, best_length, filename, start_line, start_column)))")
	pg_source_dedent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_advance_position(input, start, best_length, &line, &column)")
	pg_emit_dynamic_line_end(writer)
	pg_source_line(writer, c"index = index + best_length")
	pg_source_dedent(writer)
	pg_source_line(writer, c"else if (pg_lexer_is_inline_space(input[index])):")
	pg_source_indent(writer)
	pg_source_line(writer, c"int ws_start = index")
	pg_source_line(writer, c"int ws_line = line")
	pg_source_line(writer, c"int ws_column = column")
	pg_source_line(writer, c"while (pg_lexer_is_inline_space(input[index])):")
	pg_source_indent(writer)
	pg_source_line(writer, c"column = column + 1")
	pg_source_line(writer, c"index = index + 1")
	pg_source_dedent(writer)
	pg_source_line(writer, c"pg_token_stream_add(stream, pg_token_hide(pg_token_make(pg_token_whitespace_kind(), input, ws_start, index - ws_start, filename, ws_line, ws_column)))")
	pg_source_dedent(writer)
	pg_source_line(writer, c"else:")
	pg_source_indent(writer)
	pg_source_line(writer, c"pg_diagnostics_add(diagnostics, filename, line, column, c\"invalid character\", c\"known token\", pg_substr(input, index, 1))")
	pg_source_line(writer, c"pg_token_stream_add(stream, pg_token_hide(pg_token_make(pg_token_invalid_kind(), input, index, 1, filename, line, column)))")
	pg_source_line(writer, c"index = index + 1")
	pg_source_line(writer, c"column = column + 1")
	pg_source_dedent(writer)
	pg_source_dedent(writer)
	pg_source_line(writer, c"pg_token_stream_add(stream, pg_token_eof(index, filename, line, column))")
	pg_source_line(writer, c"return stream")
	pg_source_dedent(writer)
	pg_source_blank(writer)


void pg_emit_match_token(pg_source_writer* writer, pg_grammar* grammar):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_ast_node* ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_match_token(pg_token_stream* stream, int kind, char* name):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_source_line(writer, c"pg_token* token = pg_token_stream_peek(stream)")
	pg_source_line(writer, c"if (token.kind == kind):")
	pg_source_indent(writer)
	pg_source_line(writer, c"pg_token_stream_consume(stream)")
	pg_source_line(writer, c"return pg_ast_token(kind, token, name)")
	pg_source_dedent(writer)
	pg_source_line(writer, c"return 0")
	pg_source_dedent(writer)
	pg_source_blank(writer)


void pg_emit_var(pg_source_writer* writer, char* name, int alt_index, int term_index):
	pg_source_append(writer, name)
	pg_source_append_int(writer, alt_index)
	pg_source_append(writer, c"_")
	pg_source_append_int(writer, term_index)


# --- LL(1) committed dispatch (issue #329 milestone 2) ---------------------
#
# Rule bodies used to attempt every alternative in order, allocating a
# node per attempt and re-parsing shared prefixes. Using the analysis in
# analysis.w, the emitters below (a) guard alternatives and ?/*/+ terms
# with first-set membership tests that only skip attempts which would
# fail without consuming input or recording diagnostics, and (b) parse a
# left-factored shared plain-term prefix of consecutive alternatives
# once, dispatching only the suffix choice. Ordered-choice (PEG)
# semantics, accept/reject behavior, AST shape, and the furthest-token
# error position are unchanged: where first sets overlap or a guard
# would be unsound (nullable or impure attempts), today's mark/rewind
# backtracking code shape is kept.


# Caller-freed "name<alt>_<term>" string for hoisted guard variables.
char* pg_guard_var_name(char* name, int alt_index, int term_index):
	string_builder* out = string_new()
	string_append(out, name)
	string_append(out, itoa(alt_index))
	string_append(out, c"_")
	string_append(out, itoa(term_index))
	char* text = out.data
	free(out)
	return text


# Parenthesized membership test of var_name against a kind set, as a
# disjunction of ranges over the dense kind numbering, e.g.
# (k == g_token_IDENT()) || ((k >= g_token_KW_IF()) && (k <= g_token_KW_FOR()))
# Emitted with the short-circuit spellings: every operand is a pure
# comparison against a token-kind constant function, so skipping the
# rest of the disjunction once a range matches changes nothing but the
# number of comparisons executed.
void pg_emit_kind_set_test(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, char* kinds, char* var_name):
	int first_range = 1
	int kind = 0
	while (kind < analysis.kind_count):
		if (kinds[kind] == 0):
			kind = kind + 1
		else:
			int end = kind
			while ((end + 1 < analysis.kind_count) && (kinds[end + 1] != 0)):
				end = end + 1
			if (first_range == 0):
				pg_source_append(writer, c" || ")
			if (kind == end):
				pg_source_append(writer, c"(")
				pg_source_append(writer, var_name)
				pg_source_append(writer, c" == ")
				pg_emit_token_kind_call(writer, grammar, pg_report_kind_name(grammar, kind))
				pg_source_append(writer, c")")
			else:
				pg_source_append(writer, c"((")
				pg_source_append(writer, var_name)
				pg_source_append(writer, c" >= ")
				pg_emit_token_kind_call(writer, grammar, pg_report_kind_name(grammar, kind))
				pg_source_append(writer, c") && (")
				pg_source_append(writer, var_name)
				pg_source_append(writer, c" <= ")
				pg_emit_token_kind_call(writer, grammar, pg_report_kind_name(grammar, end))
				pg_source_append(writer, c"))")
			first_range = 0
			kind = end + 1
	if (first_range):
		pg_source_append_char(writer, '0')


# "int <var> = pg_token_stream_peek(stream).kind"
void pg_emit_peek_kind_line(pg_source_writer* writer, char* var_name):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_source_append(writer, var_name)
	pg_source_append(writer, c" = pg_token_stream_peek(stream).kind")
	pg_emit_dynamic_line_end(writer)


# Error recovery inside a repetition of a recover-marked rule. Emitted in the
# child-failed branch, after the stream has been rewound to the iteration
# mark. At EOF the repetition ends normally; otherwise one diagnostic is
# recorded at the furthest token any attempt reached, the skipped tokens are
# collected under an "error" node, and the repetition resumes after the sync
# token (also skipping sync/skip-led continuations, e.g. blank or indented
# lines).
void pg_emit_recovery(pg_source_writer* writer, pg_grammar* grammar, pg_recover_def* recover, char* rule_name, int alt_index, int term_index):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"if (pg_token_stream_peek(stream).kind == ")
	pg_emit_token_kind_call(writer, grammar, c"EOF")
	pg_source_append(writer, c"):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_source_line(writer, c"break")
	pg_source_dedent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_token* ")
	pg_emit_var(writer, c"recover_found_", alt_index, term_index)
	pg_source_append(writer, c" = pg_token_stream_furthest(stream)")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_diagnostics_add(diagnostics, ")
	pg_emit_var(writer, c"recover_found_", alt_index, term_index)
	pg_source_append(writer, c".filename, ")
	pg_emit_var(writer, c"recover_found_", alt_index, term_index)
	pg_source_append(writer, c".line, ")
	pg_emit_var(writer, c"recover_found_", alt_index, term_index)
	pg_source_append(writer, c".column, c\"syntax error\", ")
	pg_emit_c_string_literal(writer, rule_name)
	pg_source_append(writer, c", ")
	pg_emit_var(writer, c"recover_found_", alt_index, term_index)
	pg_source_append(writer, c".text)")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_ast_node* ")
	pg_emit_var(writer, c"recover_node_", alt_index, term_index)
	pg_source_append(writer, c" = pg_ast_new(pg_ast_error_kind(), 0, c\"error\")")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"while (pg_token_stream_peek(stream).kind != ")
	pg_emit_token_kind_call(writer, grammar, c"EOF")
	pg_source_append(writer, c"):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_token* ")
	pg_emit_var(writer, c"recover_token_", alt_index, term_index)
	pg_source_append(writer, c" = pg_token_stream_consume(stream)")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_ast_add(")
	pg_emit_var(writer, c"recover_node_", alt_index, term_index)
	pg_source_append(writer, c", pg_ast_token(")
	pg_emit_var(writer, c"recover_token_", alt_index, term_index)
	pg_source_append(writer, c".kind, ")
	pg_emit_var(writer, c"recover_token_", alt_index, term_index)
	pg_source_append(writer, c", c\"error_token\"))")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"if (")
	pg_emit_var(writer, c"recover_token_", alt_index, term_index)
	pg_source_append(writer, c".kind == ")
	pg_emit_token_kind_call(writer, grammar, recover.sync_token)
	pg_source_append(writer, c"):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_emit_var(writer, c"recover_next_", alt_index, term_index)
	pg_source_append(writer, c" = pg_token_stream_peek(stream).kind")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"if ((")
	pg_emit_var(writer, c"recover_next_", alt_index, term_index)
	pg_source_append(writer, c" != ")
	pg_emit_token_kind_call(writer, grammar, recover.sync_token)
	pg_source_append(writer, c")")
	int skip_index = 0
	while (skip_index < recover.skip_tokens.length):
		char* skip_name = recover.skip_tokens[skip_index]
		pg_source_append(writer, c" && (")
		pg_emit_var(writer, c"recover_next_", alt_index, term_index)
		pg_source_append(writer, c" != ")
		pg_emit_token_kind_call(writer, grammar, skip_name)
		pg_source_append(writer, c")")
		skip_index = skip_index + 1
	pg_source_append(writer, c"):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_source_line(writer, c"break")
	pg_source_dedent(writer)
	pg_source_dedent(writer)
	pg_source_dedent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_ast_add(node, ")
	pg_emit_var(writer, c"recover_node_", alt_index, term_index)
	pg_source_append(writer, c")")
	pg_emit_dynamic_line_end(writer)
	pg_source_line(writer, c"continue")


# "pg_ast_node* child_<a>_<t> = <term call>"
void pg_emit_child_assign(pg_source_writer* writer, pg_grammar* grammar, pg_term* term, int alt_index, int term_index):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_ast_node* ")
	pg_emit_var(writer, c"child_", alt_index, term_index)
	pg_source_append(writer, c" = ")
	pg_emit_term_call(writer, grammar, term)
	pg_emit_dynamic_line_end(writer)


# "pg_ast_add(node, child_<a>_<t>)"
void pg_emit_child_add(pg_source_writer* writer, int alt_index, int term_index):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_ast_add(node, ")
	pg_emit_var(writer, c"child_", alt_index, term_index)
	pg_source_append(writer, c")")
	pg_emit_dynamic_line_end(writer)


# "if (child_<a>_<t> == 0):"
void pg_emit_child_failed_test(pg_source_writer* writer, int alt_index, int term_index):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"if (")
	pg_emit_var(writer, c"child_", alt_index, term_index)
	pg_source_append(writer, c" == 0):")
	pg_emit_dynamic_line_end(writer)


# Today's optional-term attempt: mark, trial parse, rewind or attach.
void pg_emit_optional_attempt(pg_source_writer* writer, pg_grammar* grammar, pg_term* term, int alt_index, int term_index):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_emit_var(writer, c"optional_mark_", alt_index, term_index)
	pg_source_append(writer, c" = pg_token_stream_mark(stream)")
	pg_emit_dynamic_line_end(writer)
	pg_emit_child_assign(writer, grammar, term, alt_index, term_index)
	pg_emit_child_failed_test(writer, alt_index, term_index)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_token_stream_rewind(stream, ")
	pg_emit_var(writer, c"optional_mark_", alt_index, term_index)
	pg_source_append(writer, c")")
	pg_emit_dynamic_line_end(writer)
	pg_source_dedent(writer)
	pg_source_line(writer, c"else:")
	pg_source_indent(writer)
	pg_emit_child_add(writer, alt_index, term_index)
	pg_source_dedent(writer)


# The guard has already established the term matches here: attach the
# child directly, with no mark/rewind and no failure branch. Only used
# for token terms, whose match is decided entirely by the peeked kind.
void pg_emit_committed_token(pg_source_writer* writer, pg_grammar* grammar, pg_term* term, int alt_index, int term_index):
	pg_emit_child_assign(writer, grammar, term, alt_index, term_index)
	pg_emit_child_add(writer, alt_index, term_index)


# Today's repetition-iteration attempt: mark, trial parse, rewind plus
# recovery-or-break on failure, attach and count on success.
void pg_emit_repeat_attempt(pg_source_writer* writer, pg_grammar* grammar, pg_recover_def* recover, pg_term* term, int alt_index, int term_index):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_emit_var(writer, c"repeat_mark_", alt_index, term_index)
	pg_source_append(writer, c" = pg_token_stream_mark(stream)")
	pg_emit_dynamic_line_end(writer)
	pg_emit_child_assign(writer, grammar, term, alt_index, term_index)
	pg_emit_child_failed_test(writer, alt_index, term_index)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_token_stream_rewind(stream, ")
	pg_emit_var(writer, c"repeat_mark_", alt_index, term_index)
	pg_source_append(writer, c")")
	pg_emit_dynamic_line_end(writer)
	if (recover != 0):
		pg_emit_recovery(writer, grammar, recover, term.name, alt_index, term_index)
	else:
		pg_source_line(writer, c"break")
	pg_source_dedent(writer)
	pg_emit_child_add(writer, alt_index, term_index)
	pg_emit_dynamic_line_start(writer)
	pg_emit_var(writer, c"repeat_count_", alt_index, term_index)
	pg_source_append(writer, c" = ")
	pg_emit_var(writer, c"repeat_count_", alt_index, term_index)
	pg_source_append(writer, c" + 1")
	pg_emit_dynamic_line_end(writer)


void pg_emit_term(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_term* term, int alt_index, int term_index):
	if (term.modifier == 0):
		pg_emit_child_assign(writer, grammar, term, alt_index, term_index)
		pg_emit_child_failed_test(writer, alt_index, term_index)
		pg_source_indent(writer)
		pg_source_line(writer, c"failed = 1")
		pg_source_dedent(writer)
		pg_source_line(writer, c"else:")
		pg_source_indent(writer)
		pg_emit_child_add(writer, alt_index, term_index)
		pg_source_dedent(writer)
	else if (term.modifier == '?'):
		if (pg_analysis_term_enter_guardable(analysis, term)):
			# Enter the optional term only when the current token is in
			# its first set; a miss is a provably silent failure, so the
			# skip is exactly what today's failed attempt did.
			char* kinds = pg_kind_set_new(analysis)
			pg_analysis_term_first(analysis, term, kinds)
			char* kind_name = pg_guard_var_name(c"optional_kind_", alt_index, term_index)
			pg_emit_peek_kind_line(writer, kind_name)
			pg_emit_dynamic_line_start(writer)
			pg_source_append(writer, c"if (")
			pg_emit_kind_set_test(writer, grammar, analysis, kinds, kind_name)
			pg_source_append(writer, c"):")
			pg_emit_dynamic_line_end(writer)
			pg_source_indent(writer)
			if (pg_grammar_is_token_term(grammar, term.name)):
				pg_emit_committed_token(writer, grammar, term, alt_index, term_index)
			else:
				pg_emit_optional_attempt(writer, grammar, term, alt_index, term_index)
			pg_source_dedent(writer)
			free(kind_name)
			free(kinds)
		else:
			pg_emit_optional_attempt(writer, grammar, term, alt_index, term_index)
	else if ((term.modifier == '*') || (term.modifier == '+')):
		pg_recover_def* recover = 0
		if (pg_grammar_is_token_term(grammar, term.name) == 0):
			recover = pg_grammar_find_recover(grammar, term.name)
		int guardable = pg_analysis_term_enter_guardable(analysis, term)
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"int ")
		pg_emit_var(writer, c"repeat_count_", alt_index, term_index)
		pg_source_append(writer, c" = 0")
		pg_emit_dynamic_line_end(writer)
		pg_source_line(writer, c"while (failed == 0):")
		pg_source_indent(writer)
		if (guardable):
			# Iterate while the current token is in the term's first
			# set; the stop is exactly today's final failed attempt.
			char* kinds = pg_kind_set_new(analysis)
			pg_analysis_term_first(analysis, term, kinds)
			char* kind_name = pg_guard_var_name(c"repeat_kind_", alt_index, term_index)
			pg_emit_peek_kind_line(writer, kind_name)
			pg_emit_dynamic_line_start(writer)
			pg_source_append(writer, c"if ((")
			pg_emit_kind_set_test(writer, grammar, analysis, kinds, kind_name)
			pg_source_append(writer, c") == 0):")
			pg_emit_dynamic_line_end(writer)
			pg_source_indent(writer)
			pg_source_line(writer, c"break")
			pg_source_dedent(writer)
			if (pg_grammar_is_token_term(grammar, term.name)):
				pg_emit_committed_token(writer, grammar, term, alt_index, term_index)
				pg_emit_dynamic_line_start(writer)
				pg_emit_var(writer, c"repeat_count_", alt_index, term_index)
				pg_source_append(writer, c" = ")
				pg_emit_var(writer, c"repeat_count_", alt_index, term_index)
				pg_source_append(writer, c" + 1")
				pg_emit_dynamic_line_end(writer)
			else:
				pg_emit_repeat_attempt(writer, grammar, recover, term, alt_index, term_index)
			free(kind_name)
			free(kinds)
		else:
			pg_emit_repeat_attempt(writer, grammar, recover, term, alt_index, term_index)
		pg_source_dedent(writer)
		if (term.modifier == '+'):
			pg_emit_dynamic_line_start(writer)
			pg_source_append(writer, c"if (")
			pg_emit_var(writer, c"repeat_count_", alt_index, term_index)
			pg_source_append(writer, c" == 0):")
			pg_emit_dynamic_line_end(writer)
			pg_source_indent(writer)
			pg_source_line(writer, c"failed = 1")
			pg_source_dedent(writer)


# "node = pg_ast_new(<rule ast kind>, 0, "<rule>")" plus reattaching any
# already-parsed left-factored prefix children in order.
void pg_emit_node_alloc(pg_source_writer* writer, pg_grammar* grammar, pg_rule* rule, list[char*] prefix_children):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"node = pg_ast_new(")
	pg_emit_ast_kind_call(writer, grammar, rule.name)
	pg_source_append(writer, c", 0, ")
	pg_emit_c_string_literal(writer, rule.name)
	pg_source_append(writer, c")")
	pg_emit_dynamic_line_end(writer)
	int i = 0
	while (i < prefix_children.length):
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"pg_ast_add(node, ")
		pg_source_append(writer, prefix_children[i])
		pg_source_append(writer, c")")
		pg_emit_dynamic_line_end(writer)
		i = i + 1


# One alternative's terms from offset on: today's attempt body. With an
# empty remainder (a fully factored alternative) the node is returned
# outright — nothing is left to fail.
void pg_emit_alternative_body(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, int alt_index, int offset, list[char*] prefix_children, char* mark_name):
	pg_alternative* alternative = rule.alternatives[alt_index]
	pg_emit_node_alloc(writer, grammar, rule, prefix_children)
	if (offset >= alternative.terms.length):
		pg_source_line(writer, c"return node")
		return
	pg_source_line(writer, c"failed = 0")
	int term_index = offset
	while (term_index < alternative.terms.length):
		pg_source_line(writer, c"if (failed == 0):")
		pg_source_indent(writer)
		pg_emit_term(writer, grammar, analysis, alternative.terms[term_index], alt_index, term_index)
		pg_source_dedent(writer)
		term_index = term_index + 1
	pg_source_line(writer, c"if (failed == 0):")
	pg_source_indent(writer)
	pg_source_line(writer, c"return node")
	pg_source_dedent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_token_stream_rewind(stream, ")
	pg_source_append(writer, mark_name)
	pg_source_append(writer, c")")
	pg_emit_dynamic_line_end(writer)


void pg_emit_choice(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, int alt_start, int alt_count, int offset, list[char*] prefix_children, char* mark_name, char* kind_name);


# A left-factored run: parse the shared prefix once into locals, then
# dispatch the suffix choice from a fresh mark. On any failure the
# stream is restored to the enclosing mark, exactly like the separate
# per-alternative attempts this replaces.
void pg_emit_factored_unit(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, pg_choice_unit* unit, int offset, list[char*] prefix_children, char* mark_name):
	pg_alternative* head = rule.alternatives[unit.alt_start]
	pg_source_line(writer, c"failed = 0")
	list[char*] inner_children = new list[char*]
	int i = 0
	while (i < prefix_children.length):
		inner_children.push(prefix_children[i])
		i = i + 1
	# The prefix children are declared at unit level so the suffix
	# alternatives (nested blocks) can attach them to their nodes.
	int term_index = offset
	while (term_index < offset + unit.prefix_length):
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"pg_ast_node* ")
		pg_emit_var(writer, c"child_", unit.alt_start, term_index)
		pg_source_append(writer, c" = 0")
		pg_emit_dynamic_line_end(writer)
		term_index = term_index + 1
	term_index = offset
	while (term_index < offset + unit.prefix_length):
		pg_source_line(writer, c"if (failed == 0):")
		pg_source_indent(writer)
		pg_emit_dynamic_line_start(writer)
		pg_emit_var(writer, c"child_", unit.alt_start, term_index)
		pg_source_append(writer, c" = ")
		pg_emit_term_call(writer, grammar, head.terms[term_index])
		pg_emit_dynamic_line_end(writer)
		pg_emit_child_failed_test(writer, unit.alt_start, term_index)
		pg_source_indent(writer)
		pg_source_line(writer, c"failed = 1")
		pg_source_dedent(writer)
		pg_source_dedent(writer)
		inner_children.push(pg_guard_var_name(c"child_", unit.alt_start, term_index))
		term_index = term_index + 1
	pg_source_line(writer, c"if (failed == 0):")
	pg_source_indent(writer)
	char* factored_mark = pg_guard_var_name(c"factored_mark_", unit.alt_start, offset)
	char* factored_kind = pg_guard_var_name(c"factored_kind_", unit.alt_start, offset)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_source_append(writer, factored_mark)
	pg_source_append(writer, c" = pg_token_stream_mark(stream)")
	pg_emit_dynamic_line_end(writer)
	pg_emit_choice(writer, grammar, analysis, rule, unit.alt_start, unit.member_count, offset + unit.prefix_length, inner_children, factored_mark, factored_kind)
	pg_source_dedent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_token_stream_rewind(stream, ")
	pg_source_append(writer, mark_name)
	pg_source_append(writer, c")")
	pg_emit_dynamic_line_end(writer)
	i = prefix_children.length
	while (i < inner_children.length):
		free(inner_children[i])
		i = i + 1
	list_free[char*](inner_children)
	free(factored_mark)
	free(factored_kind)


# Ordered choice over alternatives alt_start..alt_start+alt_count-1 from
# term offset on. Guarded units only run when the current token is in
# their first set; overlapping or unguardable units keep today's ordered
# attempt semantics simply by being tried in sequence.
void pg_emit_choice(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, int alt_start, int alt_count, int offset, list[char*] prefix_children, char* mark_name, char* kind_name):
	list[pg_choice_unit*] units = pg_plan_choice(analysis, rule, alt_start, alt_count, offset)
	int any_guarded = 0
	int i = 0
	while (i < units.length):
		if (units[i].guarded):
			any_guarded = 1
		i = i + 1
	if (any_guarded):
		pg_emit_peek_kind_line(writer, kind_name)
	i = 0
	while (i < units.length):
		pg_choice_unit* unit = units[i]
		if (unit.guarded):
			pg_emit_dynamic_line_start(writer)
			pg_source_append(writer, c"if (")
			pg_emit_kind_set_test(writer, grammar, analysis, unit.guard_set, kind_name)
			pg_source_append(writer, c"):")
			pg_emit_dynamic_line_end(writer)
			pg_source_indent(writer)
		if (unit.member_count == 1):
			pg_emit_alternative_body(writer, grammar, analysis, rule, unit.alt_start, offset, prefix_children, mark_name)
		else:
			pg_emit_factored_unit(writer, grammar, analysis, rule, unit, offset, prefix_children, mark_name)
		if (unit.guarded):
			pg_source_dedent(writer)
		i = i + 1
	pg_choice_units_free(units)


void pg_emit_rule(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_ast_node* ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_parse_")
	pg_source_append(writer, rule.name)
	pg_source_append(writer, c"(pg_token_stream* stream, pg_diagnostics* diagnostics):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_source_line(writer, c"int mark = pg_token_stream_mark(stream)")
	pg_source_line(writer, c"pg_ast_node* node = 0")
	pg_source_line(writer, c"int failed = 0")
	list[char*] prefix_children = new list[char*]
	pg_emit_choice(writer, grammar, analysis, rule, 0, rule.alternatives.length, 0, prefix_children, c"mark", c"first_kind")
	list_free[char*](prefix_children)
	pg_source_line(writer, c"return 0")
	pg_source_dedent(writer)
	pg_source_blank(writer)


void pg_emit_parse_entry(pg_source_writer* writer, pg_grammar* grammar):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_ast_node* ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_parse(char* input, char* filename, pg_diagnostics* diagnostics):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_token_stream* stream = ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_lex(input, filename, diagnostics)")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_ast_node* root = ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_parse_")
	pg_source_append(writer, grammar.start_rule)
	pg_source_append(writer, c"(stream, diagnostics)")
	pg_emit_dynamic_line_end(writer)
	pg_source_line(writer, c"if (root == 0):")
	pg_source_indent(writer)
	pg_source_line(writer, c"pg_token* found = pg_token_stream_furthest(stream)")
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_diagnostics_add(diagnostics, found.filename, found.line, found.column, c\"syntax error\", ")
	pg_emit_c_string_literal(writer, grammar.start_rule)
	pg_source_append(writer, c", found.text)")
	pg_emit_dynamic_line_end(writer)
	pg_source_dedent(writer)
	pg_source_line(writer, c"return root")
	pg_source_dedent(writer)
	pg_source_blank(writer)


# --- streaming mode (issue #329 milestone 3) --------------------------
#
# `pg_streaming_check` (analysis.w) has already proven, before any of
# this runs, that every choice in the grammar is committed dispatch and
# no ?/*/+ term names a rule (pg_generate_streaming_parser below refuses
# to emit anything otherwise). That lets rule bodies commit to an
# alternative with a single first-set test and then run its terms in a
# straight line: no mark, no rewind, anywhere. A mandatory term that
# fails is a hard syntax error -- once the guard chose this alternative
# there was never a sibling to fall back to -- so failure is a direct
# "record diagnostic, return 0" instead of AST mode's rewind-and-try-next.
#
# Callback surface: a generated <parser>_listener carries one context
# pointer plus, per rule, an on_enter_<rule>/on_exit_<rule> pair (fired
# with the token stream, so a listener can peek the token that triggered
# it) and one shared on_token, fired for every consumed token regardless
# of which rule consumed it. Any field left 0 is simply skipped. on_enter
# fires before the rule's alternative is even chosen; on_exit fires only
# once every term of the chosen alternative has matched, so a rule that
# enters but never exits is exactly the rule that failed.


void pg_emit_streaming_types(pg_source_writer* writer, pg_grammar* grammar):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"type ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_listener_fn = fn(pg_token_stream*, void*) -> void")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"type ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_token_fn = fn(pg_token*, void*) -> void")
	pg_emit_dynamic_line_end(writer)
	pg_source_blank(writer)


void pg_emit_streaming_listener_name(pg_source_writer* writer, pg_grammar* grammar):
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_listener")


void pg_emit_streaming_listener_struct(pg_source_writer* writer, pg_grammar* grammar):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"struct ")
	pg_emit_streaming_listener_name(writer, grammar)
	pg_source_append(writer, c":")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_source_line(writer, c"void* context")
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_token_fn* on_token")
	pg_emit_dynamic_line_end(writer)
	int i = 0
	while (i < grammar.rules.length):
		pg_rule* rule = grammar.rules[i]
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, grammar.name)
		pg_source_append(writer, c"_listener_fn* on_enter_")
		pg_source_append(writer, rule.name)
		pg_emit_dynamic_line_end(writer)
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, grammar.name)
		pg_source_append(writer, c"_listener_fn* on_exit_")
		pg_source_append(writer, rule.name)
		pg_emit_dynamic_line_end(writer)
		i = i + 1
	pg_source_dedent(writer)
	pg_source_blank(writer)


void pg_emit_streaming_listener_new(pg_source_writer* writer, pg_grammar* grammar):
	pg_emit_dynamic_line_start(writer)
	pg_emit_streaming_listener_name(writer, grammar)
	pg_source_append(writer, c"* ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_listener_new():")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_emit_streaming_listener_name(writer, grammar)
	pg_source_append(writer, c"* listener = new ")
	pg_emit_streaming_listener_name(writer, grammar)
	pg_source_append(writer, c"()")
	pg_emit_dynamic_line_end(writer)
	pg_source_line(writer, c"listener.context = 0")
	pg_source_line(writer, c"listener.on_token = 0")
	int i = 0
	while (i < grammar.rules.length):
		pg_rule* rule = grammar.rules[i]
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"listener.on_enter_")
		pg_source_append(writer, rule.name)
		pg_source_append(writer, c" = 0")
		pg_emit_dynamic_line_end(writer)
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"listener.on_exit_")
		pg_source_append(writer, rule.name)
		pg_source_append(writer, c" = 0")
		pg_emit_dynamic_line_end(writer)
		i = i + 1
	pg_source_line(writer, c"return listener")
	pg_source_dedent(writer)
	pg_source_blank(writer)


void pg_emit_streaming_rule_forward_declarations(pg_source_writer* writer, pg_grammar* grammar):
	int i = 0
	while (i < grammar.rules.length):
		pg_rule* rule = grammar.rules[i]
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"int ")
		pg_source_append(writer, grammar.name)
		pg_source_append(writer, c"_parse_")
		pg_source_append(writer, rule.name)
		pg_source_append(writer, c"(pg_token_stream* stream, pg_diagnostics* diagnostics, ")
		pg_emit_streaming_listener_name(writer, grammar)
		pg_source_append(writer, c"* listener);")
		pg_emit_dynamic_line_end(writer)
		i = i + 1
	pg_source_blank(writer)


# int <name>_match_token(stream, kind, listener): peeks, and on a kind
# match consumes and fires on_token. Mirrors pg_emit_match_token's
# AST-mode shape but returns a plain success flag instead of building a
# pg_ast_node -- every term emitter below (mandatory, optional, repeat)
# is built on this one primitive.
void pg_emit_streaming_match_token(pg_source_writer* writer, pg_grammar* grammar):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_match_token(pg_token_stream* stream, int kind, ")
	pg_emit_streaming_listener_name(writer, grammar)
	pg_source_append(writer, c"* listener):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_source_line(writer, c"pg_token* token = pg_token_stream_peek(stream)")
	pg_source_line(writer, c"if (token.kind == kind):")
	pg_source_indent(writer)
	pg_source_line(writer, c"pg_token_stream_consume(stream)")
	pg_source_line(writer, c"if (listener.on_token != 0):")
	pg_source_indent(writer)
	pg_source_line(writer, c"listener.on_token(token, listener.context)")
	pg_source_dedent(writer)
	pg_source_line(writer, c"return 1")
	pg_source_dedent(writer)
	pg_source_line(writer, c"return 0")
	pg_source_dedent(writer)
	pg_source_blank(writer)


# "pg_token* <var> = pg_token_stream_peek(stream); pg_diagnostics_add(...); return 0"
# -- the hard-failure path every streaming term emitter below shares.
void pg_emit_streaming_syntax_error(pg_source_writer* writer, char* var_name, char* expected):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_token* ")
	pg_source_append(writer, var_name)
	pg_source_append(writer, c" = pg_token_stream_peek(stream)")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_diagnostics_add(diagnostics, ")
	pg_source_append(writer, var_name)
	pg_source_append(writer, c".filename, ")
	pg_source_append(writer, var_name)
	pg_source_append(writer, c".line, ")
	pg_source_append(writer, var_name)
	pg_source_append(writer, c".column, c\"syntax error\", ")
	pg_emit_c_string_literal(writer, expected)
	pg_source_append(writer, c", ")
	pg_source_append(writer, var_name)
	pg_source_append(writer, c".text)")
	pg_emit_dynamic_line_end(writer)
	pg_source_line(writer, c"return 0")


# --- actions and predicates (issue #329 milestone 4) -----------------------
#
# `{ code }` action terms are verbatim W statements, one per (trimmed,
# non-empty) source line, spliced into the generated rule function at
# exactly that position -- streaming mode only, so "spliced at that
# position" already means "on the committed, straight-line path" (see
# pg_action_safety_check in analysis.w). `&{ expr }` predicate terms are a
# single boolean expression spliced as-is into an if/else-if branch
# condition by pg_emit_streaming_choice; they are handled entirely there
# and never reach pg_emit_streaming_term.
#
# Binding surface: inside an action, `$n` or `text(n)` is replaced with the
# text of term n (1-based, over the *enclosing alternative's own* term
# list, action/predicate terms included in the count) -- pg_validate_action_bindings
# below requires n to name an earlier, plain (no ?/*/+) token or literal
# term in the same alternative, so by the time pg_action_substitute runs
# every reference it sees is already known-valid.


int pg_action_matches_text_call(char* code, int i, int length):
	if (i > 0):
		if (pg_lexer_is_ident_part(code[i - 1] & 255)):
			return 0
	return starts_with(code + i, c"text(")


# Every $n/text(n) reference in an action's code, as the 1-based n values
# referenced (duplicates allowed; order not significant to callers).
list[int] pg_action_scan_refs(char* code):
	list[int] refs = new list[int]
	int length = strlen(code)
	int i = 0
	while (i < length):
		int c = code[i] & 255
		if ((c == '"') || (c == 39)):
			int quote = c
			i = i + 1
			while ((i < length) && (code[i] != quote)):
				if (code[i] == 92):
					i = i + 1
					if (i < length):
						i = i + 1
				else:
					i = i + 1
			if ((i < length) && (code[i] == quote)):
				i = i + 1
		else if (c == '$'):
			int j = i + 1
			int n = 0
			int has_digit = 0
			while ((j < length) && (code[j] >= '0') && (code[j] <= '9')):
				n = n * 10 + (code[j] - '0')
				has_digit = 1
				j = j + 1
			if (has_digit):
				refs.push(n)
				i = j
			else:
				i = i + 1
		else if ((c == 't') && pg_action_matches_text_call(code, i, length)):
			int j = i + 5
			int n = 0
			int has_digit = 0
			while ((j < length) && (code[j] >= '0') && (code[j] <= '9')):
				n = n * 10 + (code[j] - '0')
				has_digit = 1
				j = j + 1
			if (has_digit && (j < length) && (code[j] == ')')):
				refs.push(n)
				i = j + 1
			else:
				i = i + 1
		else:
			i = i + 1
	return refs


# code with every $n/text(n) replaced by "action_arg_<alt_index>_<n-1>.text"
# -- the same "action_arg_" + alt + "_" + term naming pg_emit_streaming_term
# uses below when it captures a referenced token. Caller frees the result.
char* pg_action_substitute(char* code, int alt_index):
	string_builder* out = string_new()
	int length = strlen(code)
	int i = 0
	while (i < length):
		int c = code[i] & 255
		if ((c == '"') || (c == 39)):
			int quote = c
			string_append_char(out, c)
			i = i + 1
			while ((i < length) && (code[i] != quote)):
				if (code[i] == 92):
					string_append_char(out, code[i])
					i = i + 1
					if (i < length):
						string_append_char(out, code[i])
						i = i + 1
				else:
					string_append_char(out, code[i])
					i = i + 1
			if ((i < length) && (code[i] == quote)):
				string_append_char(out, code[i])
				i = i + 1
		else if (c == '$'):
			int j = i + 1
			int n = 0
			int has_digit = 0
			while ((j < length) && (code[j] >= '0') && (code[j] <= '9')):
				n = n * 10 + (code[j] - '0')
				has_digit = 1
				j = j + 1
			if (has_digit):
				string_append(out, c"action_arg_")
				string_append_int(out, alt_index)
				string_append(out, c"_")
				string_append_int(out, n - 1)
				string_append(out, c".text")
				i = j
			else:
				string_append_char(out, '$')
				i = i + 1
		else if ((c == 't') && pg_action_matches_text_call(code, i, length)):
			int j = i + 5
			int n = 0
			int has_digit = 0
			while ((j < length) && (code[j] >= '0') && (code[j] <= '9')):
				n = n * 10 + (code[j] - '0')
				has_digit = 1
				j = j + 1
			if (has_digit && (j < length) && (code[j] == ')')):
				string_append(out, c"action_arg_")
				string_append_int(out, alt_index)
				string_append(out, c"_")
				string_append_int(out, n - 1)
				string_append(out, c".text")
				i = j + 1
			else:
				string_append_char(out, code[i])
				i = i + 1
		else:
			string_append_char(out, c)
			i = i + 1
	char* text = out.data
	free(out)
	return text


char* pg_action_trim(char* text):
	int start = 0
	while (pg_lexer_is_space(text[start])):
		start = start + 1
	int end = strlen(text)
	while ((end > start) && pg_lexer_is_space(text[end - 1])):
		end = end - 1
	return pg_substr(text, start, end - start)


# Split trimmed code into non-empty, individually trimmed lines -- the
# "flat statements only" contract documented in parser_generator.md: each
# line becomes one pg_source_line at the writer's current indent, so an
# action body may not itself open a nested indented block (if/while/etc).
list[char*] pg_action_split_lines(char* code):
	list[char*] lines = new list[char*]
	int length = strlen(code)
	int start = 0
	int i = 0
	while (i <= length):
		if ((i == length) || (code[i] == 10)):
			char* raw = pg_substr(code, start, i - start)
			char* trimmed = pg_action_trim(raw)
			free(raw)
			if (strlen(trimmed) > 0):
				lines.push(trimmed)
			else:
				free(trimmed)
			start = i + 1
		i = i + 1
	return lines


void pg_emit_streaming_action(pg_source_writer* writer, pg_term* term, int alt_index, int term_index):
	char* substituted = pg_action_substitute(term.code, alt_index)
	list[char*] lines = pg_action_split_lines(substituted)
	int i = 0
	while (i < lines.length):
		pg_source_line(writer, lines[i])
		free(lines[i])
		i = i + 1
	list_free[char*](lines)
	free(substituted)


# 1-indexed (size terms.length + 1, index 0 unused) membership set of term
# positions that some action in this alternative captures via $n/text(n).
# Only ever called once pg_validate_action_bindings has passed, so every
# referenced n is already known to be in range and to name a plain token
# term earlier in the same alternative.
char* pg_alt_capture_set(pg_alternative* alternative):
	char* captures = malloc(alternative.terms.length + 1)
	int i = 0
	while (i <= alternative.terms.length):
		captures[i] = 0
		i = i + 1
	i = 0
	while (i < alternative.terms.length):
		pg_term* term = alternative.terms[i]
		if (term.kind == pg_term_kind_action()):
			list[int] refs = pg_action_scan_refs(term.code)
			int r = 0
			while (r < refs.length):
				int n = refs[r]
				if ((n >= 1) && (n <= alternative.terms.length)):
					captures[n] = 1
				r = r + 1
			list_free[int](refs)
		i = i + 1
	return captures


# A single term within a chosen alternative. Streaming eligibility
# (pg_streaming_check) has already ruled out ?/*/+ over a rule reference,
# so the modifier cases below only ever guard a token/literal -- always
# safe to test with zero lookahead cost via <name>_match_token. captures
# may be 0 (never capture -- used for a left-factored shared prefix, which
# pg_validate_action_bindings guarantees carries no $n/text(n) references).
void pg_emit_streaming_term(pg_source_writer* writer, pg_grammar* grammar, char* captures, pg_term* term, int alt_index, int term_index):
	if (term.kind == pg_term_kind_action()):
		pg_emit_streaming_action(writer, term, alt_index, term_index)
		return
	if (term.modifier == 0):
		if (pg_grammar_is_token_term(grammar, term.name)):
			if ((captures != 0) && (captures[term_index + 1] != 0)):
				pg_emit_dynamic_line_start(writer)
				pg_source_append(writer, c"pg_token* ")
				pg_emit_var(writer, c"action_arg_", alt_index, term_index)
				pg_source_append(writer, c" = pg_token_stream_peek(stream)")
				pg_emit_dynamic_line_end(writer)
			pg_emit_dynamic_line_start(writer)
			pg_source_append(writer, c"if (")
			pg_source_append(writer, grammar.name)
			pg_source_append(writer, c"_match_token(stream, ")
			pg_emit_token_kind_call(writer, grammar, term.name)
			pg_source_append(writer, c", listener) == 0):")
			pg_emit_dynamic_line_end(writer)
			pg_source_indent(writer)
			char* var_name = pg_guard_var_name(c"stream_err_", alt_index, term_index)
			pg_emit_streaming_syntax_error(writer, var_name, term.name)
			free(var_name)
			pg_source_dedent(writer)
		else:
			pg_emit_dynamic_line_start(writer)
			pg_source_append(writer, c"if (")
			pg_source_append(writer, grammar.name)
			pg_source_append(writer, c"_parse_")
			pg_source_append(writer, term.name)
			pg_source_append(writer, c"(stream, diagnostics, listener) == 0):")
			pg_emit_dynamic_line_end(writer)
			pg_source_indent(writer)
			pg_source_line(writer, c"return 0")
			pg_source_dedent(writer)
	else if (term.modifier == '?'):
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, grammar.name)
		pg_source_append(writer, c"_match_token(stream, ")
		pg_emit_token_kind_call(writer, grammar, term.name)
		pg_source_append(writer, c", listener)")
		pg_emit_dynamic_line_end(writer)
	else:
		# '*' or '+'
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"int ")
		pg_emit_var(writer, c"repeat_count_", alt_index, term_index)
		pg_source_append(writer, c" = 0")
		pg_emit_dynamic_line_end(writer)
		pg_emit_dynamic_line_start(writer)
		pg_source_append(writer, c"while (")
		pg_source_append(writer, grammar.name)
		pg_source_append(writer, c"_match_token(stream, ")
		pg_emit_token_kind_call(writer, grammar, term.name)
		pg_source_append(writer, c", listener)):")
		pg_emit_dynamic_line_end(writer)
		pg_source_indent(writer)
		pg_emit_dynamic_line_start(writer)
		pg_emit_var(writer, c"repeat_count_", alt_index, term_index)
		pg_source_append(writer, c" = ")
		pg_emit_var(writer, c"repeat_count_", alt_index, term_index)
		pg_source_append(writer, c" + 1")
		pg_emit_dynamic_line_end(writer)
		pg_source_dedent(writer)
		if (term.modifier == '+'):
			pg_emit_dynamic_line_start(writer)
			pg_source_append(writer, c"if (")
			pg_emit_var(writer, c"repeat_count_", alt_index, term_index)
			pg_source_append(writer, c" == 0):")
			pg_emit_dynamic_line_end(writer)
			pg_source_indent(writer)
			char* var_name = pg_guard_var_name(c"stream_err_", alt_index, term_index)
			pg_emit_streaming_syntax_error(writer, var_name, term.name)
			free(var_name)
			pg_source_dedent(writer)


void pg_emit_streaming_alternative_body(pg_source_writer* writer, pg_grammar* grammar, pg_rule* rule, int alt_index, int offset):
	pg_alternative* alternative = rule.alternatives[alt_index]
	if (offset >= alternative.terms.length):
		# The empty/epsilon alternative (e.g. a trailing unguarded
		# fallback unit, see pg_emit_streaming_choice): nothing to match,
		# so make the no-op explicit instead of emitting an empty block.
		pg_source_line(writer, c"pass")
		return
	char* captures = pg_alt_capture_set(alternative)
	int term_index = offset
	while (term_index < alternative.terms.length):
		pg_emit_streaming_term(writer, grammar, captures, alternative.terms[term_index], alt_index, term_index)
		term_index = term_index + 1
	free(captures)


void pg_emit_streaming_choice(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, int alt_start, int alt_count, int offset, char* kind_name);


# A left-factored run, streaming mode: parse the shared prefix once (each
# term mandatory-style, per pg_emit_streaming_term) then recurse into the
# suffix choice -- no mark, nothing to rewind to on failure since a
# prefix-term failure is already a hard error by the time control would
# reach here.
void pg_emit_streaming_factored_unit(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, pg_choice_unit* unit, int offset):
	pg_alternative* head = rule.alternatives[unit.alt_start]
	int term_index = offset
	while (term_index < offset + unit.prefix_length):
		# 0 (no captures): pg_validate_action_bindings rejects any
		# $n/text(n) reference inside an alternative that shares a
		# leading term with a sibling, so a shared prefix never needs to
		# capture a token for a later action to bind.
		pg_emit_streaming_term(writer, grammar, 0, head.terms[term_index], unit.alt_start, term_index)
		term_index = term_index + 1
	char* inner_kind = pg_guard_var_name(c"factored_kind_", unit.alt_start, offset)
	pg_emit_streaming_choice(writer, grammar, analysis, rule, unit.alt_start, unit.member_count, offset + unit.prefix_length, inner_kind)
	free(inner_kind)


# Ordered choice, streaming mode. pg_streaming_check has already proven
# every unit here is guarded, predicate-headed, or (possibly, only last)
# an unguarded nullable "epsilon" fallback (mirrors pg_report_choice's
# empty-suffix and predicate exemptions in analysis.w). Guarded and
# predicate-headed units become an if/else-if chain, in declaration order,
# on the current token kind or the predicate expression respectively; the
# final branch is either that fallback's (empty) body or, when every unit
# was guarded/predicated, a syntax error -- there is no other outcome left
# once none of the branches match. A predicate-headed unit's body starts
# one term past the predicate itself, since the predicate was already
# consumed as this branch's condition rather than as a matched term.
void pg_emit_streaming_choice(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, int alt_start, int alt_count, int offset, char* kind_name):
	list[pg_choice_unit*] units = pg_plan_choice(analysis, rule, alt_start, alt_count, offset)
	if ((units.length == 1) && (units[0].predicate_code == 0)):
		pg_choice_unit* unit = units[0]
		if (unit.member_count == 1):
			pg_emit_streaming_alternative_body(writer, grammar, rule, unit.alt_start, offset)
		else:
			pg_emit_streaming_factored_unit(writer, grammar, analysis, rule, unit, offset)
		pg_choice_units_free(units)
		return
	int has_fallback = (units[units.length - 1].guarded == 0) && (units[units.length - 1].predicate_code == 0)
	int needs_kind = 0
	int i = 0
	while (i < units.length):
		int is_fallback = has_fallback && (i == units.length - 1)
		if ((is_fallback == 0) && (units[i].predicate_code == 0)):
			needs_kind = 1
		i = i + 1
	if (needs_kind):
		pg_emit_peek_kind_line(writer, kind_name)
	i = 0
	while (i < units.length):
		pg_choice_unit* unit = units[i]
		int is_fallback = has_fallback && (i == units.length - 1)
		if (is_fallback == 0):
			pg_emit_dynamic_line_start(writer)
			if (i == 0):
				pg_source_append(writer, c"if (")
			else:
				pg_source_append(writer, c"else if (")
			if (unit.predicate_code != 0):
				pg_source_append(writer, unit.predicate_code)
			else:
				pg_emit_kind_set_test(writer, grammar, analysis, unit.guard_set, kind_name)
			pg_source_append(writer, c"):")
			pg_emit_dynamic_line_end(writer)
		else:
			pg_source_line(writer, c"else:")
		pg_source_indent(writer)
		int body_offset = offset
		if (unit.predicate_code != 0):
			body_offset = offset + 1
		if (unit.member_count == 1):
			pg_emit_streaming_alternative_body(writer, grammar, rule, unit.alt_start, body_offset)
		else:
			pg_emit_streaming_factored_unit(writer, grammar, analysis, rule, unit, offset)
		pg_source_dedent(writer)
		i = i + 1
	if (has_fallback == 0):
		pg_source_line(writer, c"else:")
		pg_source_indent(writer)
		char* var_name = pg_guard_var_name(c"stream_err_", alt_start, offset)
		pg_emit_streaming_syntax_error(writer, var_name, rule.name)
		free(var_name)
		pg_source_dedent(writer)
	pg_choice_units_free(units)


void pg_emit_streaming_rule(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_parse_")
	pg_source_append(writer, rule.name)
	pg_source_append(writer, c"(pg_token_stream* stream, pg_diagnostics* diagnostics, ")
	pg_emit_streaming_listener_name(writer, grammar)
	pg_source_append(writer, c"* listener):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"if (listener.on_enter_")
	pg_source_append(writer, rule.name)
	pg_source_append(writer, c" != 0):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"listener.on_enter_")
	pg_source_append(writer, rule.name)
	pg_source_append(writer, c"(stream, listener.context)")
	pg_emit_dynamic_line_end(writer)
	pg_source_dedent(writer)
	pg_emit_streaming_choice(writer, grammar, analysis, rule, 0, rule.alternatives.length, 0, c"first_kind")
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"if (listener.on_exit_")
	pg_source_append(writer, rule.name)
	pg_source_append(writer, c" != 0):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"listener.on_exit_")
	pg_source_append(writer, rule.name)
	pg_source_append(writer, c"(stream, listener.context)")
	pg_emit_dynamic_line_end(writer)
	pg_source_dedent(writer)
	pg_source_line(writer, c"return 1")
	pg_source_dedent(writer)
	pg_source_blank(writer)


# The grammar's start rule is expected to end with an EOF term (the
# convention AST mode's sample grammars already use), so there is
# nothing extra to check here: whatever the start rule returns is the
# answer.
void pg_emit_streaming_parse_entry(pg_source_writer* writer, pg_grammar* grammar):
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"int ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_parse_streaming(char* input, char* filename, pg_diagnostics* diagnostics, ")
	pg_emit_streaming_listener_name(writer, grammar)
	pg_source_append(writer, c"* listener):")
	pg_emit_dynamic_line_end(writer)
	pg_source_indent(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"pg_token_stream* stream = ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_lex(input, filename, diagnostics)")
	pg_emit_dynamic_line_end(writer)
	pg_emit_dynamic_line_start(writer)
	pg_source_append(writer, c"return ")
	pg_source_append(writer, grammar.name)
	pg_source_append(writer, c"_parse_")
	pg_source_append(writer, grammar.start_rule)
	pg_source_append(writer, c"(stream, diagnostics, listener)")
	pg_emit_dynamic_line_end(writer)
	pg_source_dedent(writer)
	pg_source_blank(writer)


# --- action/predicate binding validation (issue #329 milestone 4) ---------
#
# $n/text(n) is deliberately narrow (per docs/projects/parser_generator.md):
# it names the text of an earlier, plain (no ?/*/+) token or literal term
# in the *same* alternative. This also sidesteps a real complication: an
# alternative that shares a leading term with a sibling gets left-factored
# (analysis.w's pg_plan_choice), so its shared-prefix terms are parsed
# once under the factored unit's representative alt_start, not the
# member's own true alternative index -- pg_action_substitute has no way
# to know that renaming without duplicating pg_plan_choice's own factoring
# decision. Rather than do that, an action with any binding is rejected
# outright when its alternative could ever be factored with a sibling;
# rewrite the rule to avoid the shared leading term if this fires.


int pg_alt_shares_leading_term(pg_rule* rule, int alt_index):
	pg_alternative* alternative = rule.alternatives[alt_index]
	if (alternative.terms.length == 0):
		return 0
	pg_term* first = alternative.terms[0]
	if (first.kind != pg_term_kind_normal()):
		return 0
	int i = 0
	while (i < rule.alternatives.length):
		if (i != alt_index):
			pg_alternative* other = rule.alternatives[i]
			if (other.terms.length > 0):
				pg_term* other_first = other.terms[0]
				if (other_first.kind == pg_term_kind_normal()):
					if ((other_first.modifier == first.modifier) && (strcmp(other_first.name, first.name) == 0)):
						return 1
		i = i + 1
	return 0


# Validates every $n/text(n) reference in one action term; returns the
# number of violations printed (0 == every reference in this action is
# sound). alt_index is the action's enclosing alternative's own index in
# rule.alternatives (needed only for the shared-leading-term check).
int pg_validate_action_term_bindings(pg_grammar* grammar, pg_rule* rule, pg_alternative* alternative, int alt_index, int action_index):
	pg_term* action = alternative.terms[action_index]
	list[int] refs = pg_action_scan_refs(action.code)
	int violations = 0
	if ((refs.length > 0) && pg_alt_shares_leading_term(rule, alt_index)):
		print2(c"parser_generator: rule ")
		print2(rule.name)
		println2(c": an action's $n/text(n) binding is not supported in an alternative that shares a leading term with a sibling (left-factoring) -- rewrite the rule to avoid the shared prefix")
		violations = violations + 1
	int i = 0
	while (i < refs.length):
		int n = refs[i]
		int ok = 1
		if ((n < 1) || (n > alternative.terms.length)):
			ok = 0
		else:
			pg_term* ref_term = alternative.terms[n - 1]
			if (ref_term.kind != pg_term_kind_normal()):
				ok = 0
			else if (ref_term.modifier != 0):
				ok = 0
			else if (pg_grammar_is_token_term(grammar, ref_term.name) == 0):
				ok = 0
			else if ((n - 1) >= action_index):
				ok = 0
		if (ok == 0):
			print2(c"parser_generator: rule ")
			print2(rule.name)
			print2(c": action references invalid binding $")
			print2(itoa(n))
			println2(c" (must name an earlier plain token or literal term in the same alternative)")
			violations = violations + 1
		i = i + 1
	list_free[int](refs)
	return violations


int pg_validate_action_bindings(pg_grammar* grammar):
	int violations = 0
	int r = 0
	while (r < grammar.rules.length):
		pg_rule* rule = grammar.rules[r]
		int a = 0
		while (a < rule.alternatives.length):
			pg_alternative* alternative = rule.alternatives[a]
			int t = 0
			while (t < alternative.terms.length):
				if (alternative.terms[t].kind == pg_term_kind_action()):
					violations = violations + pg_validate_action_term_bindings(grammar, rule, alternative, a, t)
				t = t + 1
			a = a + 1
		r = r + 1
	return violations


char* pg_generate_streaming_parser(pg_grammar* grammar):
	if (pg_action_safety_check(grammar) > 0):
		return 0
	if (pg_validate_action_bindings(grammar) > 0):
		return 0
	if (pg_streaming_check(grammar) > 0):
		return 0
	pg_analysis* analysis = pg_analyze_grammar(grammar)
	pg_source_writer* writer = pg_source_writer_new()
	pg_source_line(writer, c"/* generated by ParserGenerator (streaming mode) */")
	pg_source_line(writer, c"import lib.lib")
	pg_source_line(writer, c"import libs.extras.parser_generator.runtime")
	pg_source_blank(writer)
	pg_emit_grammar_imports(writer, grammar)
	pg_emit_token_constants(writer, grammar)
	pg_emit_token_name(writer, grammar)
	pg_emit_streaming_types(writer, grammar)
	pg_emit_streaming_listener_struct(writer, grammar)
	pg_emit_streaming_listener_new(writer, grammar)
	pg_emit_matcher_forward_declarations(writer, grammar)
	pg_emit_streaming_rule_forward_declarations(writer, grammar)
	pg_emit_expression_matchers(writer, grammar)
	pg_emit_advance_position(writer, grammar)
	pg_emit_lexer(writer, grammar)
	pg_emit_streaming_match_token(writer, grammar)
	int i = 0
	while (i < grammar.rules.length):
		pg_emit_streaming_rule(writer, grammar, analysis, grammar.rules[i])
		i = i + 1
	pg_emit_streaming_parse_entry(writer, grammar)
	pg_analysis_free(analysis)
	return pg_source_take(writer)


char* pg_generate_ast_parser(pg_grammar* grammar):
	if (pg_action_safety_check(grammar) > 0):
		return 0
	pg_analysis* analysis = pg_analyze_grammar(grammar)
	pg_source_writer* writer = pg_source_writer_new()
	pg_source_line(writer, c"/* generated by ParserGenerator */")
	pg_source_line(writer, c"import lib.lib")
	pg_source_line(writer, c"import libs.extras.parser_generator.runtime")
	pg_source_blank(writer)
	pg_emit_grammar_imports(writer, grammar)
	pg_emit_token_constants(writer, grammar)
	pg_emit_ast_constants(writer, grammar)
	pg_emit_token_name(writer, grammar)
	pg_emit_forward_declarations(writer, grammar)
	pg_emit_expression_matchers(writer, grammar)
	pg_emit_advance_position(writer, grammar)
	pg_emit_lexer(writer, grammar)
	pg_emit_match_token(writer, grammar)
	int i = 0
	while (i < grammar.rules.length):
		pg_emit_rule(writer, grammar, analysis, grammar.rules[i])
		i = i + 1
	pg_emit_parse_entry(writer, grammar)
	pg_analysis_free(analysis)
	return pg_source_take(writer)


char* pg_generate_parser(pg_grammar* grammar):
	if (grammar.mode == pg_grammar_mode_streaming()):
		return pg_generate_streaming_parser(grammar)
	return pg_generate_ast_parser(grammar)
