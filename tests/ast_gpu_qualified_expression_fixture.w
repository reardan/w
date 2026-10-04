import lib.lib

struct ast_gpu_cell:
	int32 count
	float32 weight

kernel ast_gpu_fields(gpu ast_gpu_cell* cells, gpu int16* small, int n):
	int i = thread_idx()
	if (i < n):
		cells[i].count = cells[i].count + i
		cells[i].weight += 1.5
		small[i]++
		int stored = (cells[i].count = 7)
		cells[i].count = stored * 2
		gpu int16* address = small + 2
		*address = small[i]

int main():
	gpu uint16** nested = cast(gpu uint16**, 0)
	if (nested != 0): return 1
	gpu ast_gpu_cell* p = cast(gpu ast_gpu_cell*, 0)
	gpu ast_gpu_cell* q = true ? p : 0
	if (q != 0): return 2
	if (sizeof(gpu uint16*) != __word_size__): return 3
	gpu int* words = cast(gpu int*, 4096)
	if (cast(int, &words[3]) != 4096 + 3 * __word_size__): return 4
	if (cast(int, &*(words + 8)) != 4104): return 5
	gpu ast_gpu_cell* cells = cast(gpu ast_gpu_cell*, 8192)
	if (cast(int, &cells.weight) != 8196): return 6
	if (cast(int, &cells[2].count) != 8192 + 2 * sizeof(ast_gpu_cell)): return 7
	return 0
