# wbuild: arch_only=win64
# The win64 runtime's file, directory and working-directory calls take
# and return UTF-8 (through the wide Win32 API), and paths of 248 or more
# UTF-16 units use the extended \\?\ form, so names outside the system
# code page and paths past MAX_PATH (260) work. Runs under wine or Windows.
import lib.testing
import lib.file
import lib.dir

char* utf8_root = c"bin/win64_utf8_paths"

void remove_tree():
	dir_remove_all(utf8_root)

char* read_text(char* path):
	int fd = open(path, 0, 0)
	asserts(c"open for reading", fd >= 0)
	char* data = cast(char*, malloc(256))
	int n = read(fd, data, 255)
	close(fd)
	asserts(c"read", n >= 0)
	data[n] = 0
	return data

void write_text(char* path, char* text):
	int fd = open(path, 577, 420)
	asserts(c"open for writing", fd >= 0)
	assert_equal(strlen(text), write(fd, text, strlen(text)))
	assert_equal(0, close(fd))

int listed(char* dir, char* name):
	for char* entry in dir_names(dir):
		if (strcmp(entry, name) == 0): return 1
	return 0

void test_non_ascii_names():
	remove_tree()
	assert_equal(0, mkdir(utf8_root, 493))
	# "Qualification Ü" and a CJK name: neither is in a Western code page.
	char* folder = strjoin(utf8_root, c"/Qualification \xc3\x9c")
	assert_equal(0, mkdir(folder, 493))
	char* first = strjoin(folder, c"/\xe5\x9b\xb3.mmd")
	write_text(first, c"flowchart LR\n")
	assert_strings_equal(c"flowchart LR\n", read_text(first))
	asserts(c"listing has the CJK name", listed(folder, c"\xe5\x9b\xb3.mmd"))
	asserts(c"listing has the folder", listed(utf8_root, c"Qualification \xc3\x9c"))
	char* second = strjoin(folder, c"/\xc3\xa9t\xc3\xa9.mmd")
	assert_equal(0, rename(first, second))
	assert_strings_equal(c"flowchart LR\n", read_text(second))
	asserts(c"old name gone", open(first, 0, 0) < 0)
	# The working directory round-trips through UTF-8 too.
	char[4096] before
	asserts(c"getcwd", getcwd(&before[0], 4096) > 0)
	assert_equal(0, chdir(folder))
	char[4096] inside
	asserts(c"getcwd inside", getcwd(&inside[0], 4096) > 0)
	asserts(c"cwd ends in the non-ASCII folder", ends_with(&inside[0], c"Qualification \xc3\x9c"))
	assert_strings_equal(c"flowchart LR\n", read_text(c"\xc3\xa9t\xc3\xa9.mmd"))
	assert_equal(0, chdir(&before[0]))
	assert_equal(0, unlink(second))
	assert_equal(0, rmdir(folder))
	remove_tree()

# A file created through CreateFileW with hand-built UTF-16 (U+00DC U+56F3)
# is found by the UTF-8 calls under the UTF-8 spelling of the same name,
# which the old ANSI calls would have read in the system code page.
void test_names_match_the_wide_api():
	remove_tree()
	assert_equal(0, mkdir(utf8_root, 493))
	char* prefix = c"bin/win64_utf8_paths/"
	int n = strlen(prefix)
	char* wide = cast(char*, malloc((n + 3) * 2))
	for i in range(n): save_int16(wide + i * 2, prefix[i])
	save_int16(wide + n * 2, 220)          /* U+00DC */
	save_int16(wide + n * 2 + 2, 22259)    /* U+56F3 */
	save_int16(wide + n * 2 + 4, 0)
	int handle = CreateFileW(wide, 1073741824, 3, 0, 2, 128, 0)
	asserts(c"CreateFileW", handle != -1)
	assert_equal(3, write(handle, c"ok\n", 3))
	close(handle)
	assert_strings_equal(c"ok\n", read_text(c"bin/win64_utf8_paths/\xc3\x9c\xe5\x9b\xb3"))
	asserts(c"listed in UTF-8", listed(utf8_root, c"\xc3\x9c\xe5\x9b\xb3"))
	remove_tree()

void test_paths_past_max_path():
	remove_tree()
	assert_equal(0, mkdir(utf8_root, 493))
	char* deep = utf8_root
	while (strlen(deep) < 300):
		deep = strjoin(deep, c"/a-long-folder-name-for-the-path-limit")
		assert_equal(0, mkdir(deep, 493))
	char* path = strjoin(deep, c"/long.mmd")
	asserts(c"over MAX_PATH", strlen(path) > 300)
	write_text(path, c"long\n")
	assert_strings_equal(c"long\n", read_text(path))
	char* moved = strjoin(deep, c"/moved.mmd")
	assert_equal(0, rename(path, moved))
	asserts(c"listing past MAX_PATH", listed(deep, c"moved.mmd"))
	assert_equal(0, unlink(moved))
	remove_tree()
	asserts(c"tree removed", open(utf8_root, 0, 0) < 0)
