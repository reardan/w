struct ast_ctor_pair:
	int x
	int y

struct ast_ctor_nested:
	ast_ctor_pair pair
	int tag

struct ast_ctor_buffer:
	int[2] data
	int tag

union ast_ctor_union:
	int bits
	char low

int ast_ctor_sequence

int ast_ctor_tick(int value):
	ast_ctor_sequence = ast_ctor_sequence * 10 + value
	return value

int ast_ctor_sum(ast_ctor_pair value): return value.x + value.y

ast_ctor_pair ast_ctor_make(int value): return ast_ctor_pair(value, value + 1)

int main():
	ast_ctor_pair first = ast_ctor_pair(1, 2)
	if (first.x != 1 || first.y != 2): return 1
	first = ast_ctor_pair(3, 4)
	if ((ast_ctor_sum(ast_ctor_pair(5, 6))) != 11): return 2
	if ((ast_ctor_pair(7, 8).y) != 8): return 3
	ast_ctor_pair named = ast_ctor_pair(y: ast_ctor_tick(1), x: ast_ctor_tick(2))
	if (ast_ctor_sequence != 12 || named.x != 2 || named.y != 1): return 4
	ast_ctor_pair partial = ast_ctor_pair(y: 9)
	if (partial.x != 0 || partial.y != 9): return 5
	ast_ctor_nested nested = ast_ctor_nested(ast_ctor_make(10), 12)
	if (nested.pair.x != 10 || nested.pair.y != 11 || nested.tag != 12): return 6
	ast_ctor_pair* heap = new ast_ctor_pair(13, 14)
	if (heap.x != 13 || heap.y != 14): return 7
	ast_ctor_pair* named_heap = new ast_ctor_pair(y: 15)
	if (named_heap.x != 0 || named_heap.y != 15): return 8
	ast_ctor_nested* large = new ast_ctor_nested(ast_ctor_pair(16, 17), 18)
	if (large.pair.y != 17 || large.tag != 18): return 9
	ast_ctor_buffer buffer = ast_ctor_buffer()
	if (buffer.data.length != 2 || buffer.data[0] != 0): return 10
	ast_ctor_buffer* allocated_buffer = new ast_ctor_buffer()
	if (allocated_buffer.data.length != 2 || allocated_buffer.data[1] != 0): return 11
	list[ast_ctor_pair] records = list[ast_ctor_pair]{ast_ctor_pair(19, 20), ast_ctor_pair(x: 21)}
	if (records[0].y != 20 || records[1].x != 21 || records[1].y != 0): return 12
	if ((ast_ctor_nested(ast_ctor_pair(22, 23), 24).pair.x) != 22): return 13
	ast_ctor_union u = ast_ctor_union(bits: 25)
	if (u.bits != 25 || u.low != 25): return 14
	free(cast(char*, heap))
	free(cast(char*, named_heap))
	free(cast(char*, large))
	free(cast(char*, allocated_buffer))
	records.free()
	return 0
