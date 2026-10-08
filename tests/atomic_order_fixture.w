# Portable word access, evaluation order, width and ordinary-symbol shadowing.
int order_seen

int* order_pointer(int* p):
	order_seen = order_seen * 10 + 1
	return p

int order_value(int v):
	order_seen = order_seen * 10 + 2
	return v

int order_shadow();

int main():
	int value = -7
	if (atomic_load(&value) != -7): return 1
	atomic_store(order_pointer(&value), order_value(23))
	if (order_seen != 12 || value != 23): return 2
	atomic_fence()
	atomic_store_relaxed(&value, -19)
	if (atomic_load_relaxed(&value) != -19): return 3
	if (atomic_load(&value) + atomic_load(&value) != -38): return 4
	if (__word_size__ == 8):
		atomic_store(&value, (1 << 40) + 1)
		if (atomic_load(&value) != (1 << 40) + 1): return 5
		atomic_store_relaxed(&value, (1 << 42) + 3)
		if (atomic_load_relaxed(&value) != (1 << 42) + 3): return 6
	if (order_shadow() != 45): return 7
	return 0

int atomic_load(int x): return x + 1
int atomic_store(int x, int y): return x + y
int atomic_fence(): return 30
int atomic_load_relaxed(int x): return x + 1
int atomic_store_relaxed(int x, int y): return x + y
int order_shadow():
	return atomic_load(1) + atomic_store(2, 3) + atomic_fence() + atomic_load_relaxed(2) + atomic_store_relaxed(2, 3)
