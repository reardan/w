# An uninstantiated generic struct with an ill-typed field list:
# captured but never re-parsed by plain compilation, so the program
# builds fine — 'w check' self-instantiates it with [int]
# (grammar/generic.w's generic_check_instantiate_all) and must report
# the unknown field type. Asserted by check_generic_test in
# build.base.json.
struct check_generic_bad_box[T]:
	no_such_type_for_check_fixture value


int main():
	return 0
