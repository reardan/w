int[3] ast_flow_values
struct ast_flow_box:
	int[] values

ast_flow_box ast_flow_make():
	ast_flow_box result
	result.values = ast_flow_values
	return result

int ast_flow_first(int* values): return values[0]
int* ast_flow_pick(int flag, int* other): return flag ? ast_flow_values : other
int* ast_flow_reverse(int flag, int* other): return flag ? other : ast_flow_values
int* ast_flow_null(int flag): return flag ? ast_flow_values : 0
int* ast_flow_from_null(int flag): return flag ? 0 : ast_flow_values

int main():
	ast_flow_values[0] = 4
	ast_flow_values[1] = 7
	ast_flow_values[2] = 9
	int other = 2
	if (ast_flow_first(ast_flow_make().values) != 4): return 1
	if (ast_flow_make().values.length != 3 || ast_flow_make().values[1] != 7): return 2
	if (ast_flow_pick(1, &other)[0] != 4 || ast_flow_pick(0, &other)[0] != 2): return 3
	if (ast_flow_reverse(1, &other)[0] != 2 || ast_flow_reverse(0, &other)[0] != 4): return 4
	if (ast_flow_null(0) != 0 || ast_flow_from_null(1) != 0): return 5
	if (ast_flow_null(1)[0] != 4 || ast_flow_from_null(0)[0] != 4): return 6
	int[] joined = true ? ast_flow_values : ast_flow_values[1:]
	if (joined.length != 3 || joined[0] != 4): return 7
	joined = false ? ast_flow_values : ast_flow_values[1:]
	if (joined.length != 2 || joined[0] != 7): return 8
	char[3] key
	key[0] = 'h'
	key[1] = 'i'
	key[2] = 0
	set[char*] names = set[char*]{c"hi", c"bye"}
	list[char*] words = list[char*]{c"hi"}
	if (!(key in names) || !(key in words)): return 9
	# Unary casts stop before the following parenthesized statement even
	# though lexical preflight also permits multiline postfix calls.
	char* key_data = cast(char*, key)
	(key_data + 1)[0] = 'o'
	if (key[1] != 'o'): return 10
	char* key_again = cast(char*, key) # retain the newline boundary
	/* lookahead comment */ (key_again)[0] = 'g'
	if (key[0] != 'g'): return 11
	int element_size = sizeof(int)
	(element_size) = element_size + 1
	if (element_size != __word_size__ + 1): return 12
	names.free()
	words.free()
	return 0
