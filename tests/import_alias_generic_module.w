# Module for import_alias_generic_inline_test: a generic body whose
# one-line loop calls a runtime helper the inliner expands.
int alias_grow[K](K key):
	int capacity = 8
	while capacity < 20: capacity = __w_size_mul(capacity, 2)
	return capacity
