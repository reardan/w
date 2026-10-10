# JavaScript lexical helpers. Matchers return a byte length, never mutate state.
# Unicode identifier properties are pinned to Unicode 12.1 (ES2020).
import lib.lib
import libs.extras.javascript.unicode
import libs.extras.parser_generator.lexer_state


int js_hex(int ch):
	if (ch >= '0' && ch <= '9'): return ch - '0'
	if (ch >= 'a' && ch <= 'f'): return ch - 'a' + 10
	if (ch >= 'A' && ch <= 'F'): return ch - 'A' + 10
	return -1


int js_digit(int ch):
	return ch >= '0' && ch <= '9'


int js_optional_allowed(char* input, int index, int length):
	return js_digit(input[index + length]) == 0


# Inspect at most four bytes, stopping at the input's terminator.
int js_decode(char* input, int index, int* codepoint):
	int available = 0
	while (available < 4 && input[index + available] != 0): available = available + 1
	return utf8_scan(input + index, available, codepoint)


int js_line_terminator(char* input, int index):
	if (input[index] == 10 || input[index] == 13): return 1
	int cp = 0
	int n = js_decode(input, index, &cp)
	if (n > 0 && (cp == 8232 || cp == 8233)): return n
	return 0


# index points at the backslash. Returns full escape width and decoded scalar.
int js_unicode_escape(char* input, int index, int* codepoint):
	if (input[index] != 92 || input[index + 1] != 'u'): return 0
	int i = index + 2
	int value = 0
	if (input[i] == '{'):
		i = i + 1
		int digits = 0
		while (js_hex(input[i]) >= 0):
			value = value * 16 + js_hex(input[i])
			digits = digits + 1
			if (value > 1114111 || digits > 6): return 0
			i = i + 1
		if (digits == 0 || input[i] != '}'): return 0
		i = i + 1
	else:
		int digits = 0
		while (digits < 4):
			int d = js_hex(input[i])
			if (d < 0): return 0
			value = value * 16 + d
			digits = digits + 1
			i = i + 1
	*codepoint = value
	return i - index


int js_identifier_start(int cp):
	return cp == '$' || cp == '_' || js_unicode_id_start(cp)


int js_identifier_part(int cp):
	return cp == '$' || cp == '_' || cp == 8204 || cp == 8205 || js_unicode_id_continue(cp)


int js_identifier_unit(char* input, int index, int* cp):
	if (input[index] == 92): return js_unicode_escape(input, index, cp)
	return js_decode(input, index, cp)


int pg_lexer_matcher_js_identifier(char* input, int index):
	int cp = 0
	int n = js_identifier_unit(input, index, &cp)
	if (n == 0 || js_identifier_start(cp) == 0): return 0
	int i = index + n
	while (input[i] != 0):
		n = js_identifier_unit(input, i, &cp)
		if (n == 0 || js_identifier_part(cp) == 0): break
		i = i + n
	return i - index


int pg_lexer_matcher_js_space(char* input, int index):
	int i = index
	while (input[i] != 0):
		int cp = 0
		int n = js_decode(input, i, &cp)
		if (n == 0): break
		int space = cp == 9 || cp == 10 || cp == 11 || cp == 12 || cp == 13 || cp == 32 || cp == 160 || cp == 5760 || cp == 8232 || cp == 8233 || cp == 8239 || cp == 8287 || cp == 12288 || cp == 65279
		if (cp >= 8192 && cp <= 8202): space = 1
		if (space == 0): break
		i = i + n
	return i - index


int pg_lexer_matcher_js_line_comment(char* input, int index):
	if (input[index] != '/' || input[index + 1] != '/'): return 0
	int i = index + 2
	while (input[i] != 0 && js_line_terminator(input, i) == 0): i = i + 1
	return i - index


int pg_lexer_matcher_js_block_comment(char* input, int index):
	if (input[index] != '/' || input[index + 1] != '*'): return 0
	int i = index + 2
	while (input[i] != 0):
		if (input[i] == '*' && input[i + 1] == '/'): return i + 2 - index
		i = i + 1
	return 0


int pg_lexer_matcher_js_hashbang(char* input, int index):
	if (index != 0 || input[index] != '#' || input[index + 1] != '!'): return 0
	int i = index + 2
	while (input[i] != 0 && js_line_terminator(input, i) == 0): i = i + 1
	return i - index


int js_string_escape(char* input, int index):
	if (input[index] != 92 || input[index + 1] == 0): return 0
	int i = index + 1
	int line = js_line_terminator(input, i)
	if (line > 0):
		if (input[i] == 13 && input[i + 1] == 10): line = 2
		return line + 1
	if (input[i] == 'u'):
		int cp = 0
		return js_unicode_escape(input, index, &cp)
	if (input[i] == 'x'):
		if (js_hex(input[i + 1]) < 0): return 0
		if (js_hex(input[i + 2]) < 0): return 0
		return 4
	# Legacy numeric escapes are validated by the strict-mode pass.
	return 2


int pg_lexer_matcher_js_string(char* input, int index):
	int quote = input[index]
	if (quote != 39 && quote != 34): return 0
	int i = index + 1
	while (input[i] != 0):
		if (input[i] == quote): return i + 1 - index
		if (input[i] == 10 || input[i] == 13): return 0
		if (input[i] == 92):
			int n = js_string_escape(input, i)
			if (n == 0): return 0
			i = i + n
		else:
			int cp = 0
			int n = js_decode(input, i, &cp)
			if (n == 0): return 0
			i = i + n
	return 0


int pg_lexer_matcher_js_number(char* input, int index):
	int i = index
	int base = 10
	int fractional = 0
	if (input[i] == '0'):
		int next = input[i + 1]
		if (next == 'x' || next == 'X'): base = 16
		else if (next == 'b' || next == 'B'): base = 2
		else if (next == 'o' || next == 'O'): base = 8
	if (base != 10):
		i = i + 2
		int start = i
		while (js_hex(input[i]) >= 0 && js_hex(input[i]) < base): i = i + 1
		if (i == start): return 0
	else:
		while (js_digit(input[i])): i = i + 1
		if (input[i] == '.'):
			fractional = 1
			i = i + 1
			int after_dot = i
			while (js_digit(input[i])): i = i + 1
			if (index + 1 == after_dot && i == after_dot): return 0
		if (i == index): return 0
		if (input[i] == 'e' || input[i] == 'E'):
			fractional = 1
			i = i + 1
			if (input[i] == '+' || input[i] == '-'): i = i + 1
			int exp_start = i
			while (js_digit(input[i])): i = i + 1
			if (i == exp_start): return 0
	if (input[i] == 'n'):
		if (fractional): return 0
		if (base == 10 && input[index] == '0' && i > index + 1): return 0
		i = i + 1
	int cp = 0
	int n = js_identifier_unit(input, i, &cp)
	if (n > 0 && js_identifier_part(cp)): return 0
	return i - index


# Regex boundary/flag lexing. Pattern semantics are a separate validation layer.
int pg_lexer_matcher_js_regex(char* input, int index):
	if (input[index] != '/' || input[index + 1] == '/' || input[index + 1] == '*'): return 0
	int i = index + 1
	int in_class = 0
	while (input[i] != 0):
		if (js_line_terminator(input, i)): return 0
		if (input[i] == 92):
			i = i + 1
			if (input[i] == 0 || js_line_terminator(input, i)): return 0
		else if (input[i] == '['): in_class = 1
		else if (input[i] == ']'): in_class = 0
		else if (input[i] == '/' && in_class == 0):
			i = i + 1
			int flags = 0
			while (input[i] != 0):
				int cp = 0
				int n = js_identifier_unit(input, i, &cp)
				if (n == 0 || js_identifier_part(cp) == 0): break
				int flag = 0
				if (cp == 'g'): flag = 1
				else if (cp == 'i'): flag = 2
				else if (cp == 'm'): flag = 4
				else if (cp == 's'): flag = 8
				else if (cp == 'u'): flag = 16
				else if (cp == 'y'): flag = 32
				if (flag == 0 || (flags & flag) != 0 || input[i] == 92): return 0
				flags = flags | flag
				i = i + n
			return i - index
		i = i + 1
	return 0


int pg_lexer_matcher_js_template_text(char* input, int index):
	int i = index
	while (input[i] != 0):
		if (input[i] == '`' || (input[i] == '$' && input[i + 1] == '{')): break
		if (input[i] == 92):
			# Preserve raw escapes, including invalid tagged-template escapes.
			i = i + 1
			if (input[i] == 0): return 0
		int cp = 0
		int n = js_decode(input, i, &cp)
		if (n == 0): return 0
		i = i + n
	return i - index


# All JS-specific mutable lexical state lives in the checkpointed context stack.
void js_lexer_interpolation(pg_lexer_state* state):
	state.context.push(0)


void js_lexer_open_brace(pg_lexer_state* state):
	if (state.context.length > 0):
		int last = state.context.length - 1
		state.context[last] = state.context[last] + 1


void js_lexer_close_brace(pg_lexer_state* state):
	if (state.context.length == 0): return
	int last = state.context.length - 1
	if (state.context[last] == 0):
		state.context.pop()
		# A matching interpolation always has a saved template mode.
		if (state.modes.length > 0): state.mode = state.modes.pop()
	else: state.context[last] = state.context[last] - 1
