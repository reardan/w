/*
Custom pg lexer matchers shared by the grammars in this directory
(`token NAME <matcher>` in a .pg resolves to pg_lexer_matcher_<matcher>).
Import this module ahead of a generated parser that uses them, as the
tests/grammars demos do; tools/antlr_to_pg.w maps CSV-style unquoted
fields to csv_text.
*/


int pg_lexer_matcher_csv_text(char* input, int index):
	int start = index
	while ((input[index] != 0) && (input[index] != ',') && (input[index] != 10) && (input[index] != 13) && (input[index] != '"')):
		index = index + 1
	return index - start
