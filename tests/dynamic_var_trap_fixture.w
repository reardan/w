import lib.lib

# Unboxing a var with the wrong runtime tag must trap: print a
# recognizable message to stderr and exit non-zero.
int main(int argc, char** argv):
	var x = c"hello"
	int n = x
	print_int(c"unreachable: ", n)
	return 0
