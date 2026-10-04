int ast_expression_statement_total

void ast_expression_statement_note(int n):
	ast_expression_statement_total += n

int main():
	int a = 1
	int b = 2
	a, b = b, a
	++a
	b++
	a += b
	ast_expression_statement_note(a)
	map[int, int] values = new map[int, int]
	values[0] = a
	values[0] += 2
	ast_expression_statement_note(values[0])
	list[int] items = list[int]{10}
	items[0]--
	--items[0]
	ast_expression_statement_note(items[0])
	if (ast_expression_statement_total != 20): return 1
	return 0
