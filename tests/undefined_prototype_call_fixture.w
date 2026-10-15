# A prototype with no body anywhere in the program used to compile
# silently: the call below jumped to a stale backpatch-chain address
# and the binary segfaulted. A full compile now fails at the prototype
# (compiler/compiler.w's undefined_function_check), while 'w check'
# stays lenient so a single module can prototype functions whose
# bodies only the program's entry file imports
# (undefined_prototype_call_fixture.w.wbuild asserts both). Every
# such function is reported, not just the first.
# expect_fail
# expect_stderr: error: function 'undefined_proto_callee' is declared but never defined
# expect_stderr: undefined_prototype_call_fixture.w:19:5
# expect_stderr: help: define its body, or import the module that defines it
# expect_stderr: error: function 'undefined_proto_second' is declared but never defined
# reject_stderr: never_called_proto
import lib.lib


int never_called_proto(int x);
int undefined_proto_callee(int x);
int undefined_proto_second();


int main(int argc, int argv):
	return undefined_proto_callee(3) + undefined_proto_second()
