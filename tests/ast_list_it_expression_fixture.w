int ast_it_order
int ast_it_mark(int n):
	ast_it_order = ast_it_order * 10 + n
	return n

T ast_it_identity[T](T value): return value

struct ast_it_record:
	int score
	int it

int main():
	list[int] values = list[int]{1, 2, 3}
	list[int] doubled = values.map(ast_it_mark(it) * 2)
	if (ast_it_order != 123 || doubled[2] != 6): return 1
	int bias = 5
	list[int] nested = values.map(values.filter(it > 1).sum() + it + bias)
	if (nested[0] != 11 || nested[2] != 13): return 2
	list[string] text = values.map(f"<{it}>")
	if (text[1] != s"<2>"): return 3
	if (values.any(it == 2) != true): return 4
	if (values.all(it < 4) != true): return 5
	if (values.index(it > 1) != 1): return 6
	list[ast_it_record] records = new list[ast_it_record]
	records.push(ast_it_record(4, 7))
	records.push(ast_it_record(2, 8))
	records.min_by(it.score).score = 9
	if (records[1].score != 9): return 7
	list[int] keys = records.map(it.it)
	if (keys[0] != 7 || keys[1] != 8): return 8
	list[int] empty = new list[int]
	if (empty.map(it + bias).length != 0): return 9
	if (values.map(ast_it_identity(it)).sum() != 6): return 10
	if (values.map(it += 1).sum() != 9 || values[0] != 1): return 11
	list[list[string]] matrix = list[list[string]]{list[string]{s"a", s"b"}, list[string]{s"c", s"d"}}
	int column = 1
	list[string] transposed = matrix.map(it[column])
	if (transposed[0] != s"b" || transposed[1] != s"d"): return 13
	int it = 2
	if (values.count(it) != 1): return 12
	return 0
