# wbuild: binary=darwin_fs_qualification tag=tests
# Private import overlay intercepts only fullsync/rename; production is unchanged.
import tools.host_tools
import lib.str
import libs.standard.cli.argparse
import libs.standard.fs.glob

int df_run(char* executable, char* target, int stage, int crash = 0, int error = 5):
	return ht_run(ht_argv(executable, target, itoa(stage), itoa(crash), itoa(error)), 0, 0, 15000).status

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"darwin_fs_qualification")
	argparse_arg_default(argparse_add_option(parser, c"--compiler", c"FILE", c"native compiler"), c"bin/wv2_darwin")
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	ht_require(contains(ht_checked(ht_command(c"uname -s")).stdout_text, c"Darwin") && contains(ht_checked(ht_command(c"uname -m")).stdout_text, c"arm64"), c"requires a native Apple Silicon Mac")
	char* compiler = tempfile_abspath(argparse_get(args, c"compiler"))
	char* work = ht_temp()
	char* overlay = path_join(work, c"imports")
	char* source = ht_read(c"lib/darwin/syscalls.w").data
	list[char*] originals = ht_split(c"sys_fcntl(file, 51, 0)|syscall(128, oldpath, newpath, 0)", '|')
	list[char*] replacements = ht_split(c"fs_fault_fullsync(file)|fs_fault_rename(oldpath, newpath)", '|')
	for i in range(2):
		int at = index_of(source, originals[i])
		ht_require(at >= 0 && index_of(source + at + strlen(originals[i]), originals[i]) < 0, strjoin(c"update interception for changed syscall adapter: ", originals[i]))
		source = replace(source, originals[i], replacements[i])
	char* patched = path_join(overlay, c"lib/darwin/syscalls.w")
	ht_mkdir(path_dirname(patched))
	ht_require(file_write_text(patched, strjoin(c"import tests.fs_darwin_fault_hooks\n", source)), c"cannot write syscall overlay")
	char* fixture = c"tests/fs_darwin_fault_fixture.w"
	ht_checked(ht_argv(compiler, c"check", c"--json", c"arm64_darwin", c"--import-root", overlay, fixture))
	char* binary = path_join(work, c"fixture")
	ht_checked(ht_argv(compiler, c"arm64_darwin", c"--import-root", overlay, c"--strict", fixture, c"-o", binary))
	char* executable = path_join(work, c"fixture.run")
	ht_require(shutil_copy(binary, executable) == 0, c"cannot make fresh executable inode")
	char* target = path_join(work, c"state")
	int cases = 0
	for stage in range(1, 6, 2):
		list[char*] errors = split(c"5 4 22 45 102")
		if (stage == 3): errors = split(c"5")
		for char* error in errors:
			ht_write(target, c"old contents", 12)
			ht_require(df_run(executable, target, stage, 0, atoi(error)) == 0, c"fault propagation failed")
			char* expected = c"old contents"
			if (stage == 5): expected = c"new contents"
			ht_equal_file(target, expected)
			ht_require(glob_glob(path_join(work, c"state.tmp.*")).length == 0, c"failed replace leaked its temp file")
			ht_require(df_run(executable, target, 0) == 0, c"recovery publication failed")
			ht_equal_file(target, c"new contents")
			cases = cases + 1
	for stage in range(1, 7):
		ht_write(target, c"old contents", 12)
		ht_require(df_run(executable, target, stage, 1) == 137, c"fixture did not terminate with SIGKILL")
		char* expected = c"new contents"
		int count = 0
		if (stage <= 3):
			expected = c"old contents"
			count = 1
		ht_equal_file(target, expected)
		list[char*] leftovers = glob_glob(path_join(work, c"state.tmp.*"))
		ht_require(leftovers.length == count, c"incorrect crash artifact count")
		ht_require(df_run(executable, target, 0) == 0, c"recovery publication failed")
		ht_equal_file(target, c"new contents")
		for char* leftover in leftovers:
			ht_equal_file(leftover, c"new contents")
			ht_require(unlink(leftover) == 0, c"cannot remove crash artifact")
		cases = cases + 1
	ht_cleanup()
	println(strjoin(strjoin(c"Darwin durability: ", itoa(cases)), c" fault/crash cases and recovery passed"))
	return 0
