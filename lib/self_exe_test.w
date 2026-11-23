# wbuild: x64 arch=arm64_darwin
# lib/self_exe.w: the path names this very test binary.
import lib.testing
import lib.self_exe
import lib.path
import lib.stat


void test_self_exe_path():
	char* path = self_exe_path()
	assert1(path != 0)
	assert_equal('/', path[0])
	char* name = path_basename(path)
	assert1(starts_with(name, c"self_exe"))
	file_stat st
	assert_equal(0, file_stat_path(path, &st))
	assert1(file_is_reg(&st))
	free(name)
	free(path)
