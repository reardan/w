import tests.safe_mutable_view_import_fixture


optrefmut[a] int* optional_view_data(optrefmut[a] MutableViewOuter* view):
	if (view): return view.child.data
	return 0


optref[a] MutableViewOuter* optional_view_shared(optref[a] MutableViewOuter* view):
	return view


optrefmut[a] T* optional_view_identity[T](optrefmut[a] T* view):
	return view


void optional_view_increment(optrefmut[a] MutableViewOuter* view):
	if (view): mutable_view_increment(view)
