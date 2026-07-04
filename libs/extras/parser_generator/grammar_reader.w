/*
ParserGenerator grammar reader.

This reader is deliberately separate from compiler.tokenizer. It accepts a
small grammar format suitable for generated recursive-descent parsers.
*/
import lib.lib
import structures.string
import libs.extras.parser_generator.token
import libs.extras.parser_generator.lexer
import libs.extras.parser_generator.diagnostics
import libs.extras.parser_generator.grammar_model


struct pg_grammar_reader:
	char* input
	char* filename
	int index
	int line
	int column
	int token_kind
	char* token
	int token_line
	int token_column
	pg_diagnostics* diagnostics


int pg_reader_token_eof():
	return 0


int pg_reader_token_name():
	return 1


int pg_reader_token_string():
	return 2


int pg_reader_token_symbol():
	return 3


pg_grammar_reader* pg_reader_new(char* input, char* filename, pg_diagnostics* diagnostics):
	pg_grammar_reader* reader = new pg_grammar_reader()
	reader.input = input
	reader.filename = filename
	reader.index = 0
	reader.line = 1
	reader.column = 1
	reader.token_kind = pg_reader_token_eof()
	reader.token = ""
	reader.token_line = 1
	reader.token_column = 1
	reader.diagnostics = diagnostics
	return reader


void pg_reader_step(pg_grammar_reader* reader):
	if (reader.input[reader.index] == 10):
		reader.line = reader.line + 1
		reader.column = 1
	else:
		reader.column = reader.column + 1
	reader.index = reader.index + 1


void pg_reader_skip_ws(pg_grammar_reader* reader):
	int running = 1
	while (running):
		running = 0
		while (pg_lexer_is_space(reader.input[reader.index])):
			pg_reader_step(reader)
			running = 1
		if (reader.input[reader.index] == '#'):
			while ((reader.input[reader.index] != 0) & (reader.input[reader.index] != 10)):
				pg_reader_step(reader)
			running = 1


void pg_reader_error(pg_grammar_reader* reader, char* message, char* expected):
	pg_diagnostics_add(reader.diagnostics, reader.filename, reader.token_line, reader.token_column, message, expected, reader.token)


char* pg_reader_string_token(pg_grammar_reader* reader):
	string_builder* out = string_new()
	pg_reader_step(reader)
	while ((reader.input[reader.index] != 0) & (reader.input[reader.index] != '"')):
		int c = reader.input[reader.index]
		if (c == 92):
			pg_reader_step(reader)
			c = reader.input[reader.index]
			if (c == 'n'):
				c = 10
			else if (c == 't'):
				c = 9
			else if (c == 'r'):
				c = 13
		string_append_char(out, c)
		pg_reader_step(reader)
	if (reader.input[reader.index] == '"'):
		pg_reader_step(reader)
	char* text = out.data
	free(out)
	return text


void pg_reader_next(pg_grammar_reader* reader):
	pg_reader_skip_ws(reader)
	reader.token_line = reader.line
	reader.token_column = reader.column
	int c = reader.input[reader.index]
	if (c == 0):
		reader.token_kind = pg_reader_token_eof()
		reader.token = ""
		return
	if (pg_lexer_is_ident_start(c)):
		int start = reader.index
		while (pg_lexer_is_ident_part(reader.input[reader.index])):
			pg_reader_step(reader)
		reader.token_kind = pg_reader_token_name()
		reader.token = pg_substr(reader.input, start, reader.index - start)
		return
	if (c == '"'):
		reader.token_kind = pg_reader_token_string()
		reader.token = pg_reader_string_token(reader)
		return
	reader.token_kind = pg_reader_token_symbol()
	reader.token = pg_substr(reader.input, reader.index, 1)
	pg_reader_step(reader)


int pg_reader_is_name(pg_grammar_reader* reader, char* name):
	if (reader.token_kind != pg_reader_token_name()):
		return 0
	return strcmp(reader.token, name) == 0


int pg_reader_is_top_level(pg_grammar_reader* reader):
	if (reader.token_kind != pg_reader_token_name()):
		return 0
	if (strcmp(reader.token, "parser") == 0):
		return 1
	if (strcmp(reader.token, "token") == 0):
		return 1
	if (strcmp(reader.token, "skip") == 0):
		return 1
	if (strcmp(reader.token, "literal") == 0):
		return 1
	if (strcmp(reader.token, "start") == 0):
		return 1
	if (strcmp(reader.token, "rule") == 0):
		return 1
	return 0


int pg_reader_accept_symbol(pg_grammar_reader* reader, char* symbol):
	if (reader.token_kind != pg_reader_token_symbol()):
		return 0
	if (strcmp(reader.token, symbol) != 0):
		return 0
	pg_reader_next(reader)
	return 1


int pg_reader_expect_symbol(pg_grammar_reader* reader, char* symbol):
	if (pg_reader_accept_symbol(reader, symbol)):
		return 1
	pg_reader_error(reader, "grammar parse error", symbol)
	return 0


char* pg_reader_take_name(pg_grammar_reader* reader):
	if (reader.token_kind != pg_reader_token_name()):
		pg_reader_error(reader, "grammar parse error", "name")
		return 0
	char* name = strclone(reader.token)
	pg_reader_next(reader)
	return name


char* pg_reader_take_string(pg_grammar_reader* reader):
	if (reader.token_kind != pg_reader_token_string()):
		pg_reader_error(reader, "grammar parse error", "string")
		return 0
	char* text = strclone(reader.token)
	pg_reader_next(reader)
	return text


void pg_reader_parse_rule_body(pg_grammar_reader* reader, pg_rule* rule):
	pg_alternative* alternative = pg_alternative_new()
	while (reader.token_kind != pg_reader_token_eof()):
		if (pg_reader_is_top_level(reader)):
			break
		if (pg_reader_accept_symbol(reader, "|")):
			pg_rule_add_alternative(rule, alternative)
			alternative = pg_alternative_new()
		else:
			char* name = pg_reader_take_name(reader)
			if (name == 0):
				return
			int modifier = 0
			if (reader.token_kind == pg_reader_token_symbol()):
				if ((strcmp(reader.token, "?") == 0) | (strcmp(reader.token, "*") == 0) | (strcmp(reader.token, "+") == 0)):
					modifier = reader.token[0]
					pg_reader_next(reader)
			pg_alternative_add_term(alternative, pg_term_new(name, modifier))
	pg_rule_add_alternative(rule, alternative)


pg_grammar* pg_grammar_read(char* input, char* filename, pg_diagnostics* diagnostics):
	pg_grammar_reader* reader = pg_reader_new(input, filename, diagnostics)
	pg_reader_next(reader)
	if (pg_reader_is_name(reader, "parser") == 0):
		pg_reader_error(reader, "grammar must start with parser directive", "parser")
		return 0
	pg_reader_next(reader)
	char* parser_name = pg_reader_take_name(reader)
	if (parser_name == 0):
		return 0
	pg_grammar* grammar = pg_grammar_new(parser_name)
	while (reader.token_kind != pg_reader_token_eof()):
		if (pg_reader_is_name(reader, "token")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			char* matcher = pg_reader_take_name(reader)
			if ((name == 0) | (matcher == 0)):
				return 0
			pg_grammar_add_token(grammar, name, matcher)
		else if (pg_reader_is_name(reader, "skip")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			char* matcher = pg_reader_take_name(reader)
			if ((name == 0) | (matcher == 0)):
				return 0
			pg_grammar_add_skip(grammar, name, matcher)
		else if (pg_reader_is_name(reader, "literal")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			char* text = pg_reader_take_string(reader)
			if ((name == 0) | (text == 0)):
				return 0
			pg_grammar_add_literal(grammar, name, text)
		else if (pg_reader_is_name(reader, "start")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			if (name == 0):
				return 0
			if (grammar.start_rule != 0):
				free(grammar.start_rule)
			grammar.start_rule = strclone(name)
		else if (pg_reader_is_name(reader, "rule")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			if (name == 0):
				return 0
			if (pg_reader_expect_symbol(reader, "=") == 0):
				return 0
			pg_rule* rule = pg_grammar_add_rule(grammar, name)
			pg_reader_parse_rule_body(reader, rule)
		else:
			pg_reader_error(reader, "unknown grammar directive", "token, skip, literal, start or rule")
			return 0
	if (grammar.rules.length == 0):
		pg_reader_error(reader, "grammar has no rules", "rule")
		return 0
	if (pg_grammar_find_rule(grammar, grammar.start_rule) == 0):
		pg_reader_error(reader, "start rule is not defined", grammar.start_rule)
		return 0
	return grammar
