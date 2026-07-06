import lib.lib

# Instantiation with the wrong number of type arguments (the generic
# declares one parameter, the call passes two).
T pick[T](T a, T b):
	if (a > b):
		return a
	return b


int main(int argc, char** argv):
	return pick[int, char](1, 2)
