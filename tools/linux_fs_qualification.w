# wbuild: binary=linux_fs_qualification tag=tests
# wbuild: target=fs_fault_linux_test tag=tests dep=wv2 dep=linux_fs_qualification
# wbuild: step="bin/linux_fs_qualification --arch x86 --arch x64"
# wbuild: target=fs_fault_arm64_test tag=tests_arm64 dep=wv2 dep=wrun dep=linux_fs_qualification
# wbuild: step="bin/linux_fs_qualification --arch arm64"
# Injected syscall failures and SIGKILL around fs_replace_durable's file
# sync, rename and directory sync on Linux (#608), the counterpart of
# tools/mac/test_fs_durability.w. A private import overlay replaces only
# the fsync and rename bodies of the target's syscall adapter with
# tests/fs_linux_fault_hooks.w; lib/fs.w is compiled unchanged. arm64
# runs through bin/wrun (qemu-user on an x86_64 host, so that leg checks
# the AArch64 adapter and error propagation, not hardware durability).
# Process kills keep the kernel and its caches alive: this is not
# power-loss evidence.
import tools.host_tools
import lib.str
import libs.standard.cli.argparse
import libs.standard.fs.glob

char* lf_runner


int lf_run(char* executable, char* target, int stage, int crash = 0, int error = 5):
	list[char*] argv = ht_argv(executable, target, itoa(stage), itoa(crash), itoa(error))
	if (lf_runner != 0):
		argv = ht_argv(lf_runner, c"arm64", executable, target, itoa(stage), itoa(crash), itoa(error))
	return ht_run(argv, 0, 0, 60000).status


# Replaces the single occurrence of each original with its replacement.
char* lf_patch(char* source, char* originals, char* replacements):
	list[char*] from = ht_split(originals, '|')
	list[char*] to = ht_split(replacements, '|')
	for i in range(from.length):
		int at = index_of(source, from[i])
		ht_require(at >= 0 && index_of(source + at + strlen(from[i]), from[i]) < 0, strjoin(c"update interception for changed syscall adapter: ", from[i]))
		source = replace(source, from[i], to[i])
	return source


int lf_qualify(char* compiler, char* arch):
	char* work = ht_temp()
	char* overlay = path_join(work, c"imports")
	char* adapter = c"lib/syscalls_linux_x86.w"
	char* originals = c"syscall(SYS_FSYNC, file, 0, 0)|syscall(SYS_RENAME, oldpath, newpath, 0)"
	lf_runner = 0
	if (strcmp(arch, c"arm64") == 0):
		adapter = c"lib/arm64/syscalls.w"
		originals = c"syscall(82, file, 0, 0)|syscall7(38, arm64_at_fdcwd, oldpath, arm64_at_fdcwd, newpath, 0, 0)"
		lf_runner = ht_resolve(c"bin/wrun")
	char* source = lf_patch(ht_read(adapter).data, originals, c"fs_fault_fsync(file)|fs_fault_rename(oldpath, newpath)")
	char* patched = path_join(overlay, adapter)
	ht_mkdir(path_dirname(patched))
	ht_require(file_write_text(patched, strjoin(c"import tests.fs_linux_fault_hooks\n", source)), c"cannot write syscall overlay")
	char* fixture = c"tests/fs_linux_fault_fixture.w"
	char* executable = path_join(work, c"fixture")
	# The default (i386) target has no selector word.
	if (strcmp(arch, c"x86") == 0):
		ht_checked(ht_argv(compiler, c"check", c"--json", c"--import-root", overlay, fixture))
		ht_checked(ht_argv(compiler, c"--import-root", overlay, c"--strict", fixture, c"-o", executable))
	else:
		ht_checked(ht_argv(compiler, c"check", c"--json", arch, c"--import-root", overlay, fixture))
		ht_checked(ht_argv(compiler, arch, c"--import-root", overlay, c"--strict", fixture, c"-o", executable))
	char* target = path_join(work, c"state")
	int cases = 0
	# Injected failures: EIO, EINTR, EINVAL (a refused barrier), EOPNOTSUPP
	# and ENOSPC at each sync; EIO and ENOSPC at the rename.
	for stage in range(1, 6, 2):
		list[char*] errors = split(c"5 4 22 95 28")
		if (stage == 3): errors = split(c"5 28")
		for char* error in errors:
			ht_write(target, c"old contents", 12)
			ht_require(lf_run(executable, target, stage, 0, atoi(error)) == 0, strjoin(c"fault propagation failed: errno ", error))
			char* expected = c"old contents"
			if (stage == 5): expected = c"new contents"
			ht_equal_file(target, expected)
			ht_require(glob_glob(path_join(work, c"state.tmp.*")).length == 0, c"failed replace leaked its temp file")
			ht_require(lf_run(executable, target, 0) == 0, c"recovery publication failed")
			ht_equal_file(target, c"new contents")
			cases = cases + 1
	# SIGKILL before/after the file sync, the rename and the directory sync.
	for stage in range(1, 7):
		ht_write(target, c"old contents", 12)
		ht_require(lf_run(executable, target, stage, 1) == 137, c"fixture did not terminate with SIGKILL")
		char* expected = c"new contents"
		int count = 0
		if (stage <= 3):
			expected = c"old contents"
			count = 1
		ht_equal_file(target, expected)
		list[char*] leftovers = glob_glob(path_join(work, c"state.tmp.*"))
		ht_require(leftovers.length == count, c"incorrect crash artifact count")
		ht_require(lf_run(executable, target, 0) == 0, c"recovery publication failed")
		ht_equal_file(target, c"new contents")
		for char* leftover in leftovers:
			ht_equal_file(leftover, c"new contents")
			ht_require(unlink(leftover) == 0, c"cannot remove crash artifact")
		cases = cases + 1
	println(strjoin(strjoin(strjoin(c"Linux ", arch), strjoin(c" durability: ", itoa(cases))), c" fault/crash cases and recovery passed"))
	return cases


int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"linux_fs_qualification")
	argparse_arg_default(argparse_add_option(parser, c"--compiler", c"FILE", c"host compiler"), c"bin/wv2")
	argparse_arg_choices(argparse_add_list(parser, c"--arch", c"ARCH", c"target (repeatable)"), c"x86,x64,arm64")
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	ht_require(contains(ht_checked(ht_command(c"uname -s")).stdout_text, c"Linux"), c"requires a Linux host")
	char* compiler = tempfile_abspath(argparse_get(args, c"compiler"))
	list[char*] archs = argparse_get_list(args, c"arch")
	ht_require(archs.length > 0, c"pass at least one --arch")
	for char* arch in archs: lf_qualify(compiler, arch)
	ht_cleanup()
	return 0
