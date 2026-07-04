# Fixture for the REPL's run-a-file-then-attach mode (make repl_test):
# main() must run first, and the prompt must still reach the definitions.
import lib.lib


int fixture_global


int fixture_helper(int a):
	return a * 2


int main(int argc, int argv):
	fixture_global = 11
	println(c"fixture main ran")
	return 0
