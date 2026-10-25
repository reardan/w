# Shared differential input for the production x64 backend and wllvm:
# method calls, new T[n], '?' propagation, var values, W variadics,
# generic container iterables, float map updates, raw_asm, an
# import-alias statement and the host side of launch / gpu for (GPU-free
# stand-ins replace lib.cuda's entry points and check the argument
# cells). Output and exit status must match exactly.
import lib.lib
import lib.result
import structures.heap
import tests.level1.level2.level3.level_file as deep


struct forms_point:
	int x
	int y


void forms_point_move(forms_point* self, int dx, int dy):
	self.x = self.x + dx
	self.y = self.y + dy


int forms_point_sum(forms_point* self):
	return self.x + self.y


int forms_scaled(int value, int factor):
	return value * factor


wresult[int]* forms_find(int key):
	if (key < 0): return result_new_error[int](-2)
	return result_new_ok[int](key * 10)


wresult[int]* forms_sum_two(int a, int b):
	int total = forms_find(a)? + forms_find(b)?
	return result_new_ok[int](total)


int forms_vsum(int base, int... values):
	int total = base
	for int v in values: total = total + v
	return total


var forms_var_add(var a, var b):
	return a + b


int forms_gpu_raw_seen
int forms_gpu_for_seen
int forms_gpu_errors
int forms_gpu_expected


void __w_gpu_launch_raw(char* name, int grid, int block, int* values, int count):
	forms_gpu_raw_seen += 1
	if (strcmp(name, c"forms_write") != 0): forms_gpu_errors += 1
	if (grid != 2 || block != 16 || count != 2): forms_gpu_errors += 1
	if (values[0] != 4 || values[1] != forms_gpu_expected): forms_gpu_errors += 1


void __w_gpu_launch(char* name, int n, int* values, int count):
	forms_gpu_for_seen += 1
	if (starts_with(name, c"__w_gpu_kernel_") == 0): forms_gpu_errors += 1
	if (n != 4): forms_gpu_errors += 1


kernel forms_write(int* out, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if (i < n): out[i] = i


int main():
	int score = 0
	# methods: a record receiver passes its address, a word receiver
	# is the first argument
	forms_point p
	p.x = 1
	p.y = 2
	p.move(3, 4)
	if (p.sum() == 10): score += 1
	int five = 5
	if (five.forms_scaled(3) == 15): score += 1
	# new T[n]
	int[] cells = new int[5]
	for i in range(5): cells[i] = i * i
	if (cells.length == 5 && cells[4] == 16): score += 1
	# '?'
	wresult[int]* good = forms_sum_two(2, 3)
	if (good.ok && good.value == 50): score += 1
	wresult[int]* bad = forms_sum_two(2, -1)
	if ((bad.ok == 0) && bad.code == -2): score += 1
	# var
	var a = 10
	var b = forms_var_add(a, 5)
	int unboxed = b
	if (unboxed == 15): score += 1
	print(b)
	println(c"")
	# W variadics
	if (forms_vsum(1) == 1 && forms_vsum(1, 2, 3, 4) == 10): score += 1
	# a generic container iterable
	heap[int]* h = heap_new[int]()
	for int v in list[int]{5, 1, 4}: heap_push[int](h, v)
	int heap_total = 0
	for int x in h: heap_total = heap_total + x
	if (heap_total == 10): score += 1
	# float map values: compound assignment and add
	map[int, float64] weights = new map[int, float64]
	weights[1] = 1.5
	weights[1] += 0.25
	if (weights.add(1) == 2.75 && weights.add(2, 0.5) == 0.5): score += 1
	# raw_asm and an import-alias statement
	raw_asm(c"\x90\x90")
	deep.level_file_variable = 42
	if (deep.level_file_variable == 42): score += 1
	# launch and gpu for, host side
	int[8] values
	int* out = &values[0]
	forms_gpu_expected = cast(int, out)
	launch forms_write[2, 16](out, 4)
	int bias = 7
	gpu for int i in range(4):
		out[i] = i + bias
	if (forms_gpu_raw_seen == 1 && forms_gpu_for_seen == 1 && forms_gpu_errors == 0): score += 1
	println(score)
	return score
