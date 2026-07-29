# Uninstantiated generics whose bodies are valid for the synthetic
# [int] self-instantiation 'w check' performs (grammar/generic.w's
# generic_check_instantiate_all): the check must stay clean — empty
# stdout under --json, exit 0. A main-less library module on purpose
# (check's entry_optional path). Asserted by check_generic_test in
# build.base.json.
struct check_generic_pair[T]:
	T first
	T second


T check_generic_pick[T](T a, T b):
	if (cast(int, a) < cast(int, b)):
		return b
	return a


check_generic_pair[T]* check_generic_pair_new[T](T a, T b):
	check_generic_pair[T]* p = cast(check_generic_pair[T]*, malloc(2 * __word_size__))
	p.first = a
	p.second = b
	return p
