# wbuild: target=wvm_workspace_test tag=tests dep=wv2
# wbuild: step="bin/wv2 x64 tests/wvm_workspace_test.w -o bin/wvm_workspace_test"
# wbuild: step="bin/wvm_workspace_test"
import lib.testing
import lib.vmm.workspace
import lib.file
import lib.stat


void test_workspace_isolation_and_limits():
	string_builder* base = string_new()
	string_append(base, c"bin/wvm-workspace-test-")
	string_append_int(base, getpid())
	assert_equal(0, mkdir(base.data, 448))
	char* source = path_join(base.data, c"source")
	assert_equal(0, mkdir(source, 448))
	char* original = path_join(source, c"hello")
	assert_equal(1, file_write_text(original, c"original"))
	vm_workspace* a = workspace_create(source, 1024, 10, 1000)
	vm_workspace* b = workspace_create(source, 1024, 10, 1000)
	asserts(c"two private workspaces", a != 0 && b != 0)
	assert_equal(8, a.bytes)
	assert_equal(1, a.entries)
	char* first = path_join(a.path, c"hello")
	char* second = path_join(b.path, c"hello")
	assert_equal(1, file_write_text(first, c"changed"))
	char* contents = file_read_text(original)
	assert_equal(0, strcmp(contents, c"original"))
	free(contents)
	contents = file_read_text(second)
	assert_equal(0, strcmp(contents, c"original"))
	free(contents)
	file_stat st
	assert_equal(0, file_stat_path(a.path, &st))
	assert_equal(448, st.mode & 511)
	asserts(c"copy bytes bounded", workspace_create(source, 7, 10, 1000) == 0)
	char* subdir = path_join(source, c"subdir")
	assert_equal(0, mkdir(subdir, 448))
	asserts(c"entry count bounded", workspace_create(source, 1024, 1, 1000) == 0)
	char* link = path_join(source, c"escape")
	assert_equal(0, symlink(c"/etc/passwd", link))
	asserts(c"symlinks rejected", workspace_create(source, 1024, 10, 1000) == 0)
	assert_equal(0, unlink(link))
	assert_equal(0, workspace_destroy(a))
	assert_equal(0, workspace_destroy(b))
	assert_equal(0, dir_remove_all(base.data))
	free(link)
	free(subdir)
	free(first)
	free(second)
	free(original)
	free(source)
	string_free(base)
