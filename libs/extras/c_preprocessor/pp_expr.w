/*
Integer evaluator for #if / #elif expressions.
*/
import lib.lib
import libs.extras.c_preprocessor.pp_token
import libs.extras.c_preprocessor.pp_lexer
import libs.extras.c_preprocessor.pp_macro


struct cpp_expr:
	map[char*, cpp_macro*] macros
	cpp_token* token


int cpp_eval_conditional_expr(cpp_expr* expr);


cpp_token* cpp_expr_number_token(int value):
	char* text = itoa(value)
	cpp_token* token = cpp_token_new(cpp_token_number(), text, c"<expr>", 0, 0, 0)
	free(text)
	return token


int cpp_expr_is_defined_name(map[char*, cpp_macro*] macros, char* name):
	return cpp_macro_lookup(macros, name) != 0


cpp_token* cpp_expr_prepare_defined(map[char*, cpp_macro*] macros, cpp_token* token):
	cpp_token head
	head.next = 0
	cpp_token* tail = &head
	while (token != 0):
		if (token.kind == cpp_token_eof()):
			break
		if (cpp_token_is_ident(token, c"defined")):
			int value = 0
			if (cpp_token_is_punct(token.next, c"(")):
				cpp_token* name = token.next.next
				if (name != 0):
					if (name.kind == cpp_token_ident()):
						value = cpp_expr_is_defined_name(macros, name.text)
						if (cpp_token_is_punct(name.next, c")")):
							token = name.next.next
						else:
							token = name.next
					else:
						token = name
			else:
				cpp_token* name = token.next
				if (name != 0):
					if (name.kind == cpp_token_ident()):
						value = cpp_expr_is_defined_name(macros, name.text)
						token = name.next
					else:
						token = name
			tail.next = cpp_expr_number_token(value)
			tail = tail.next
		else:
			tail.next = cpp_token_clone_one(token)
			tail = tail.next
			token = token.next
	tail.next = 0
	return head.next


cpp_token* cpp_expr_identifiers_to_zero(cpp_token* token):
	cpp_token head
	head.next = 0
	cpp_token* tail = &head
	while (token != 0):
		if (token.kind == cpp_token_eof()):
			break
		if (token.kind == cpp_token_ident()):
			tail.next = cpp_expr_number_token(0)
		else:
			tail.next = cpp_token_clone_one(token)
		tail = tail.next
		token = token.next
	tail.next = 0
	return head.next


int cpp_expr_hex_value(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	if ((c >= 'a') & (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') & (c <= 'F')):
		return c - 'A' + 10
	return -1


int cpp_expr_parse_number(char* text):
	int base = 10
	int i = 0
	if (text[0] == '0'):
		if ((text[1] == 'x') | (text[1] == 'X')):
			base = 16
			i = 2
		else:
			base = 8
			i = 1
	int value = 0
	while (text[i] != 0):
		int digit = -1
		if (base == 16):
			digit = cpp_expr_hex_value(text[i])
		else if ((text[i] >= '0') & (text[i] <= '9')):
			digit = text[i] - '0'
		if ((digit < 0) | (digit >= base)):
			return value
		value = value * base + digit
		i = i + 1
	return value


int cpp_expr_char_escape(int c):
	if (c == 'n'):
		return 10
	if (c == 't'):
		return 9
	if (c == 'r'):
		return 13
	if (c == '0'):
		return 0
	return c


int cpp_expr_parse_char(char* text):
	if (text[1] == 92):
		return cpp_expr_char_escape(text[2])
	return text[1]


int cpp_expr_accept(cpp_expr* expr, char* text):
	if (cpp_token_is_punct(expr.token, text)):
		expr.token = expr.token.next
		return 1
	return 0


int cpp_eval_primary(cpp_expr* expr):
	if (cpp_expr_accept(expr, c"(")):
		int value = cpp_eval_conditional_expr(expr)
		cpp_expr_accept(expr, c")")
		return value
	if (expr.token == 0):
		return 0
	if (expr.token.kind == cpp_token_number()):
		int value = cpp_expr_parse_number(expr.token.text)
		expr.token = expr.token.next
		return value
	if (expr.token.kind == cpp_token_char()):
		int value = cpp_expr_parse_char(expr.token.text)
		expr.token = expr.token.next
		return value
	expr.token = expr.token.next
	return 0


int cpp_eval_unary(cpp_expr* expr):
	if (cpp_expr_accept(expr, c"+")):
		return cpp_eval_unary(expr)
	if (cpp_expr_accept(expr, c"-")):
		return 0 - cpp_eval_unary(expr)
	if (cpp_expr_accept(expr, c"!")):
		return cpp_eval_unary(expr) == 0
	if (cpp_expr_accept(expr, c"~")):
		return 0 - cpp_eval_unary(expr) - 1
	return cpp_eval_primary(expr)


int cpp_eval_multiplicative(cpp_expr* expr):
	int value = cpp_eval_unary(expr)
	while (1):
		if (cpp_expr_accept(expr, c"*")):
			value = value * cpp_eval_unary(expr)
		else if (cpp_expr_accept(expr, c"/")):
			int right = cpp_eval_unary(expr)
			if (right == 0):
				value = 0
			else:
				value = value / right
		else if (cpp_expr_accept(expr, c"%")):
			int right = cpp_eval_unary(expr)
			if (right == 0):
				value = 0
			else:
				value = value % right
		else:
			return value


int cpp_eval_additive(cpp_expr* expr):
	int value = cpp_eval_multiplicative(expr)
	while (1):
		if (cpp_expr_accept(expr, c"+")):
			value = value + cpp_eval_multiplicative(expr)
		else if (cpp_expr_accept(expr, c"-")):
			value = value - cpp_eval_multiplicative(expr)
		else:
			return value


int cpp_eval_shift(cpp_expr* expr):
	int value = cpp_eval_additive(expr)
	while (1):
		if (cpp_expr_accept(expr, c"<<")):
			value = value << cpp_eval_additive(expr)
		else if (cpp_expr_accept(expr, c">>")):
			value = value >> cpp_eval_additive(expr)
		else:
			return value


int cpp_eval_relational(cpp_expr* expr):
	int value = cpp_eval_shift(expr)
	while (1):
		if (cpp_expr_accept(expr, c"<")):
			value = value < cpp_eval_shift(expr)
		else if (cpp_expr_accept(expr, c">")):
			value = value > cpp_eval_shift(expr)
		else if (cpp_expr_accept(expr, c"<=")):
			value = value <= cpp_eval_shift(expr)
		else if (cpp_expr_accept(expr, c">=")):
			value = value >= cpp_eval_shift(expr)
		else:
			return value


int cpp_eval_equality(cpp_expr* expr):
	int value = cpp_eval_relational(expr)
	while (1):
		if (cpp_expr_accept(expr, c"==")):
			value = value == cpp_eval_relational(expr)
		else if (cpp_expr_accept(expr, c"!=")):
			value = value != cpp_eval_relational(expr)
		else:
			return value


int cpp_eval_bitwise_and(cpp_expr* expr):
	int value = cpp_eval_equality(expr)
	while (cpp_expr_accept(expr, c"&")):
		value = value & cpp_eval_equality(expr)
	return value


int cpp_bitwise_xor_value(int left, int right):
	return (left | right) & (0 - (left & right) - 1)


int cpp_eval_bitwise_xor(cpp_expr* expr):
	int value = cpp_eval_bitwise_and(expr)
	while (cpp_expr_accept(expr, c"^")):
		value = cpp_bitwise_xor_value(value, cpp_eval_bitwise_and(expr))
	return value


int cpp_eval_bitwise_or(cpp_expr* expr):
	int value = cpp_eval_bitwise_xor(expr)
	while (cpp_expr_accept(expr, c"|")):
		value = value | cpp_eval_bitwise_xor(expr)
	return value


int cpp_eval_logical_and(cpp_expr* expr):
	int value = cpp_eval_bitwise_or(expr)
	while (cpp_expr_accept(expr, c"&&")):
		int right = cpp_eval_bitwise_or(expr)
		value = (value != 0) & (right != 0)
	return value


int cpp_eval_logical_or(cpp_expr* expr):
	int value = cpp_eval_logical_and(expr)
	while (cpp_expr_accept(expr, c"||")):
		int right = cpp_eval_logical_and(expr)
		value = (value != 0) | (right != 0)
	return value


int cpp_eval_conditional_expr(cpp_expr* expr):
	int value = cpp_eval_logical_or(expr)
	if (cpp_expr_accept(expr, c"?")):
		int true_value = cpp_eval_conditional_expr(expr)
		cpp_expr_accept(expr, c":")
		int false_value = cpp_eval_conditional_expr(expr)
		if (value != 0):
			return true_value
		return false_value
	return value


int cpp_eval_if_expr(map[char*, cpp_macro*] macros, cpp_token* line):
	cpp_token* prepared = cpp_expr_prepare_defined(macros, line)
	cpp_token* expanded = cpp_expand_tokens(macros, prepared)
	cpp_token* zeros = cpp_expr_identifiers_to_zero(expanded)
	cpp_expr expr
	expr.macros = macros
	expr.token = zeros
	return cpp_eval_conditional_expr(&expr)
