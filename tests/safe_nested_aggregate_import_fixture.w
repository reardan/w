struct NestedCell:
	ref[item] int* value
	int tag


struct NestedView:
	ref[group] NestedCell cell
	ref[group] int[] data
	int tag


ref[a] NestedView nested_view_make(ref[a] int* value, ref[a] int[] data):
	return NestedView(NestedCell(value, 3), data, 5)


ref[b] NestedView nested_view_copy(ref[b] NestedView value):
	return value
