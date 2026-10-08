int ast_atomic_order
int* ast_atomic_pointer(int* value):
	ast_atomic_order = ast_atomic_order * 10 + 1
	return value

int ast_atomic_value(int value, int mark):
	ast_atomic_order = ast_atomic_order * 10 + mark
	return value

int ast_atomic_shadow();

int main():
	int value = 10
	if (atomic_add(ast_atomic_pointer(&value), ast_atomic_value(2, 2)) != 10): return 1
	if (value != 12 || ast_atomic_order != 12): return 2
	ast_atomic_order = 0
	if (atomic_cas(ast_atomic_pointer(&value), ast_atomic_value(12, 2), ast_atomic_value(20, 3)) != 12): return 3
	if (value != 20 || ast_atomic_order != 123): return 4
	if (atomic_cas(&value, 12, 30) != 20 || value != 20): return 5
	if (atomic_add(&value, -25) != 20 || value != -5): return 6
	if (atomic_add(&value, 2.5) != -5 || value != -3): return 7
	int other = 4
	if (atomic_add(&value, atomic_add(&other, 2)) != -3): return 8
	if (value != 1 || other != 6): return 9
	int* address = &value
	if (atomic_cas(address, 1, 8) != 1 || value != 8): return 10
	if (__word_size__ == 8):
		value = 1 << 40
		if (atomic_add(&value, 3) != (1 << 40)): return 11
		if (atomic_cas(&value, (1 << 40) + 3, 7) != (1 << 40) + 3): return 12
		if (value != 7): return 13
	if (ast_atomic_shadow() != 30): return 14
	ast_atomic_order = 0
	atomic_store(ast_atomic_pointer(&value), ast_atomic_value(31, 2))
	if (ast_atomic_order != 12): return 15
	if (atomic_load(&value) != 31): return 16
	atomic_fence()
	atomic_store_relaxed(&value, -4)
	if (atomic_load_relaxed(&value) != -4): return 17
	return 0

# Declared after the intrinsic call sites: the ordinary symbol shadows
# the builtin only for later expressions.
int atomic_add(int a, int b): return a + b
int ast_atomic_shadow(): return atomic_add(10, 20)
