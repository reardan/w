struct ast_record_small:
	int16 a
	int16 b

struct ast_record_large:
	ast_record_small small
	int tag
	int[3] values

union ast_record_union:
	int bits
	char low

type ast_record_fn = fn(ast_record_small, int) -> int

int ast_record_sum(ast_record_small value, int extra):
	value.a = value.a + 1
	return value.a + value.b + extra

int ast_record_array(ast_record_large value, int extra):
	value.values[0] = 100
	return value.values[0] + value.values[2] + value.small.a + extra

ast_record_small ast_record_make(int a, int b):
	ast_record_small value
	value.a = a
	value.b = b
	return (value)

ast_record_small ast_record_relay(ast_record_small value): return (value)

type ast_record_factory = fn(int, int) -> ast_record_small

ast_record_large ast_record_make_large(int n):
	ast_record_large value
	value.small = ast_record_make(n, 2)
	value.tag = 8
	value.values[0] = 10
	value.values[1] = 20
	value.values[2] = 30
	return value

int main():
	ast_record_small first
	first.a = 12
	first.b = -3
	ast_record_small second = (first)
	if 1: (second = first)
	if ((ast_record_sum(second, 4)) != 14): return 1
	if (second.a != 12): return 2
	ast_record_fn* callback = ast_record_sum
	if ((callback(first, 4)) != 14): return 3
	ast_record_large large
	large.small = first
	large.tag = 7
	large.values[0] = 10
	large.values[1] = 20
	large.values[2] = 30
	ast_record_large copy = (large)
	if 1: (copy = large)
	copy.values[0] = 40
	if (large.values[0] != 10): return 4
	if ((ast_record_array(copy, 5)) != 147): return 5
	if (copy.values[0] != 40): return 6
	if ((ast_record_sum(copy.small, 1)) != 11): return 7
	list[ast_record_small] records = new list[ast_record_small]
	records.push(first)
	if 1: (records[0] = second)
	ast_record_small popped = (records.pop())
	if (popped.a != 12 || popped.b != -3): return 8
	records.push(first)
	if ((ast_record_sum(records.pop(), 2)) != 12): return 9
	if 1: (records.push(second = first))
	if (records[0].a != 12): return 10
	records.free()
	ast_record_union left
	left.bits = 123
	ast_record_union right = (left)
	if 1: (right = left)
	if (right.bits != 123): return 11
	if ((ast_record_sum(second = first, 4)) != 14): return 12
	ast_record_small returned = (ast_record_make(15, 6))
	if (returned.a != 15 || returned.b != 6): return 13
	if 1: (returned = ast_record_relay(ast_record_make(18, 9)))
	if (returned.a != 18 || returned.b != 9): return 14
	if ((ast_record_sum(ast_record_make(2, 3), 4)) != 10): return 15
	if ((ast_record_make(11, 12).a) != 11): return 16
	ast_record_factory* factory = ast_record_make
	if 1: (returned = factory(21, 4))
	if (returned.a != 21 || returned.b != 4): return 17
	if ((factory(5, 6).b) != 6): return 18
	if ((callback(factory(7, 8), 9)) != 25): return 19
	if ((ast_record_sum(second = ast_record_make(10, 20), 3)) != 34): return 20
	if ((ast_record_sum(ast_record_relay(ast_record_make(1, 2)), 3)) != 7): return 21
	if 1: (copy = ast_record_make_large(6))
	copy.values[0] = 99
	if (copy.small.a != 6 || copy.values[2] != 30): return 22
	if ((ast_record_make_large(7).small.a) != 7): return 23
	return 0
