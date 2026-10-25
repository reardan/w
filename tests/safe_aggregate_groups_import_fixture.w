struct SplitView:
	ref[value] int* item
	ref[data] int[] data
	int tag


ref[a, b] SplitView split_view(ref[a] int* item, ref[b] int[] data):
	return SplitView(item, data, 7)


ref[a, b] SplitView split_copy(ref[a, b] SplitView value):
	return value


ref[a] int* split_first(ref[a, b] SplitView value):
	return value.item
