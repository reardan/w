# wbuild: target=type_check_lint_test tag=tests dep=wv2
# wbuild: step="bin/wv2 check --quiet tests/type_check_lint_fixture.w" reject_stderr="warning:"
# wbuild: step="bin/wv2 check --lint --quiet tests/type_check_lint_fixture.w" expect_stderr="warning: called object of type 'int' is not a function; declare it as a function pointer ('type callback = fn(int) -> int', then 'callback* f') [call-int]" expect_stderr="warning: initialization converts 'void*' to 'int*' without cast() [void-pointer-conversion]" expect_stderr="warning: assignment converts 'void*' to 'char*' without cast() [void-pointer-conversion]" expect_stderr="warning: function 'take_ints' argument 1 converts 'void*' to 'int*' without cast() [void-pointer-conversion]" reject_stderr="'void*' to 'void*'" reject_stderr="'int*' to"
# wbuild: step="bin/wv2 check --lint --strict --quiet tests/type_check_lint_fixture.w" expect_fail expect_stderr="warning(s) treated as errors (--strict)"
# Issue #532's two opt-in type lint rules (grammar/type_check.w):
# calling an int ([call-int]) and converting void* to a typed pointer
# without cast() ([void-pointer-conversion]). Both idioms are common
# enough across the tree (int-held callbacks, 'T* p = malloc(n)') that
# they stay out of the always-on warnings; a plain 'w check' must be
# silent on this file.
import lib.lib


type int_callback = fn(int) -> int


int twice(int x):
	return x * 2


void take_ints(int* p):
	pass


int call_through_int(int f):
	return f(3)


int call_through_typed(int_callback* f):
	return f(3)


void void_pointers(void* raw):
	int* ints = raw
	char* chars = cast(char*, raw)
	chars = raw
	take_ints(raw)
	void* again = raw
	void* from_typed = ints


int main():
	int f = cast(int, twice)
	void_pointers(malloc(8))
	return call_through_int(f) + call_through_typed(twice) - 12
