import lib.lib

# A 'pair[T]* p' parameter mentions T in a position v1 inference cannot
# invert (the shape is opaque), so T stays unbound and the call needs
# the explicit 'sum_first[int](pp)' syntax.
struct pair[T]:
	T first
	T second


T sum_first[T](pair[T]* p):
	return p.first


int main(int argc, char** argv):
	pair[int] p
	p.first = 1
	p.second = 2
	pair[int]* pp = &p
	return sum_first(pp)
