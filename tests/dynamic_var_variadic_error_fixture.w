import lib.lib

# var as a W-variadic element type is out of scope (v1); this must be a
# clean compile error, not a miscompile.
int vsum(var... values):
	return 0


int main(int argc, char** argv):
	return vsum(1, 2)
