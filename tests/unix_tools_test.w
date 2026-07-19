/*
End-to-end tests for tools/{stat,chmod,touch,readlink}.w. Spawns the
compiled binaries via lib/process.w against a pid-scoped work directory
under bin/, matching tests/wvc_e2e_test.w.
*/
import lib.testing
import lib.process
import lib.path
import lib.file
import lib.stat
import lib.time
import structures.string


char* utt_repo_root_cache


char* utt_repo_root():
	if (utt_repo_root_cache == 0):
		char* buf = malloc(4096)
		int n = getcwd(buf, 4096)
		assert1(n > 0)
		utt_repo_root_cache = buf
	return utt_repo_root_cache


char* utt_bin(char* name):
	return path_join(utt_repo_root(), path_join(c"bin", name))


char* utt_dir_cache


char* utt_dir():
	if (utt_dir_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/unix_tools_test_")
		string_append_int(p, getpid())
		utt_dir_cache = p.data
		free(p)
		mkdir(c"bin", 493)
		char** rm_argv = strv_new(3)
		strv_set(rm_argv, 0, c"/bin/rm")
		strv_set(rm_argv, 1, c"-rf")
		strv_set(rm_argv, 2, utt_dir_cache)
		process_result* rm = process_run(c"/bin/rm", rm_argv, 0, 0, 10000)
		assert1(rm != 0)
		process_result_free(rm)
		free(cast(void*, rm_argv))
		assert_equal(0, mkdir(utt_dir_cache, 493))
	return utt_dir_cache


char* utt_join(char* name):
	return path_join(utt_dir(), name)


char** utt_argv(list[char*] args):
	char** v = strv_new(args.length)
	int i = 0
	for char* a in args:
		strv_set(v, i, a)
		i = i + 1
	return v


process_result* utt_run(char* bin_name, list[char*] args):
	char** argv = utt_argv(args)
	process_result* r = process_run(utt_bin(bin_name), argv, 0, 0, 10000)
	assert1(r != 0)
	free(cast(void*, argv))
	return r


int utt_contains(char* haystack, char* needle):
	int hl = strlen(haystack)
	int nl = strlen(needle)
	if (nl == 0):
		return 1
	int i = 0
	while ((i + nl) <= hl):
		int j = 0
		while ((j < nl) && (haystack[i + j] == needle[j])):
			j = j + 1
		if (j == nl):
			return 1
		i = i + 1
	return 0


void test_touch_creates_file():
	char* path = utt_join(c"touched.txt")
	unlink(path)
	list[char*] args = new list[char*]
	args.push(c"touch")
	args.push(path)
	process_result* r = utt_run(c"touch", args)
	assert_equal(0, r.status)
	process_result_free(r)
	file_stat st
	assert_equal(0, file_stat_path(path, &st))
	assert_equal(1, file_is_reg(&st))
	assert_equal(0, st.size)
	unlink(path)


void test_chmod_sets_mode():
	char* path = utt_join(c"chmod.txt")
	assert_equal(1, file_write_text(path, c"x"))
	list[char*] args = new list[char*]
	args.push(c"chmod")
	args.push(c"600")
	args.push(path)
	process_result* r = utt_run(c"chmod", args)
	assert_equal(0, r.status)
	process_result_free(r)
	file_stat st
	assert_equal(0, file_stat_path(path, &st))
	assert_equal(384, file_mode_perm(&st))
	unlink(path)


void test_stat_prints_size_and_type():
	char* path = utt_join(c"stat_me.txt")
	assert_equal(1, file_write_text(path, c"hello"))
	list[char*] args = new list[char*]
	args.push(c"stat")
	args.push(path)
	process_result* r = utt_run(c"stat", args)
	assert_equal(0, r.status)
	assert_equal(1, utt_contains(r.stdout_text, c"Size: 5"))
	assert_equal(1, utt_contains(r.stdout_text, c"Type: regular file"))
	assert_equal(1, utt_contains(r.stdout_text, c"File: "))
	process_result_free(r)
	unlink(path)


void test_stat_nofollow_symlink():
	char* target = utt_join(c"link_target.txt")
	char* linkpath = utt_join(c"the_link")
	assert_equal(1, file_write_text(target, c"payload"))
	unlink(linkpath)
	assert_equal(0, file_symlink(c"link_target.txt", linkpath))
	list[char*] args = new list[char*]
	args.push(c"stat")
	args.push(c"-f")
	args.push(linkpath)
	process_result* r = utt_run(c"stat", args)
	assert_equal(0, r.status)
	assert_equal(1, utt_contains(r.stdout_text, c"Type: symbolic link"))
	process_result_free(r)
	unlink(linkpath)
	unlink(target)


void test_stat_nofollow_flag_after_path():
	char* target = utt_join(c"link_target2.txt")
	char* linkpath = utt_join(c"the_link2")
	assert_equal(1, file_write_text(target, c"payload"))
	unlink(linkpath)
	assert_equal(0, file_symlink(c"link_target2.txt", linkpath))
	list[char*] args = new list[char*]
	args.push(c"stat")
	args.push(linkpath)
	args.push(c"-f")
	process_result* r = utt_run(c"stat", args)
	assert_equal(0, r.status)
	assert_equal(1, utt_contains(r.stdout_text, c"Type: symbolic link"))
	process_result_free(r)
	unlink(linkpath)
	unlink(target)


void test_stat_multiple_paths_with_leading_flag():
	char* a = utt_join(c"multi_a.txt")
	char* b = utt_join(c"multi_b.txt")
	assert_equal(1, file_write_text(a, c"aaa"))
	assert_equal(1, file_write_text(b, c"bb"))
	list[char*] args = new list[char*]
	args.push(c"stat")
	args.push(c"-f")
	args.push(a)
	args.push(b)
	process_result* r = utt_run(c"stat", args)
	assert_equal(0, r.status)
	assert_equal(1, utt_contains(r.stdout_text, c"Size: 3"))
	assert_equal(1, utt_contains(r.stdout_text, c"Size: 2"))
	process_result_free(r)
	unlink(a)
	unlink(b)


void test_readlink_prints_target():
	char* target = utt_join(c"rl_target.txt")
	char* linkpath = utt_join(c"rl_link")
	assert_equal(1, file_write_text(target, c"x"))
	unlink(linkpath)
	assert_equal(0, file_symlink(c"rl_target.txt", linkpath))
	list[char*] args = new list[char*]
	args.push(c"readlink")
	args.push(linkpath)
	process_result* r = utt_run(c"readlink", args)
	assert_equal(0, r.status)
	assert_equal(1, utt_contains(r.stdout_text, c"rl_target.txt"))
	process_result_free(r)
	unlink(linkpath)
	unlink(target)


void test_readlink_no_newline_flag_after_path():
	char* target = utt_join(c"rl_target2.txt")
	char* linkpath = utt_join(c"rl_link2")
	assert_equal(1, file_write_text(target, c"x"))
	unlink(linkpath)
	assert_equal(0, file_symlink(c"rl_target2.txt", linkpath))
	list[char*] args = new list[char*]
	args.push(c"readlink")
	args.push(linkpath)
	args.push(c"-n")
	process_result* r = utt_run(c"readlink", args)
	assert_equal(0, r.status)
	assert_equal(1, utt_contains(r.stdout_text, c"rl_target2.txt"))
	assert_equal(strlen(c"rl_target2.txt"), strlen(r.stdout_text))
	process_result_free(r)
	unlink(linkpath)
	unlink(target)


void test_stat_usage_error():
	list[char*] args = new list[char*]
	args.push(c"stat")
	process_result* r = utt_run(c"stat", args)
	assert_equal(1, r.status)
	assert_equal(1, utt_contains(r.stderr_text, c"usage: stat"))
	process_result_free(r)
