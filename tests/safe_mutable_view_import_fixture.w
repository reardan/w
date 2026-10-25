struct MutableViewLeaf:
	own int* stored
	refmut[data] int* data
	ref[text] int[] text
	int tag


struct MutableViewOuter:
	own[left, right] MutableViewLeaf* child


refmut[a] int* mutable_view_data(refmut[a] MutableViewOuter* view):
	return view.child.data


ref[a] int[] mutable_view_text(ref[a] MutableViewOuter* view):
	return view.child.text


refmut[a] T* mutable_view_identity[T](refmut[a] T* view):
	return view


void mutable_view_increment(refmut[a] MutableViewOuter* view):
	refmut MutableViewLeaf* child = view.child
	child.tag += 1
	refmut int* value = child.data
	*value += 1
