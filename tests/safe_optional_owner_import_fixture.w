struct OptionalOwnerBox:
	optown int* child
	int tag


struct OptionalOwnerMixed:
	optown int* child
	ref[data] int* external


optown int* optional_owner_make(int value, int present):
	if (present == 0): return 0
	own int* result = new int
	*result = value
	return result


optown T* optional_owner_identity[T](optown T* value):
	return value


optown[a] OptionalOwnerMixed* optional_owner_mixed(ref[a] int* external, int present):
	if (present == 0): return 0
	return new OptionalOwnerMixed(optional_owner_make(4, 1), external)
