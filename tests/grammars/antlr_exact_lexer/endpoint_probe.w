import lib.args
import lib.lib
import bin.at_exact_matchers
int main(int argc, int argv):
	args_init(argc, argv)
	int i = 0
	while (i < args_positional_count()):
		char* rule = args_positional(i)
		char* input = args_positional(i + 1)
		int length = 0
		if (strcmp(rule, c"WORD") == 0): length = pg_lexer_matcher_g_at_exact_WORD(input, 0)
		if (strcmp(rule, c"REPEAT") == 0): length = pg_lexer_matcher_g_at_exact_REPEAT(input, 0)
		if (strcmp(rule, c"NG_SUFFIX") == 0): length = pg_lexer_matcher_g_at_exact_NG_SUFFIX(input, 0)
		if (strcmp(rule, c"ORDERED") == 0): length = pg_lexer_matcher_g_at_exact_ORDERED(input, 0)
		if (strcmp(rule, c"MIXED") == 0): length = pg_lexer_matcher_g_at_exact_MIXED(input, 0)
		if (strcmp(rule, c"NESTED") == 0): length = pg_lexer_matcher_g_at_exact_NESTED(input, 0)
		if (strcmp(rule, c"NG_OPTIONAL") == 0): length = pg_lexer_matcher_g_at_exact_NG_OPTIONAL(input, 0)
		if (strcmp(rule, c"NG_PLUS") == 0): length = pg_lexer_matcher_g_at_exact_NG_PLUS(input, 0)
		if (strcmp(rule, c"FRAGMENT") == 0): length = pg_lexer_matcher_g_at_exact_FRAGMENT(input, 0)
		if (length < 0): length = 0
		print(rule)
		print(c"\t")
		println(itoa(length))
		i = i + 2
	return 0
