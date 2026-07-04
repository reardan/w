/*
In-memory grammar model for the first ParserGenerator milestone.

The initial grammar language is intentionally small:
	parser <name>
	token <NAME> <letters|digits|identifier|any>
	skip <NAME> <line_comment|block_comment>
	literal <NAME> "<text>"
	rule <name> = TERM* (| TERM*)*

Terms are rule names, token names, literal names, or EOF. A term may end with
?, * or +. Parenthesized groups are reserved for a later milestone.
*/
import lib.lib
import structures.array_list


struct pg_grammar:
	char* name
	char* start_rule
	array_list* tokens
	array_list* skips
	array_list* literals
	array_list* rules


struct pg_token_def:
	char* name
	char* matcher
	int kind


struct pg_literal_def:
	char* name
	char* text
	int kind


struct pg_rule:
	char* name
	array_list* alternatives
	int kind


struct pg_alternative:
	array_list* terms


struct pg_term:
	char* name
	int modifier


pg_grammar* pg_grammar_new(char* name):
	pg_grammar* grammar = new pg_grammar()
	grammar.name = strclone(name)
	grammar.start_rule = 0
	grammar.tokens = array_list_new()
	grammar.skips = array_list_new()
	grammar.literals = array_list_new()
	grammar.rules = array_list_new()
	return grammar


pg_token_def* pg_token_def_new(char* name, char* matcher, int kind):
	pg_token_def* token = new pg_token_def()
	token.name = strclone(name)
	token.matcher = strclone(matcher)
	token.kind = kind
	return token


pg_literal_def* pg_literal_def_new(char* name, char* text, int kind):
	pg_literal_def* literal = new pg_literal_def()
	literal.name = strclone(name)
	literal.text = strclone(text)
	literal.kind = kind
	return literal


pg_rule* pg_rule_new(char* name, int kind):
	pg_rule* rule = new pg_rule()
	rule.name = strclone(name)
	rule.alternatives = array_list_new()
	rule.kind = kind
	return rule


pg_alternative* pg_alternative_new():
	pg_alternative* alternative = new pg_alternative()
	alternative.terms = array_list_new()
	return alternative


pg_term* pg_term_new(char* name, int modifier):
	pg_term* term = new pg_term()
	term.name = strclone(name)
	term.modifier = modifier
	return term


pg_token_def* pg_grammar_add_token(pg_grammar* grammar, char* name, char* matcher):
	pg_token_def* token = pg_token_def_new(name, matcher, grammar.tokens.length + grammar.literals.length + 1)
	array_list_push(grammar.tokens, cast(int, token))
	return token


pg_token_def* pg_grammar_add_skip(pg_grammar* grammar, char* name, char* matcher):
	pg_token_def* token = pg_token_def_new(name, matcher, 0)
	array_list_push(grammar.skips, cast(int, token))
	return token


pg_literal_def* pg_grammar_add_literal(pg_grammar* grammar, char* name, char* text):
	pg_literal_def* literal = pg_literal_def_new(name, text, grammar.tokens.length + grammar.literals.length + 1)
	array_list_push(grammar.literals, cast(int, literal))
	return literal


pg_rule* pg_grammar_add_rule(pg_grammar* grammar, char* name):
	pg_rule* rule = pg_rule_new(name, grammar.rules.length + 1)
	if (grammar.start_rule == 0):
		grammar.start_rule = strclone(name)
	array_list_push(grammar.rules, cast(int, rule))
	return rule


void pg_rule_add_alternative(pg_rule* rule, pg_alternative* alternative):
	array_list_push(rule.alternatives, cast(int, alternative))


void pg_alternative_add_term(pg_alternative* alternative, pg_term* term):
	array_list_push(alternative.terms, cast(int, term))


pg_token_def* pg_grammar_find_token(pg_grammar* grammar, char* name):
	int i = 0
	while (i < grammar.tokens.length):
		pg_token_def* token = cast(pg_token_def*, array_list_get(grammar.tokens, i))
		if (strcmp(token.name, name) == 0):
			return token
		i = i + 1
	return 0


pg_literal_def* pg_grammar_find_literal(pg_grammar* grammar, char* name):
	int i = 0
	while (i < grammar.literals.length):
		pg_literal_def* literal = cast(pg_literal_def*, array_list_get(grammar.literals, i))
		if (strcmp(literal.name, name) == 0):
			return literal
		i = i + 1
	return 0


pg_rule* pg_grammar_find_rule(pg_grammar* grammar, char* name):
	int i = 0
	while (i < grammar.rules.length):
		pg_rule* rule = cast(pg_rule*, array_list_get(grammar.rules, i))
		if (strcmp(rule.name, name) == 0):
			return rule
		i = i + 1
	return 0


int pg_grammar_is_token_term(pg_grammar* grammar, char* name):
	if (strcmp(name, "EOF") == 0):
		return 1
	if (pg_grammar_find_token(grammar, name) != 0):
		return 1
	if (pg_grammar_find_literal(grammar, name) != 0):
		return 1
	return 0


int pg_grammar_token_kind(pg_grammar* grammar, char* name):
	if (strcmp(name, "EOF") == 0):
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
		pg_term_free(cast(pg_term*, array_list_get(alternative.terms, i)))
		i = i + 1
	array_list_free(alternative.terms)
	free(alternative)


void pg_rule_free(pg_rule* rule):
	int i = 0
	while (i < rule.alternatives.length):
		pg_alternative_free(cast(pg_alternative*, array_list_get(rule.alternatives, i)))
		i = i + 1
	free(rule.name)
	array_list_free(rule.alternatives)
	free(rule)


void pg_token_def_free(pg_token_def* token):
	free(token.name)
	free(token.matcher)
	free(token)


void pg_literal_def_free(pg_literal_def* literal):
	free(literal.name)
	free(literal.text)
	free(literal)


void pg_grammar_free(pg_grammar* grammar):
	if (grammar == 0):
		return
	int i = 0
	while (i < grammar.tokens.length):
		pg_token_def_free(cast(pg_token_def*, array_list_get(grammar.tokens, i)))
		i = i + 1
	i = 0
	while (i < grammar.skips.length):
		pg_token_def_free(cast(pg_token_def*, array_list_get(grammar.skips, i)))
		i = i + 1
	i = 0
	while (i < grammar.literals.length):
		pg_literal_def_free(cast(pg_literal_def*, array_list_get(grammar.literals, i)))
		i = i + 1
	i = 0
	while (i < grammar.rules.length):
		pg_rule_free(cast(pg_rule*, array_list_get(grammar.rules, i)))
		i = i + 1
	free(grammar.name)
	if (grammar.start_rule != 0):
		free(grammar.start_rule)
	array_list_free(grammar.tokens)
	array_list_free(grammar.skips)
	array_list_free(grammar.literals)
	array_list_free(grammar.rules)
	free(grammar)
