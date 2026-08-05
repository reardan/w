# Fixture for c_import_torture_test: accessing an imported C bit-field
# member is diagnosed, not silently miscompiled. The member's storage
# lays out correctly (neighbors and sizeof are exact), but the named
# member itself is a zero-size marker — reading it would load the whole
# storage unit, so grammar/postfix_expr.w reports a dedicated error
# (libs/extras/c_import/importer.w, ci_bit_field_marker_type).
# expect_fail
# expect_stderr: struct field 'b' is an imported C bit-field; bit-field member access is not supported
# wbuild: fixture_group=c_import_torture_test
c_import "libc.so.6" c"tests/c_import_bitfield_fixture.h"


int main(int argc, int argv):
	ci_bf_basic* basic = 0
	return basic.b
