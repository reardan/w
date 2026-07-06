import lib.lib

# '%' is not dispatched on var operands; this must be a compile error.
int main(int argc, char** argv):
	var x = 5
	var y = x % 2
	return 0
