# Prototypes that are never referenced stay legal (no error, no
# warning), and a prototype whose body appears later in the program
# resolves its forward call and address-of sites when the body is
# compiled. Companion to undefined_prototype_call_fixture.w, where a
# called prototype never gets a body.
# wbuild: x64
import lib.lib
import lib.assert


int prototype_never_used(int x);
int prototype_defined_later(int x);


type int_unary = fn(int) -> int


int call_through(int_unary* f, int x):
	return f(x)


int main(int argc, int argv):
	assert_equal(7, prototype_defined_later(6))
	assert_equal(11, call_through(prototype_defined_later, 10))
	println(c"prototype_unused_test: ok")
	return 0


int prototype_defined_later(int x):
	return x + 1
