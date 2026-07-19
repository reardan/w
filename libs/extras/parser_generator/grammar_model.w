/*
In-memory grammar model for the first ParserGenerator milestone.

The grammar language supports named lexer helpers and inline matcher
expressions:
	parser <name>
	token <NAME> <letters|digits|identifier|any>
	token <NAME> = <matcher expression>
	skip <NAME> <line_comment|block_comment>
	fragment <NAME> = <matcher expression>
	literal <NAME> "<text>"
	rule <name> = TERM* (| TERM*)*

Terms are rule names, token names, literal names, or EOF. A term may end with
?, * or +. Parenthesized groups are reserved for a later milestone.
*/
import lib.lib
import lib.container


int pg_match_expr_string_kind():
	return 1


int pg_match_expr_charset_kind():
	return 2


int pg_match_expr_reference_kind():
	return 3


int pg_match_expr_sequence_kind():
	return 4


int pg_match_expr_alternation_kind():
	return 5


int pg_match_expr_optional_kind():
	return 6


int pg_match_expr_zero_or_more_kind():
	return 7


int pg_match_expr_one_or_more_kind():
	return 8


struct pg_match_expr:
	int kind
	char* text
	char* charset
	list[pg_match_expr*] children
	int line
	int column


struct pg_token_def:
	char* name
	char* matcher
	pg_match_expr* expression
	int kind


struct pg_fragment_def:
	char* name
	pg_match_expr* expression


struct pg_literal_def:
	char* name
	char* text
	int kind


struct pg_term:
	char* name
	int modifier


struct pg_alternative:
	list[pg_term*] terms


struct pg_rule:
	char* name
	list[pg_alternative*] alternatives
	int kind


# Error-recovery policy from a "recover <rule> <sync> [<skip>...]" directive.
# Repetitions (*/+) of rule_name resynchronize on failure: the parser reports
# a diagnostic, then consumes tokens through the next sync token whose
# successor is neither the sync token nor one of the skip tokens, wraps the
# skipped tokens in an "error" node, and resumes the repetition.
struct pg_recover_def:
	char* rule_name
	char* sync_token
	list[char*] skip_tokens


# Generation mode selected by the grammar's optional "mode" directive
# (issue #329 milestone 3). AST mode (the default) builds a pg_ast_node
# tree via ordered-choice backtracking, unchanged from before this
# milestone. Streaming mode never marks/rewinds the token stream: it is
# only legal when analysis.w's pg_streaming_check proves the whole
# grammar is committed dispatch, and it emits listener callbacks
# (enter/exit rule, token events) instead of AST nodes. See
# docs/projects/parser_generator.md.
int pg_grammar_mode_ast():
	return 0


int pg_grammar_mode_streaming():
	return 1


# tokens/skips are separate lists sharing the same element type: tokens
# produce default-channel tokens, skips hidden-channel ones (see
# pg_grammar_add_skip's negative kind numbering).
struct pg_grammar:
	char* name
	char* start_rule
	int mode
	list[pg_token_def*] tokens
	list[pg_token_def*] skips
	list[pg_fragment_def*] fragments
	list[pg_literal_def*] literals
	list[pg_rule*] rules
	list[pg_recover_def*] recovers


pg_grammar* pg_grammar_new(char* name):
	pg_grammar* grammar = new pg_grammar()
	grammar.name = strclone(name)
	grammar.start_rule = 0
	grammar.mode = pg_grammar_mode_ast()
	grammar.tokens = new list[pg_token_def*]
	grammar.skips = new list[pg_token_def*]
	grammar.fragments = new list[pg_fragment_def*]
	grammar.literals = new list[pg_literal_def*]
	grammar.rules = new list[pg_rule*]
	grammar.recovers = new list[pg_recover_def*]
	return grammar


pg_match_expr* pg_match_expr_new(int kind, int line, int column):
	pg_match_expr* expression = new pg_match_expr()
	expression.kind = kind
	expression.text = 0
	expression.charset = 0
	expression.children = new list[pg_match_expr*]
	expression.line = line
	expression.column = column
	return expression


pg_match_expr* pg_match_expr_text_new(int kind, char* text, int line, int column):
	pg_match_expr* expression = pg_match_expr_new(kind, line, column)
	expression.text = strclone(text)
	return expression


pg_match_expr* pg_match_expr_charset_new(char* charset, int line, int column):
	pg_match_expr* expression = pg_match_expr_new(pg_match_expr_charset_kind(), line, column)
	expression.charset = malloc(128)
	int i = 0
	while (i < 128):
		expression.charset[i] = charset[i]
		i = i + 1
	return expression


pg_match_expr* pg_match_expr_unary_new(int kind, pg_match_expr* child, int line, int column):
	pg_match_expr* expression = pg_match_expr_new(kind, line, column)
	expression.children.push(child)
	return expression


void pg_match_expr_add(pg_match_expr* expression, pg_match_expr* child):
	expression.children.push(child)


pg_token_def* pg_token_def_new(char* name, char* matcher, int kind):
	pg_token_def* token = new pg_token_def()
	token.name = strclone(name)
	token.matcher = 0
	if (matcher != 0):
		token.matcher = strclone(matcher)
	token.expression = 0
	token.kind = kind
	return token


pg_fragment_def* pg_fragment_def_new(char* name, pg_match_expr* expression):
	pg_fragment_def* fragment = new pg_fragment_def()
	fragment.name = strclone(name)
	fragment.expression = expression
	return fragment


pg_literal_def* pg_literal_def_new(char* name, char* text, int kind):
	pg_literal_def* literal = new pg_literal_def()
	literal.name = strclone(name)
	literal.text = strclone(text)
	literal.kind = kind
	return literal


pg_rule* pg_rule_new(char* name, int kind):
	pg_rule* rule = new pg_rule()
	rule.name = strclone(name)
	rule.alternatives = new list[pg_alternative*]
	rule.kind = kind
	return rule


pg_alternative* pg_alternative_new():
	pg_alternative* alternative = new pg_alternative()
	alternative.terms = new list[pg_term*]
	return alternative


pg_term* pg_term_new(char* name, int modifier):
	pg_term* term = new pg_term()
	term.name = strclone(name)
	term.modifier = modifier
	return term


pg_recover_def* pg_recover_def_new(char* rule_name, char* sync_token):
	pg_recover_def* recover = new pg_recover_def()
	recover.rule_name = strclone(rule_name)
	recover.sync_token = strclone(sync_token)
	recover.skip_tokens = new list[char*]
	return recover


pg_token_def* pg_grammar_add_token(pg_grammar* grammar, char* name, char* matcher):
	pg_token_def* token = pg_token_def_new(name, matcher, grammar.tokens.length + grammar.literals.length + 1)
	grammar.tokens.push(token)
	return token


pg_token_def* pg_grammar_add_token_expression(pg_grammar* grammar, char* name, pg_match_expr* expression):
	pg_token_def* token = pg_token_def_new(name, 0, grammar.tokens.length + grammar.literals.length + 1)
	token.expression = expression
	grammar.tokens.push(token)
	return token


# Skip rules produce hidden-channel tokens. They get negative kinds starting
# at -3 (-1 is the invalid kind, -2 the whitespace kind) so they never collide
# with EOF (0) or the positive token/literal kinds.
pg_token_def* pg_grammar_add_skip(pg_grammar* grammar, char* name, char* matcher):
	pg_token_def* token = pg_token_def_new(name, matcher, 0 - grammar.skips.length - 3)
	grammar.skips.push(token)
	return token


pg_token_def* pg_grammar_add_skip_expression(pg_grammar* grammar, char* name, pg_match_expr* expression):
	pg_token_def* token = pg_token_def_new(name, 0, 0 - grammar.skips.length - 3)
	token.expression = expression
	grammar.skips.push(token)
	return token


pg_fragment_def* pg_grammar_add_fragment(pg_grammar* grammar, char* name, pg_match_expr* expression):
	pg_fragment_def* fragment = pg_fragment_def_new(name, expression)
	grammar.fragments.push(fragment)
	return fragment


pg_literal_def* pg_grammar_add_literal(pg_grammar* grammar, char* name, char* text):
	pg_literal_def* literal = pg_literal_def_new(name, text, grammar.tokens.length + grammar.literals.length + 1)
	grammar.literals.push(literal)
	return literal


pg_recover_def* pg_grammar_add_recover(pg_grammar* grammar, char* rule_name, char* sync_token):
	pg_recover_def* recover = pg_recover_def_new(rule_name, sync_token)
	grammar.recovers.push(recover)
	return recover


void pg_recover_add_skip(pg_recover_def* recover, char* token_name):
	recover.skip_tokens.push(strclone(token_name))


pg_recover_def* pg_grammar_find_recover(pg_grammar* grammar, char* rule_name):
	int i = 0
	while (i < grammar.recovers.length):
		pg_recover_def* recover = grammar.recovers[i]
		if (strcmp(recover.rule_name, rule_name) == 0):
			return recover
		i = i + 1
	return 0


pg_rule* pg_grammar_add_rule(pg_grammar* grammar, char* name):
	pg_rule* rule = pg_rule_new(name, grammar.rules.length + 1)
	if (grammar.start_rule == 0):
		grammar.start_rule = strclone(name)
	grammar.rules.push(rule)
	return rule


void pg_rule_add_alternative(pg_rule* rule, pg_alternative* alternative):
	rule.alternatives.push(alternative)


void pg_alternative_add_term(pg_alternative* alternative, pg_term* term):
	alternative.terms.push(term)


pg_token_def* pg_grammar_find_token(pg_grammar* grammar, char* name):
	int i = 0
	while (i < grammar.tokens.length):
		pg_token_def* token = grammar.tokens[i]
		if (strcmp(token.name, name) == 0):
			return token
		i = i + 1
	return 0


pg_fragment_def* pg_grammar_find_fragment(pg_grammar* grammar, char* name):
	int i = 0
	while (i < grammar.fragments.length):
		pg_fragment_def* fragment = grammar.fragments[i]
		if (strcmp(fragment.name, name) == 0):
			return fragment
		i = i + 1
	return 0


pg_literal_def* pg_grammar_find_literal(pg_grammar* grammar, char* name):
	int i = 0
	while (i < grammar.literals.length):
		pg_literal_def* literal = grammar.literals[i]
		if (strcmp(literal.name, name) == 0):
			return literal
		i = i + 1
	return 0


pg_rule* pg_grammar_find_rule(pg_grammar* grammar, char* name):
	int i = 0
	while (i < grammar.rules.length):
		pg_rule* rule = grammar.rules[i]
		if (strcmp(rule.name, name) == 0):
			return rule
		i = i + 1
	return 0


int pg_grammar_is_token_term(pg_grammar* grammar, char* name):
	if (strcmp(name, c"EOF") == 0):
		return 1
	if (pg_grammar_find_token(grammar, name) != 0):
		return 1
	if (pg_grammar_find_literal(grammar, name) != 0):
		return 1
	return 0


int pg_grammar_token_kind(pg_grammar* grammar, char* name):
	if (strcmp(name, c"EOF") == 0):
		return 0
	pg_token_def* token = pg_grammar_find_token(grammar, name)
	if (token != 0):
		return token.kind
	pg_literal_def* literal = pg_grammar_find_literal(grammar, name)
	if (literal != 0):
		return literal.kind
	return -1


void pg_term_free(pg_term* term):
	free(term.name)
	free(term)


void pg_alternative_free(pg_alternative* alternative):
	int i = 0
	while (i < alternative.terms.length):
		pg_term_free(alternative.terms[i])
		i = i + 1
	list_free[pg_term*](alternative.terms)
	free(alternative)


void pg_rule_free(pg_rule* rule):
	int i = 0
	while (i < rule.alternatives.length):
		pg_alternative_free(rule.alternatives[i])
		i = i + 1
	free(rule.name)
	list_free[pg_alternative*](rule.alternatives)
	free(rule)


void pg_match_expr_free(pg_match_expr* expression):
	if (expression == 0):
		return
	int i = 0
	while (i < expression.children.length):
		pg_match_expr_free(expression.children[i])
		i = i + 1
	if (expression.text != 0):
		free(expression.text)
	if (expression.charset != 0):
		free(expression.charset)
	list_free[pg_match_expr*](expression.children)
	free(expression)


void pg_token_def_free(pg_token_def* token):
	free(token.name)
	if (token.matcher != 0):
		free(token.matcher)
	if (token.expression != 0):
		pg_match_expr_free(token.expression)
	free(token)


void pg_fragment_def_free(pg_fragment_def* fragment):
	free(fragment.name)
	pg_match_expr_free(fragment.expression)
	free(fragment)


void pg_literal_def_free(pg_literal_def* literal):
	free(literal.name)
	free(literal.text)
	free(literal)


void pg_recover_def_free(pg_recover_def* recover):
	free(recover.rule_name)
	free(recover.sync_token)
	int i = 0
	while (i < recover.skip_tokens.length):
		free(recover.skip_tokens[i])
		i = i + 1
	list_free[char*](recover.skip_tokens)
	free(recover)


void pg_grammar_free(pg_grammar* grammar):
	if (grammar == 0):
		return
	int i = 0
	while (i < grammar.tokens.length):
		pg_token_def_free(grammar.tokens[i])
		i = i + 1
	i = 0
	while (i < grammar.skips.length):
		pg_token_def_free(grammar.skips[i])
		i = i + 1
	i = 0
	while (i < grammar.fragments.length):
		pg_fragment_def_free(grammar.fragments[i])
		i = i + 1
	i = 0
	while (i < grammar.literals.length):
		pg_literal_def_free(grammar.literals[i])
		i = i + 1
	i = 0
	while (i < grammar.rules.length):
		pg_rule_free(grammar.rules[i])
		i = i + 1
	i = 0
	while (i < grammar.recovers.length):
		pg_recover_def_free(grammar.recovers[i])
		i = i + 1
	free(grammar.name)
	if (grammar.start_rule != 0):
		free(grammar.start_rule)
	list_free[pg_token_def*](grammar.tokens)
	list_free[pg_token_def*](grammar.skips)
	list_free[pg_fragment_def*](grammar.fragments)
	list_free[pg_literal_def*](grammar.literals)
	list_free[pg_rule*](grammar.rules)
	list_free[pg_recover_def*](grammar.recovers)
	free(grammar)
