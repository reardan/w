import lib.lib

# Two arguments that bind the same type parameter to different types:
# the untyped constant 1 binds T = int first, then the char* argument
# conflicts with that binding.
T pick[T](T a, T b):
	if (a > b):
		return a
	return b


int main(int argc, char** argv):
	char* s = c"hello"
	return pick(1, s)
