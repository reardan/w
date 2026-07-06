import lib.lib

# A type parameter that appears only in the return type cannot be
# inferred from the call's arguments: the call needs the explicit
# 'make[int]()' instantiation syntax.
T make[T]():
	T value = 0
	return value


int main(int argc, char** argv):
	return make()
