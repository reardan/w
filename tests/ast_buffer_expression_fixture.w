struct ast_buffer_record:
	int16[3] items
	int tag

struct ast_buffer_element:
	int tag
	int value

int ast_buffer_order
int ast_buffer_index(int i):
	ast_buffer_order = ast_buffer_order * 10 + i
	return i

int ast_buffer_sum(int[] items): return (items[0] + items[1] + items[2])

int main():
	int[3] values
	values[0] = 10
	values[1] = 20
	values[2] = 30
	if ((values[0] + values[2]) != 40): return 1
	if ((values[ast_buffer_index(1)] + values[ast_buffer_index(2)]) != 50): return 2
	if (ast_buffer_order != 12): return 3
	if ((values[1] += values[0]) != 30): return 4
	if ((values[2] = values[0] * 4) != 40): return 5
	if (ast_buffer_sum(values) != 80): return 6
	ast_buffer_record record
	record.items[0] = 100
	record.items[1] = 200
	record.items[2] = 300
	record.tag = 7
	ast_buffer_record* p = &record
	if ((p.items[1] + record.items[2]) != 500): return 7
	if ((record.items[0] += 25) != 125): return 8
	ast_buffer_element[2] records
	records[1].tag = 42
	records[1].value = 64
	if ((records[1].tag + records[1].value) != 106): return 9
	string text = s"abc"
	if ((text[0] + text[2]) != 196): return 10
	if (("xyz"[1]) != 121): return 11
	int16* address = (&p.items[1])
	if (*address != 200): return 12
	return 0
