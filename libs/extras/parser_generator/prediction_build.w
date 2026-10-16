# Compile a pure PG grammar into the continuation instruction graph.
import libs.extras.parser_generator.grammar_model
import libs.extras.parser_generator.prediction


int pg_prediction_check(pg_grammar* grammar):
	if ((grammar.goals.length > 0) || (grammar.recovers.length > 0)):
		println2(c"parser_generator: antlr prediction does not support lexical goals or recovery")
		return 1
	for pg_rule* rule in grammar.rules:
		for pg_alternative* alternative in rule.alternatives:
			for pg_term* term in alternative.terms:
				if (term.kind != pg_term_kind_normal()):
					println2(c"parser_generator: antlr prediction requires action-free, predicate-free parser rules")
					return 1
	# Lexer host callbacks may observe external mutable state, so buffered
	# lookahead would have a different contract from checkpointed parsing.
	for pg_lexer_rule_config* config in grammar.lexer_rules:
		if ((config.guard != 0) || (config.action != 0)):
			println2(c"parser_generator: antlr prediction does not support lexer host callbacks")
			return 1
	return 0


int pg_prediction_rule_index(pg_grammar* grammar, char* name):
	for i, rule in grammar.rules:
		if (strcmp(rule.name, name) == 0): return i
	return -1


int pg_prediction_atom(pg_prediction_program* program, pg_grammar* grammar, pg_term* term, int next):
	if (term.metadata != 0):
		for char* key in term.metadata:
			next = pg_prediction_add(program, 9, next, 0, term.metadata[key], key)
	if (pg_grammar_is_token_term(grammar, term.name)):
		return pg_prediction_add(program, 1, next, 0, pg_grammar_token_kind(grammar, term.name), term.name)
	return pg_prediction_add(program, 2, next, 0, pg_prediction_rule_index(grammar, term.name), c"")


pg_prediction_program* pg_prediction_build(pg_grammar* grammar):
	pg_prediction_program* program = pg_prediction_new()
	# Reserve a stable entry for each rule before resolving recursive calls.
	for pg_rule* rule in grammar.rules: pg_prediction_add(program, 7, 0, 0, rule.kind, rule.name)
	int finish = pg_prediction_add(program, 3, 0, 0, 0, c"")
	for r, rule in grammar.rules:
		int choice = -1
		int a = rule.alternatives.length - 1
		while (a >= 0):
			pg_alternative* alternative = rule.alternatives[a]
			int next = pg_prediction_add(program, 6, finish, 0, 0, c"")
			int t = alternative.terms.length - 1
			while (t >= 0):
				pg_term* term = alternative.terms[t]
				if (term.modifier == '?'):
					int atom = pg_prediction_atom(program, grammar, term, next)
					next = pg_prediction_add(program, 4, atom, next, 0, c"")
				else if ((term.modifier == '*') || (term.modifier == '+')):
					int repeat = pg_prediction_add(program, 4, 0, next, 0, c"")
					int atom = pg_prediction_atom(program, grammar, term, repeat)
					program.ops[repeat].next = atom
					next = repeat
					if (term.modifier == '+'): next = atom
				else: next = pg_prediction_atom(program, grammar, term, next)
				t--
			if (alternative.metadata != 0):
				for char* key in alternative.metadata:
					next = pg_prediction_add(program, 8, next, 0, alternative.metadata[key], key)
			int enter = pg_prediction_add(program, 5, next, a + 1, rule.kind, rule.name)
			if (choice < 0): choice = enter
			else: choice = pg_prediction_add(program, 4, enter, choice, 0, c"")
			a--
		program.ops[r].next = choice
	return program
