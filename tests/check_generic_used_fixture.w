# A generic whose body is only meaningful for the char* it is really
# instantiated with: strlen(a) would warn about an int argument. Because
# the file instantiates it, 'w check' must NOT add a synthetic [int]
# instantiation (grammar/generic.w's generic_def_used) — the check stays
# clean. Locks the suppression policy of generic_check_instantiate_all.
# Asserted by check_generic_test in build.base.json.
import lib.lib


int check_generic_len[T](T a):
	return strlen(a)


int check_generic_used_consumer():
	return check_generic_len[char*](c"abc")
