import lib.memory_debug
import tests.safe_disjoint_field_import_fixture


type DisjointChange = fn[a](refmut[a] DisjointPair*, int) -> int


struct DisjointOuter:
	own DisjointPair* left
	own DisjointPair* right


int disjoint_exercise():
	own DisjointOuter* outer = new DisjointOuter(disjoint_pair(), disjoint_pair())
	refmut DisjointPair* left = outer.left
	refmut DisjointPair* right = outer.right
	refmut int* first = left.first
	refmut int* second = left.second
	refmut int* third = right.first
	refmut int* fourth = right.second
	*first = 1
	*second = 2
	*third = 3
	*fourth = 4
	int sum = *first + *second + *third + *fourth
	own DisjointPair* pair = disjoint_pair()
	for i in range(100):
		refmut int* item = disjoint_identity[int](pair.first)
		pair.second = new int
		refmut int* other = pair.second
		*item = i
		*other = i + 1
		if (*item + *other != i * 2 + 1): return 0
	DisjointChange* change = disjoint_change
	int changed = change(pair, 8)
	refmut int* item = disjoint_first(pair)
	*item = 11
	return sum + changed + *item


int disjoint_exits(int early):
	for i in range(3):
		own DisjointPair* pair = disjoint_pair()
		refmut int* first = pair.first
		refmut int* second = pair.second
		*first = i
		*second = i + 1
		if (early): return *first
		if (*first == 0): continue
		break
	return 1


int main():
	int before = debug_alloc_report_leaks()
	if disjoint_exercise() != 38: return 1
	if disjoint_exits(1) != 0: return 2
	if disjoint_exits(0) != 1: return 3
	return debug_alloc_report_leaks() - before
