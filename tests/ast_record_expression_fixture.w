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
	return 0
