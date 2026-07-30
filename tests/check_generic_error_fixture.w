# An uninstantiated generic whose body is ill-typed: nothing here
# instantiates check_generic_broken, so plain compilation never parses
# past its header and the program builds and runs fine — but 'w check'
# self-instantiates it with [int] (grammar/generic.w's
# generic_check_instantiate_all) and must report the body's error at
# this file's real source location. Asserted by check_generic_test in
# build.base.json (both the failing check and the succeeding compile).
T check_generic_broken[T](T a):
	return undefined_symbol_in_generic_body(a)


int main():
	return 0
