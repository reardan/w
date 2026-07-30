# Fixture for c_import_torture_test: extern array objects. Unknown-length
# extern arrays (the sys_errlist shape) used to be skipped because COPY
# space cannot be sized without an extent; they now import by address as
# pointer globals (ci_import_data_array), so indexing compiles for
# unknown-length, known-length and multi-dimensional (flattened) arrays
# alike. The body indexes every one — an import regression surfaces as
# an undefined symbol and fails this compile.
# reject_stderr: c_import:
# wbuild: fixture_group=c_import_torture_test
c_import "libc.so.6" c"tests/c_import_extern_array_fixture.h"


int ci_arr_use_all():
	char* message = ci_arr_errlist[2]
	int count = ci_arr_counts[1]
	char* name = ci_arr_names[0]
	int cell = ci_arr_matrix[4]
	int small = ci_arr_shorts[3]
	if ((message != 0) && (name != 0)):
		count = count + cell + small
	return count


int main(int argc, int argv):
	return 0
