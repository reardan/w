import lib.lib

# Calling a generic function without the explicit '[type-args]'
# instantiation list.
T pick[T](T a, T b):
	if (a > b):
		return a
	return b


int main(int argc, char** argv):
	return pick(1, 2)
