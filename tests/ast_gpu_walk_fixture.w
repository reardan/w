# S2.2e: launch and gpu for statements whose headers the --ast-emit-retained
# walk emits after their parse (ast_retained_emit_test compiles this in
# both modes and compares images and diagnostics). GPU-free stand-ins
# replace lib.cuda's runtime entry points. The argument warnings are
# intended: they are emitted by the walk and must keep their place among
# the parse's diagnostics.
import lib.lib

int walk_launches
int walk_loops
int walk_ticks


int walk_tick(int value):
	walk_ticks += 1
	return value


void __w_gpu_launch_raw(char* name, int grid, int block, int* values, int count):
	walk_launches += 1


void __w_gpu_launch(char* name, int n, int* values, int count):
	walk_loops += 1


kernel walk_none():
	pass


kernel walk_pair(int* out, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if (i < n): out[i] = i


kernel walk_scalar(int a, int b):
	pass


int main():
	int[8] values
	int* out = &values[0]
	int bias = 3
	int n = 8
	launch walk_none[1, 1]()
	launch walk_pair[walk_tick(1), walk_tick(8)](out, n)
	launch walk_pair[walk_tick(2), walk_tick(4)](out,
		walk_tick(n))
	launch walk_scalar[1, 32](c"cells", walk_tick(n) + bias)
	launch walk_scalar[n / 4, n * 4](walk_tick(bias), c"cells")
	gpu for int i in range(walk_tick(n)):
		out[i] = i + bias
	gpu for int i in range(walk_tick(1),
		walk_tick(n)):
		out[i] = out[i] * bias + n
	gpu for int i in range(n): out[i] = bias
	if (walk_launches != 5 || walk_loops != 3): return 1
	if (walk_ticks != 10): return 2
	return 0
