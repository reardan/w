import lib.safe_buffer


struct PartialPair:
	own int* first
	own int* second


own PartialPair* partial_pair():
	return new PartialPair(new int, new int)


own int* partial_take(own PartialPair* pair):
	return pair.first


own T* partial_identity[T](own T* item):
	return item


struct PartialBuffer:
	own WIntBuffer* buffer
	own int* stored


struct PartialView:
	own int* stored
	ref[data] int[] data


struct PartialOuter:
	own[group] PartialView* child


own[a] PartialView* partial_extract(own[a] PartialOuter* outer):
	return outer.child
