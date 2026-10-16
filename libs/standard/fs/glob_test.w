# wbuild: x64
# wbuild: step="bin/glob_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# Expected glob results were produced by CPython 3 with
# sorted(glob.glob(pattern, recursive=True)) over the same tree.
import lib.testing
import lib.file
import libs.standard.fs.glob


# ---- fnmatch table ---------------------------------------------------------


void fm(int want, char* name, char* pattern):
	if (fnmatch_match(name, pattern) != want):
		print(c"fnmatch_match(\"")
		print(name)
		print(c"\", \"")
		print(pattern)
		if (want): print(c"\") should match\n")
		else: print(c"\") should not match\n")
	assert_equal(want, fnmatch_match(name, pattern))


void test_fnmatch_literals_and_wildcards():
	fm(1, c"abc", c"abc")
	fm(0, c"abc", c"ABC")
	fm(1, c"abc", c"a*")
	fm(1, c"abc", c"*c")
	fm(1, c"abc", c"*")
	fm(1, c"", c"*")
	fm(0, c"", c"?")
	fm(1, c"", c"")
	fm(0, c"a", c"")
	fm(1, c"abc", c"a?c")
	fm(0, c"ac", c"a?c")
	fm(1, c"abc", c"a*b*c")
	fm(1, c"aXbYc", c"a*b*c")
	fm(1, c"abcbc", c"a*bc")
	fm(0, c"abcd", c"a*bc")
	fm(1, c"abc", c"**c")
	fm(1, c"a.py", c"*.py")
	fm(0, c"a.pyc", c"*.py")
	fm(1, c"aaaaaaaaaaaaaaaaaaaaab", c"*a*a*a*a*b")
	fm(0, c"aaaaaaaaaaaaaaaaaaaaaa", c"*a*a*a*a*b")


void test_fnmatch_slash_and_dot_are_ordinary():
	fm(1, c"a/b", c"a*b")
	fm(1, c"a/b", c"a?b")
	fm(1, c".hidden", c"*")
	fm(1, c".hidden", c"?hidden")


void test_fnmatch_brackets():
	fm(1, c"b", c"[abc]")
	fm(0, c"d", c"[abc]")
	fm(1, c"d", c"[!abc]")
	fm(0, c"a", c"[!abc]")
	fm(1, c"m", c"[a-z]")
	fm(0, c"M", c"[a-z]")
	fm(1, c"M", c"[!a-z]")
	fm(1, c"]", c"[]]")
	fm(0, c"]", c"[!]]")
	fm(1, c"a", c"[!]]")
	fm(1, c"-", c"[a-]")
	fm(1, c"-", c"[-a]")
	fm(0, c"b", c"[a-]")
	fm(1, c"^", c"[^a]")
	fm(0, c"b", c"[^a]")
	fm(1, c"x-y", c"x[--/]y")
	fm(1, c"x.y", c"x[--/]y")
	fm(0, c"x0y", c"x[--/]y")
	fm(1, c"file7.txt", c"file[0-9].txt")
	fm(0, c"file10.txt", c"file[0-9].txt")


void test_fnmatch_unclosed_and_empty_sets():
	fm(1, c"[", c"[")
	fm(1, c"[a", c"[a")
	fm(0, c"a", c"[a")
	fm(0, c"a", c"[z-a]")
	fm(1, c"a", c"[!z-a]")
	fm(0, c"x", c"[!]")
	fm(1, c"[!]", c"[!]")


void test_fnmatch_escapes():
	fm(1, c"a*b", c"a\\*b")
	fm(0, c"axb", c"a\\*b")
	fm(1, c"a?", c"a\\?")
	fm(0, c"ab", c"a\\?")
	fm(1, c"[x]", c"\\[x]")
	fm(0, c"x", c"\\[x]")
	fm(1, c"a\\", c"a\\")
	fm(1, c"\\", c"[\\]")
	fm(1, c"ab", c"\\a\\b")


void test_fnmatch_bytes_are_unsigned():
	# U+00E9 is two bytes: '?' matches one byte, "??" both.
	fm(0, c"\xc3\xa9", c"?")
	fm(1, c"\xc3\xa9", c"??")
	fm(1, c"\xc3\xa9", c"[\xc3][\x80-\xbf]")
	fm(0, c"a", c"[\x80-\xff]")


void test_fnmatch_filter():
	list[char*] names = new list[char*]
	names.push(c"a.py")
	names.push(c"b.txt")
	names.push(c"c.py")
	list[char*] got = fnmatch_filter(names, c"*.py")
	assert_equal(2, got.length)
	assert_strings_equal(c"a.py", got[0])
	assert_strings_equal(c"c.py", got[1])
	glob_free(got)
	list_free[char*](names)


void test_glob_has_magic_and_escape():
	assert_equal(0, glob_has_magic(c"plain/path.txt"))
	assert_equal(1, glob_has_magic(c"a*"))
	assert_equal(1, glob_has_magic(c"a?"))
	assert_equal(1, glob_has_magic(c"[a]"))
	assert_equal(1, glob_has_magic(c"a\\b"))
	char* e = glob_escape(c"a*b?c[d]\\e")
	assert_strings_equal(c"a[*]b[?]c[[]d][\\]e", e)
	assert_equal(1, fnmatch_match(c"a*b?c[d]\\e", e))
	assert_equal(0, fnmatch_match(c"aXbYc[d]\\e", e))
	free(e)


# ---- glob over a temp tree -------------------------------------------------


char* gt_root = 0


char* gt_path(char* rel):
	return path_join(gt_root, rel)


void gt_write(char* rel):
	char* p = gt_path(rel)
	assert1(file_write_text(p, rel) != 0)
	free(p)


void gt_mkdir(char* rel):
	char* p = gt_path(rel)
	assert_equal(0, mkdir(p, 493))
	free(p)


# bin/glob_test_<pid>/ holding
#   a.txt b.py .hidden.py star*name.txt
#   .hdir/x.py  empty/  sub/{c.py, d.txt, deep/e.py, .h2/f.py}
#   link -> sub   dangling -> missing
void gt_setup():
	string_builder* s = string_new()
	string_append(s, c"bin/glob_test_")
	string_append_int(s, getpid())
	gt_root = s.data
	free(s)
	dir_remove_all(gt_root)
	assert_equal(0, mkdir(gt_root, 493))
	gt_mkdir(c".hdir")
	gt_mkdir(c"empty")
	gt_mkdir(c"sub")
	gt_mkdir(c"sub/deep")
	gt_mkdir(c"sub/.h2")
	gt_write(c"a.txt")
	gt_write(c"b.py")
	gt_write(c".hidden.py")
	gt_write(c"star*name.txt")
	gt_write(c".hdir/x.py")
	gt_write(c"sub/c.py")
	gt_write(c"sub/d.txt")
	gt_write(c"sub/deep/e.py")
	gt_write(c"sub/.h2/f.py")
	char* p = gt_path(c"link")
	assert_equal(0, symlink(c"sub", p))
	free(p)
	p = gt_path(c"dangling")
	assert_equal(0, symlink(c"missing", p))
	free(p)


void gt_teardown():
	assert_equal(0, dir_remove_all(gt_root))
	assert_equal(0, path_exists(gt_root))
	free(gt_root)
	gt_root = 0


int gt_has_prefix(char* s, char* prefix, int plen):
	int i = 0
	while (i < plen):
		if (s[i] != prefix[i]): return 0
		i = i + 1
	return 1


# The results joined with ",", with the root prefix written as "R".
char* gt_render(list[char*] results, char* prefix):
	string_builder* s = string_new()
	int plen = strlen(prefix)
	int i = 0
	while (i < results.length):
		char* r = results[i]
		if (i > 0): string_append(s, c",")
		if ((plen > 0) && gt_has_prefix(r, prefix, plen)):
			string_append(s, c"R")
			string_append(s, &r[plen])
		else: string_append(s, r)
		i = i + 1
	char* out = s.data
	free(s)
	return out


# glob(<root>/rel) must equal expected (comma-separated, root as "R").
void gt_check(char* rel, char* expected):
	char* pattern = strjoin(gt_root, rel)
	list[char*] got = glob_glob(pattern)
	char* rendered = gt_render(got, gt_root)
	if (strcmp(rendered, expected) != 0):
		print(c"glob ")
		print(pattern)
		print(c"\n  got:  ")
		print(rendered)
		print(c"\n  want: ")
		print(expected)
		print(c"\n")
	assert_strings_equal(expected, rendered)
	free(rendered)
	glob_free(got)
	free(pattern)


# Relative pattern against the current directory.
void gt_check_here(char* pattern, char* expected):
	list[char*] got = glob_glob(pattern)
	char* rendered = gt_render(got, c"")
	if (strcmp(rendered, expected) != 0):
		print(c"glob ")
		print(pattern)
		print(c"\n  got:  ")
		print(rendered)
		print(c"\n")
	assert_strings_equal(expected, rendered)
	free(rendered)
	glob_free(got)


void test_glob_single_level():
	gt_setup()
	gt_check(c"/*", c"R/a.txt,R/b.py,R/dangling,R/empty,R/link,R/star*name.txt,R/sub")
	gt_check(c"/*.py", c"R/b.py")
	gt_check(c"/?.txt", c"R/a.txt")
	gt_check(c"/[ab].*", c"R/a.txt,R/b.py")
	gt_check(c"/[!a]*", c"R/b.py,R/dangling,R/empty,R/link,R/star*name.txt,R/sub")
	gt_check(c"/nomatch*", c"")
	gt_check(c"/sub/*/*.py", c"R/sub/deep/e.py")
	gt_check(c"/*/c.py", c"R/link/c.py,R/sub/c.py")
	gt_check(c"//sub//*.py", c"R//sub/c.py")
	gt_teardown()


void test_glob_hidden_rule():
	gt_setup()
	gt_check(c"/.*", c"R/.hdir,R/.hidden.py")
	gt_check(c"/.*.py", c"R/.hidden.py")
	gt_check(c"/.hdir/*", c"R/.hdir/x.py")
	gt_check(c"/[.]hidden.py", c"")
	gt_check(c"/**/.h2/*", c"R/link/.h2/f.py,R/sub/.h2/f.py")
	gt_teardown()


void test_glob_literals():
	gt_setup()
	gt_check(c"/a.txt", c"R/a.txt")
	gt_check(c"/missing", c"")
	gt_check(c"/dangling", c"R/dangling")
	gt_check(c"/link/c.py", c"R/link/c.py")
	gt_check(c"/sub/", c"R/sub/")
	gt_check(c"/a.txt/", c"")
	gt_teardown()


void test_glob_trailing_slash_dirs_only():
	gt_setup()
	gt_check(c"/*/", c"R/empty/,R/link/,R/sub/")
	gt_check(c"/emp?y/**", c"R/empty/")
	gt_teardown()


void test_glob_recursive():
	gt_setup()
	gt_check(c"/**", c"R/,R/a.txt,R/b.py,R/dangling,R/empty,R/link,R/link/c.py,R/link/d.txt,R/link/deep,R/link/deep/e.py,R/star*name.txt,R/sub,R/sub/c.py,R/sub/d.txt,R/sub/deep,R/sub/deep/e.py")
	gt_check(c"/**/*.py", c"R/b.py,R/link/c.py,R/link/deep/e.py,R/sub/c.py,R/sub/deep/e.py")
	gt_check(c"/**/", c"R/,R/empty/,R/link/,R/link/deep/,R/sub/,R/sub/deep/")
	gt_check(c"/sub/**", c"R/sub/,R/sub/c.py,R/sub/d.txt,R/sub/deep,R/sub/deep/e.py")
	gt_check(c"/sub/**/", c"R/sub/,R/sub/deep/")
	# "**" inside a longer segment is an ordinary star.
	gt_check(c"/s**", c"R/star*name.txt,R/sub")
	gt_teardown()


void test_glob_escaped_magic():
	gt_setup()
	gt_check(c"/star\\*name.txt", c"R/star*name.txt")
	gt_check(c"/star[*]name.txt", c"R/star*name.txt")
	char* literal = gt_path(c"star*name.txt")
	char* escaped = glob_escape(literal)
	list[char*] got = glob_glob(escaped)
	assert_equal(1, got.length)
	assert_strings_equal(literal, got[0])
	glob_free(got)
	free(escaped)
	free(literal)
	gt_teardown()


void test_glob_relative_to_cwd():
	gt_setup()
	assert_equal(0, chdir(gt_root))
	gt_check_here(c"**", c"a.txt,b.py,dangling,empty,link,link/c.py,link/d.txt,link/deep,link/deep/e.py,star*name.txt,sub,sub/c.py,sub/d.txt,sub/deep,sub/deep/e.py")
	gt_check_here(c"*.py", c"b.py")
	gt_check_here(c"**/*.py", c"b.py,link/c.py,link/deep/e.py,sub/c.py,sub/deep/e.py")
	gt_check_here(c"*/", c"empty/,link/,sub/")
	gt_check_here(c"**/", c"empty/,link/,link/deep/,sub/,sub/deep/")
	gt_check_here(c"", c"")
	assert_equal(0, chdir(c"../.."))
	gt_teardown()


void test_glob_missing_directory():
	list[char*] got = glob_glob(c"/nonexistent_w_glob_dir_91x/*")
	assert_equal(0, got.length)
	glob_free(got)
	got = glob_glob(c"/nonexistent_w_glob_dir_91x/**")
	assert_equal(0, got.length)
	glob_free(got)
