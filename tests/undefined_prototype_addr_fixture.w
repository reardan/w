# Companion to undefined_prototype_call_fixture.w on the x64 target:
# taking a bodiless prototype's address (a function-pointer value)
# resolves through the same backpatch chain as a call, so it is the
# same missing-body error.
# wfixture: x64
# expect_fail
# expect_stderr: error: function 'undefined_proto_target' is declared but never defined
# expect_stderr: undefined_prototype_addr_fixture.w:12:5
import lib.lib


int undefined_proto_target(int x);


int main(int argc, int argv):
	int f = cast(int, undefined_proto_target)
	return f != 0
