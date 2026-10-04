# GPU-free launch marshalling: these stand-ins inspect host argument cells.
import lib.lib

int ast_gpu_raw_seen
int ast_gpu_for_seen
int ast_gpu_errors
int ast_gpu_ticks
int ast_gpu_expected_pointer


int ast_gpu_tick(int value):
	ast_gpu_ticks += 1
	return value


void __w_gpu_launch_raw(char* name, int grid, int block, int* values, int count):
	ast_gpu_raw_seen += 1
	if (strcmp(name, c"ast_gpu_write") != 0): ast_gpu_errors += 1
	if (grid != 2 || block != 16 || count != 2): ast_gpu_errors += 1
	if (values[0] != 4 || values[1] != ast_gpu_expected_pointer): ast_gpu_errors += 1


void __w_gpu_launch(char* name, int n, int* values, int count):
	ast_gpu_for_seen += 1
	if (starts_with(name, c"__w_gpu_kernel_") == 0): ast_gpu_errors += 1
	if (n != 4): ast_gpu_errors += 1
	if (values[0] != 7 || values[1] != ast_gpu_expected_pointer): ast_gpu_errors += 1
	if (ast_gpu_for_seen == 1):
		if (count != 3 || values[2] != 4): ast_gpu_errors += 1
	else:
		if (count != 4 || values[2] != 5 || values[3] != 1): ast_gpu_errors += 1


kernel ast_gpu_write(int* out, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if (i < n): out[i] = i


int main():
	int[8] values
	int* out = &values[0]
	ast_gpu_expected_pointer = cast(int, out)
	int bias = 7
	launch ast_gpu_write[ast_gpu_tick(2), ast_gpu_tick(16)](out, ast_gpu_tick(4))
	gpu for int i in range(ast_gpu_tick(4)):
		out[i] = i + bias
	gpu for int i in range(ast_gpu_tick(1), ast_gpu_tick(5)):
		out[i] = i + bias
	if (ast_gpu_raw_seen != 1 || ast_gpu_for_seen != 2): return 1
	if (ast_gpu_ticks != 6): return 2
	if (ast_gpu_errors != 0): return 3
	return 0
