# A top-level initializer must be a compile-time constant
# (grammar/program.w's global_initializer): nothing runs before main to
# evaluate a call, so this is rejected by name instead of falling
# through to the bare "valid primary expression" parse error the '='
# used to produce.
# expect_fail
# expect_stderr: initializer for global 'computed' must be a compile-time constant, got 'compute'
import lib.lib


int compute():
	return 7


int computed = compute()


int main(int argc, int argv):
	return computed
