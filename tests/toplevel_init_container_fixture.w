# A value whose storage is not a single scalar word cannot carry a
# top-level initializer (grammar/program.w's
# global_initializer_check_type): a list needs its allocation and
# element copies to run, which a top-level declaration has no place to
# run. Declare it here and fill it inside a function.
# expect_fail
# expect_stderr: cannot initialize global 'items' of type 'list[int]' at its declaration; assign it inside a function
import lib.lib


list[int] items = 0


int main(int argc, int argv):
	return items.length
