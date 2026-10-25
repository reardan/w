struct GenericBorrowed:
	ref[first] int* scalar
	ref[second] int[] values


struct GenericNested:
	ref[left, right] GenericBorrowed child
	int tag


struct GenericMutable:
	refmut[data] int* value


ref[x, y] T generic_shape_identity[T](ref[x, y] T value):
	return value


ref[result] T[] generic_shape_slice[T](ref[source] T[] value, int start) where source > result:
	return value[start:]


refmut[result] T generic_shape_mutable[T](refmut[result] T value):
	return value


ref[a, b] GenericBorrowed generic_shape_callback(ref[a, b] GenericBorrowed value):
	return generic_shape_identity[GenericBorrowed](value)
