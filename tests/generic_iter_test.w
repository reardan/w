# wbuild: x64
# Every fixture below fails to compile on purpose; each step pins one
# diagnostic of the for-in container protocol (grammar/for_statement.w).
#
# Generic-container iteration: 'for x in <generic struct instance>*'
# resolves the protocol functions as '<base>_iter_*[T]' instantiations.
# These fixtures pin every rejection on that path:
# wbuild: step="bin/wv2 tests/generic_iter_no_protocol_fixture.w -o bin/generic_iter_no_protocol_fixture" expect_fail expect_stderr="box3_iter_begin not found"
# wbuild: step="bin/wv2 tests/generic_iter_two_params_fixture.w -o bin/generic_iter_two_params_fixture" expect_fail expect_stderr="box3_iter_begin must take exactly one type parameter"
# wbuild: step="bin/wv2 tests/generic_iter_arity_fixture.w -o bin/generic_iter_arity_fixture" expect_fail expect_stderr="box3_iter_begin$int has wrong arity"
# wbuild: step="bin/wv2 tests/generic_iter_return_fixture.w -o bin/generic_iter_return_fixture" expect_fail expect_stderr="box3_iter_value$int must return a word-sized value"
# wbuild: step="bin/wv2 tests/generic_iter_param_mismatch_fixture.w -o bin/generic_iter_param_mismatch_fixture" expect_fail expect_stderr="box3_iter_begin$int first parameter must match the iterable type"
# wbuild: step="bin/wv2 tests/generic_iter_cursor_fixture.w -o bin/generic_iter_cursor_fixture" expect_fail expect_stderr="box3_iter_done$int second parameter must be int"
#
# The plain (non-generic) cursor protocol checks the same arity rules
# before the instantiation is interned:
# wbuild: step="bin/wv2 tests/plain_iter_cursor_fixture.w -o bin/plain_iter_cursor_fixture" expect_fail expect_stderr="plain_iter_done second parameter must be int"
#
# Container-kind restrictions and loop-variable compatibility:
# wbuild: step="bin/wv2 tests/slice_struct_elements_fixture.w -o bin/slice_struct_elements_fixture" expect_fail expect_stderr="slice iteration requires scalar or pointer elements"
# wbuild: step="bin/wv2 tests/string_iter_no_utf8_fixture.w -o bin/string_iter_no_utf8_fixture" expect_fail expect_stderr="string iteration requires import lib.utf8"
# wbuild: step="bin/wv2 tests/for_aggregate_value_var_fixture.w -o bin/for_aggregate_value_var_fixture" expect_fail expect_stderr="for loop value variable must be a word-sized type"
# wbuild: step="bin/wv2 tests/for_list_var_mismatch_fixture.w -o bin/for_list_var_mismatch_fixture" expect_fail expect_stderr="for loop variable type mismatch: expected 'char*', got 'int'"
# wbuild: step="bin/wv2 tests/for_map_var_mismatch_fixture.w -o bin/for_map_var_mismatch_fixture" expect_fail expect_stderr="for loop variable type mismatch: expected 'char*', got 'int'"
# wbuild: step="bin/wv2 tests/for_slice_var_mismatch_fixture.w -o bin/for_slice_var_mismatch_fixture" expect_fail expect_stderr="for loop variable type mismatch: expected 'char*', got 'int'"
# wbuild: step="bin/wv2 tests/for_string_var_mismatch_fixture.w -o bin/for_string_var_mismatch_fixture" expect_fail expect_stderr="for loop variable type mismatch: expected 'char*', got 'int'"
/*
generic_iter_test: the for-in container protocol's rejections.

The happy paths (list, map, slice, string, plain struct iterators,
generic containers) are covered by for_test, string_utf8_test,
ast_loop_switch_walk_fixture and generics_test. These fixtures pin the
diagnostics: the generic '<base>_iter_*' instantiation checks (missing
protocol, one-type-parameter rule, arity, word-sized return, iterable
type match, int cursor), the same cursor check on the plain protocol,
the slice/string container restrictions, the aggregate value-variable
rejection, and the loop-variable compatibility diagnostics for every
container kind (list one- and two-variable, map, slice, string).

Each fixture deliberately fails to compile; the steps assert the exact
stderr needles. The x64 twin keeps the checks pinned on the 64-bit
target too (the generic instantiation machinery is word-size aware).
*/
import lib.lib

# The steps above are the test; the program body only has to exist so
# the target's compile step succeeds.
int main():
	return 0
