int pg_lexer_matcher_guarded_switch(char* input, int index):
	if ((input[index] == 'a') || (input[index] == 'z')): return -4
	if (input[index] == 'x'): return -2
	if (input[index] == 'y'): return -3
	return 0

int pg_lexer_matcher_guarded_end(char* input, int index):
	if (input[index] == 0): return -4
	return 0

int pg_lexer_matcher_guarded_cycle(char* input, int index):
	if (input[index] == 'z'): return -4
	return 0
