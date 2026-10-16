import lib.assert
import bin.prediction_precedence_matchers
import bin.prediction_precedence_parser


char* precedence_text(pg_ast_node* node):
	if (node.token != 0): return node.text
	assert_equal(1, node.children.length)
	return precedence_text(node.children[0])


int precedence_value(pg_ast_node* node):
	if (node.token != 0): return atoi(node.text)
	if (strcmp(node.name, c"e_primary") == 0):
		char* head = precedence_text(node.children[0])
		if (strcmp(head, c"-") == 0): return -precedence_value(node.children[1])
		if (strcmp(head, c"(") == 0): return precedence_value(node.children[1])
		return precedence_value(node.children[0])
	int value = precedence_value(node.children[0])
	for i in range(1, node.children.length):
		pg_ast_node* tail = node.children[i]
		char* op = precedence_text(tail.children[0])
		if (strcmp(op, c"!") == 0): value = value + 100
		else if (strcmp(op, c"?") == 0):
			int yes = precedence_value(tail.children[1])
			int no = precedence_value(tail.children[3])
			if (value != 0): value = yes
			else: value = no
		else:
			int last = tail.children.length - 1
			int rhs = precedence_value(tail.children[last])
			if (strcmp(op, c"+") == 0): value = value + rhs
			else if (strcmp(op, c"*") == 0): value = value * rhs
			else:
				assert_strings_equal(c"^", op)
				int power = 1
				assert1(rhs >= 0)
				for n in range(rhs): power = power * value
				value = power
	return value


void precedence_accept(char* input, int expected):
	pg_parse_result* result = precedence_parse_owned(input, strlen(input), c"expression")
	if (result.success == 0): pg_diagnostics_print(result.diagnostics)
	assert1(result.success)
	assert_equal(expected, precedence_value(result.root.children[0]))
	pg_parse_result_free(result)


void precedence_reject(char* input):
	pg_parse_result* result = precedence_parse_owned(input, strlen(input), c"expression")
	assert_equal(0, result.success)
	pg_parse_result_free(result)


int main():
	precedence_accept(c"2+3*by 4", 14)
	precedence_accept(c"2^3^2", 512)
	precedence_accept(c"2+3!", 105)
	precedence_accept(c"2!^2", 10404)
	precedence_accept(c"2^2!", 104)
	precedence_accept(c"2!!^2!", 40904)
	precedence_accept(c"-2^2", 4)
	precedence_accept(c"1?2+3:4*5", 5)
	precedence_accept(c"0?2:0?3:4", 4)
	precedence_accept(c"1?0?3:4:5", 4)
	precedence_accept(c"0?1:2+3*4", 14)
	precedence_accept(c"(0?1:2)+3", 5)
	precedence_reject(c"1?")
	precedence_reject(c"1?2")
	precedence_reject(c"1?2:")
	precedence_reject(c"2*by")
	precedence_reject(c"2^^3")
	println(c"binding-power loops preserve mixed postfix, compound operators and ternaries")
	return 0
