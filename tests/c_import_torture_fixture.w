# Fixture for c_import_torture_test: system-header torture shapes —
# forward-declared struct typedefs, nested unions, anonymous inner
# structs, named and unnamed bit-fields (laid out per the SysV ABI;
# see tests/c_import_bitfield_fixture.w for the dedicated battery),
# array and function-pointer fields, enum constant expressions,
# function typedefs, macro-sized extern arrays, and K&R declarations
# mixed with prototyped variadic ones. The body uses the imported
# types, constants, arrays and functions, so an import regression
# fails this compile.
# reject_stderr: c_import:
# reject_stderr: header parse failed
# wbuild: fixture_group=c_import_torture_test
c_import "libc.so.6" c"tests/c_import_torture_fixture.h"


int ci_tt_use_all():
	ci_tt_node_t* node = ci_tt_head
	int total = CI_TT_A + CI_TT_B + CI_TT_C
	ci_tt_word mask = ci_tt_masks[3]
	char* first_name = ci_tt_names[0]
	ci_tt_handler handler = 0
	if (node != 0):
		node = node.next
	if (node != 0):
		total = total + node.origin.row + node.cells
	if ((first_name != 0) && (handler == 0)):
		total = total + ci_tt_old()
		total = total + ci_tt_older(2, c"x")
		total = total + ci_tt_mixed(mask, c"name", 1, 2)
	return total


int main(int argc, int argv):
	return 0
