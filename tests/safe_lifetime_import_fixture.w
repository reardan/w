# Imported lifetime labels must constrain the caller's resolved storage.
ref[shared] int* lifetime_import_choose(ref[shared] int* a, ref[shared] int* b, int first):
	if first: return a
	return b


refmut[exclusive] int* lifetime_import_first(refmut[exclusive] int* a, ref[other] int* b):
	return a
