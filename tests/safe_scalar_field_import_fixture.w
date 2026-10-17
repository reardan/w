struct ScalarPair:
	int first
	int second


struct ScalarOwner:
	ScalarPair pair
	own int* stored


struct ScalarArrays:
	int[2] first
	int[2] second


ScalarPair scalar_pair(int value):
	return ScalarPair(value, value + 1)


int scalar_change(refmut[a] ScalarPair* pair, int value):
	refmut int* first = &pair.first
	refmut int* second = &pair.second
	*first = value
	*second = value + 1
	return *first + *second


int scalar_tick(refmut int* count):
	*count += 1
	return *count
