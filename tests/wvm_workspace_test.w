# wbuild: target=wvm_workspace_test tag=tests dep=wv2
# wbuild: step="bin/wv2 x64 tests/wvm_workspace_test.w -o bin/wvm_workspace_test"
# wbuild: step="bin/wvm_workspace_test"
import lib.testing
import lib.vmm.workspace
import lib.vmm.workspace_image
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


int workspace_test_hex(char* text):
	int result = 0
	for i in range(8):
		int digit = cast(int, text[i]) - '0'
		if (digit > 9): digit = cast(int, text[i]) - 'a' + 10
		asserts(c"valid hexadecimal archive field", digit >= 0 && digit < 16)
		result = result * 16 + digit
	return result


void test_workspace_boot_image():
	string_builder* base = string_from(c"bin/wvm-workspace-image-")
	string_append_int(base, getpid())
	assert_equal(0, mkdir(base.data, 448))
	char* source = path_join(base.data, c"source")
	assert_equal(0, mkdir(source, 448))
	char* nested = path_join(source, c"nested")
	assert_equal(0, mkdir(nested, 448))
	char* program = path_join(nested, c"run")
	io_result written
	assert_equal(IO_OK, file_write_text_checked(program, c"a\0b", 3, &written))
	assert_equal(0, chmod(program, 448))
	char* initrd = path_join(base.data, c"initrd")
	asserts(c"input image fixture", file_write_text(initrd, c"input"))
	char* image = path_join(base.data, c"image")
	assert_equal(1, workspace_image_create(initrd, source, base.data, image, 3, 1000))
	int fd = open(image, 0, 0)
	int size = file_size(fd)
	close(fd)
	char* data = file_read_text(image)
	asserts(c"original image prefix unchanged", mem_eq[char](data, c"input\0\0\0", 8))
	int at = 8
	int records = 0
	int found = 0
	while (at < size):
		asserts(c"complete archive header", size - at >= 110)
		assert_equal(1, mem_eq[char](data + at, c"070701", 6))
		int mode = workspace_test_hex(data + at + 14)
		int bytes = workspace_test_hex(data + at + 54)
		int namesize = workspace_test_hex(data + at + 94)
		asserts(c"bounded archive name", namesize > 0 && namesize < 4096 && namesize <= size - at - 110)
		char* name = data + at + 110
		assert_equal(0, cast(int, name[namesize - 1]))
		at = (at + 110 + namesize + 3) / 4 * 4
		asserts(c"bounded archive content", bytes >= 0 && bytes <= size - at)
		if (strcmp(name, c"wvm-import/nested/run") == 0):
			assert_equal(33216, mode) # 0100700, execute bits preserved
			assert_equal(3, bytes)
			assert_equal(1, mem_eq[char](data + at, c"a\0b", 3))
			found = found + 1
		at = (at + bytes + 3) / 4 * 4
		records = records + 1
	assert_equal(4, records) # import root, directory, file, trailer
	assert_equal(1, found)
	free(data)
	assert_equal(0, workspace_image_create(initrd, source, base.data, image, 3, 1000))
	assert_equal(0, unlink(image))
	assert_equal(0, workspace_image_create(initrd, source, base.data, image, 2, 1000))
	assert_equal(-2, open(image, 0, 0))
	char* link = path_join(source, c"escape")
	assert_equal(0, symlink(c"/etc/passwd", link))
	assert_equal(0, workspace_image_create(initrd, source, base.data, image, 1024, 1000))
	assert_equal(-2, open(image, 0, 0))
	assert_equal(0, dir_remove_all(base.data))
	free(link)
	free(image)
	free(initrd)
	free(program)
	free(nested)
	free(source)
	string_free(base)
