struct ast_increment_record:
	int count

int ast_increment_calls
int ast_increment_index():
	ast_increment_calls = ast_increment_calls + 1
	return 0

int main():
	int n = 10
	n++
	++n
	n--
	--n
	if (n != 10): return 1
	int16 small = -2
	++small
	small++
	if (small != 0): return 2
	float32 real = 1.5
	++real
	real--
	if (real != 1.5): return 3
	ast_increment_record record
	record.count = 20
	record.count++
	--record.count
	if (record.count != 20): return 4
	int[2] values
	values[0] = 5
	values[ast_increment_index()]++
	++values[ast_increment_index()]
	if (values[0] != 7 || ast_increment_calls != 2): return 5
	int* p = &n
	if 1: (*p)++
	--*p
	if (n != 10): return 6
	char* address = c"abc"
	address++
	if (*address != 'b'): return 7
	--address
	if (*address != 'a'): return 8
	list[int] xs = new list[int]
	xs.push(2)
	xs[0]++
	++xs[0]
	if (xs[0] != 4): return 9
	if 1 { n++; --n; }
	n
	++n
	if (n != 11): return 10
	xs.free()
	return 0
