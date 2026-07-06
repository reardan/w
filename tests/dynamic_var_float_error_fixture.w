import lib.lib

# Floats do not box into var (v1); this must be a compile error.
int main(int argc, char** argv):
	var x = 1.5
	return 0
