struct DisjointPair:
	own int* first
	own int* second


own DisjointPair* disjoint_pair():
	return new DisjointPair(new int, new int)


int disjoint_change(refmut[a] DisjointPair* pair, int value):
	refmut int* first = pair.first
	refmut int* second = pair.second
	*first = value
	*second = value + 1
	return *first + *second


refmut[a] int* disjoint_first(refmut[a] DisjointPair* pair):
	return pair.first


refmut[a] T* disjoint_identity[T](refmut[a] T* item):
	return item
