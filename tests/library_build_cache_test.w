# Generated library targets must carry both scheduler dependencies and
# cache inputs. Exercise a real leaf -> middle -> executable chain.
# wbuild: tool=tools/wbuildgen.w tool=tools/wexec_main.w
import lib.testing
import tests.tool_e2e
import lib.file


void library_cache_write(char* dir, char* path, char* text):
	char* full = path_join(dir, path)
	assert_equal(1, file_write_text(full, text))
	free(full)


void library_cache_success(process_result* r):
	if (r.status != 0):
		println2(r.stdout_text)
		println2(r.stderr_text)
	assert_equal(0, r.status)


void library_cache_run_app(char* dir, int expected):
	char* path = path_join(dir, c"bin/app")
	char** argv = strv_new(1)
	strv_set(argv, 0, path)
	spawn_options* options = spawn_options_new()
	options.cwd = dir
	process_result* r = process_run(path, argv, options, 0, 10000)
	assert1(r != 0)
	if (r.status != expected): println2(r.stderr_text)
	assert_equal(expected, r.status)
	process_result_free(r)
	free(options)
	free(cast(void*, argv))
	free(path)


void test_library_consumer_deps_without_link_flags():
	# Build-cache closure discovery scans source without reproducing the
	# eventual link arguments. Extern-only consumers must remain scannable.
	process_result* r = tool_run(0, c"wv2", c"deps", c"x64", c"tools/compiler_shared.w")
	library_cache_success(r)
	assert_contains(r.stdout_text, c"tools/compiler_shared.w")
	process_result_free(r)


void test_library_transitive_cache_invalidation():
	char* rel = tool_scratch(c"library_build_cache_")
	char* dir = path_join(tool_root(), rel)
	free(rel)
	assert_equal(0, mkdir(dir, 493))
	char* bin = path_join(dir, c"bin")
	assert_equal(0, mkdir(bin, 493))
	free(bin)
	char* tests = path_join(dir, c"tests")
	assert_equal(0, mkdir(tests, 493))
	free(tests)
	char* compiler = path_join(dir, c"bin/wv2")
	assert_equal(0, symlink(tool_bin(c"wv2"), compiler))
	free(compiler)
	library_cache_write(dir, c"base.json", c"{\"dirs\":[\"bin\"],\"targets\":[{\"name\":\"wv2\",\"inputs\":[\"bin/wv2\"],\"outputs\":[\"bin/wv2\"]},{\"name\":\"tests\",\"deps\":[]}]}")
	char* flags = strjoin(c" flags=\"--import-root=", tool_root())
	char* suffix = strjoin(flags, c"\"\n")
	free(flags)
	char* leaf_header = strjoin(c"# wbuild: library=leaf kind=shared arch=x64", suffix)
	char* leaf = strjoin(leaf_header, c"export int leaf_value():\n\treturn 40\n")
	library_cache_write(dir, c"tests/z_leaf.w", leaf)
	free(leaf)
	char* middle_header = strjoin(c"# wbuild: library=middle kind=shared arch=x64 link=leaf", suffix)
	char* middle = strjoin(middle_header, c"extern int leaf_value()\nexport int middle_value():\n\treturn leaf_value() + 2\n")
	library_cache_write(dir, c"tests/b_middle.w", middle)
	free(middle)
	free(middle_header)
	char* app_header = strjoin(c"# wbuild: binary=app arch=x64 link=middle tag=tests", suffix)
	char* app = strjoin(app_header, c"import tests.library_cache_helper\nextern int middle_value()\nint main():\n\treturn middle_value() + helper_offset()\n")
	library_cache_write(dir, c"tests/a_app.w", app)
	library_cache_write(dir, c"tests/library_cache_helper.w", c"int helper_offset():\n\treturn 0\n")
	free(app)
	free(app_header)
	free(suffix)
	process_result* r = tool_run(dir, c"wbuildgen", c"--base", c"base.json", c"--out", c"build.json")
	library_cache_success(r)
	process_result_free(r)
	r = tool_run(dir, c"wexec", c"-f", c"build.json", c"-j", c"3", c"app")
	library_cache_success(r)
	assert_lacks(r.stdout_text, c"leaf (cached)")
	assert_lacks(r.stdout_text, c"middle (cached)")
	assert_lacks(r.stdout_text, c"app (cached)")
	process_result_free(r)
	library_cache_run_app(dir, 42)
	r = tool_run(dir, c"wexec", c"-f", c"build.json", c"app")
	library_cache_success(r)
	assert_contains(r.stdout_text, c"leaf (cached)")
	assert_contains(r.stdout_text, c"middle (cached)")
	assert_contains(r.stdout_text, c"app (cached)")
	process_result_free(r)
	leaf = strjoin(leaf_header, c"export int leaf_value():\n\treturn 41\n")
	library_cache_write(dir, c"tests/z_leaf.w", leaf)
	free(leaf)
	free(leaf_header)
	r = tool_run(dir, c"wexec", c"-f", c"build.json", c"app")
	library_cache_success(r)
	assert_lacks(r.stdout_text, c"leaf (cached)")
	assert_lacks(r.stdout_text, c"middle (cached)")
	assert_lacks(r.stdout_text, c"app (cached)")
	process_result_free(r)
	library_cache_run_app(dir, 43)
	# Imported consumer source is not an explicit artifact input. Its
	# closure hash must still invalidate this target, leaving the two
	# unchanged libraries cached.
	library_cache_write(dir, c"tests/library_cache_helper.w", c"int helper_offset():\n\treturn 1\n")
	r = tool_run(dir, c"wexec", c"-f", c"build.json", c"app")
	library_cache_success(r)
	assert_contains(r.stdout_text, c"leaf (cached)")
	assert_contains(r.stdout_text, c"middle (cached)")
	assert_lacks(r.stdout_text, c"app (cached)")
	process_result_free(r)
	library_cache_run_app(dir, 44)
	dir_remove_all(dir)
	free(dir)
