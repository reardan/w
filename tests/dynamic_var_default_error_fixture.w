import lib.lib

# Default values on var parameters are out of scope (v1); this must be
# a clean compile error, not a miscompile.
int f(var x = 5):
	return 0


int main(int argc, char** argv):
	return f()
