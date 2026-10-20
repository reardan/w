# WASI has no subprocess API; Windows lacks the candidate-file primitives.
import tools.reduce_common


int reduce_main(int argc, int argv):
	char** args = cast(char**, argv)
	if ((argc == 3) && ((strcmp(args[2], c"--help") == 0) || (strcmp(args[2], c"-h") == 0))):
		reduce_usage()
		return 0
	return reduce_error(c"reduction currently requires a Unix host")
