optref[a] int* optional_import_choose(ref[a] int* left, ref[a] int* right, int choose):
	if choose == 0: return 0
	if choose == 1: return left
	return right


optrefmut int* optional_import_mutable(optrefmut int* value):
	return value
