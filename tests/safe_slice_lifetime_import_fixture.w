ref[borrow] int[] slice_lifetime_import_view(ref[borrow] int[] values):
	return values


ref[borrow] int* slice_lifetime_import_element(ref[borrow] int[] values):
	return &values[0]
