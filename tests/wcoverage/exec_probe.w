# Stand-in for an instrumented build in coverage_test: prints the argv
# and the environment compiler/coverage_exec.w hands it.
import lib.lib
import lib.args
import lib.env


void show(char* name):
	char* value = env_get(name)
	if (value == 0): value = c"(unset)"
	print(name)
	print(c"=[")
	print(value)
	println(c"]")


int main(int argc, int argv):
	args_init(argc, argv)
	print(c"argv:")
	for i in range(args_count()):
		print(c" ")
		print(args_get(i))
	println(c"")
	show(c"W_COVERAGE_COMPILER")
	show(c"W_PROFILE_OUT")
	return 0
