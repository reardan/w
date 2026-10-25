import lib.lib

# A 'pair[T]* p' parameter binds T from the argument's instance, but a
# composite type argument ('pair[T*]*') stays opaque to inference, so T
# stays unbound and the call needs the explicit 'sum_first[int](pp)'
# syntax.
struct pair[T]:
	T first
	T second


T sum_first[T](pair[T*]* p):
	return *p.first


int main(int argc, char** argv):
	int x = 1
	pair[int*] p
	p.first = &x
	p.second = &x
	pair[int*]* pp = &p
	return sum_first(pp)
