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
	return 0
