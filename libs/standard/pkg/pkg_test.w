import lib.testing
import lib.file
import lib.path
import libs.standard.pkg.metadata
import libs.standard.pkg.discovery
import libs.standard.pkg.resources
import libs.standard.pkg.env
import libs.standard.pkg.install_manifest


int pkg_test_contains(char* haystack, char* needle):
	int i = 0
	int needle_len = strlen(needle)
	while (haystack[i] != 0):
		int j = 0
		while ((j < needle_len) & (haystack[i + j] == needle[j])):
			j = j + 1
		if (j == needle_len):
			return 1
		i = i + 1
	return 0


void test_metadata_reads_plan_fields():
	package_meta* meta = pkg_read_metadata(c"libs/standard/pkg/testdata/root_a/example_pkg/package.wmeta")
	assert_equal(0, meta.diagnostics.length)
	assert_strings_equal(c"example-pkg", meta.name)
	assert_strings_equal(c"1.2.3", pkg_version(meta))
	assert_strings_equal(c".", meta.root)
	assert_equal(2, meta.modules.length)
	assert_strings_equal(c"example.sub", meta.modules[1])
	assert_equal(1, meta.resources.length)
	assert_strings_equal(c"data/message.txt", meta.resources[0])
	assert_equal(1, meta.dependencies.length)
	assert_strings_equal(c"other_pkg", meta.dependencies[0].name)
	assert_strings_equal(c">=2.0.0", meta.dependencies[0].constraint)


void test_metadata_invalid_reports_diagnostics():
	package_meta* meta = pkg_read_metadata(c"libs/standard/pkg/testdata/bad_pkg/package.wmeta")
	assert1(meta.diagnostics.length >= 3)
	string_builder* diagnostics = string_new()
	for char* diag in meta.diagnostics:
		string_append(diagnostics, diag)
		string_append_char(diagnostics, 10)
	assert1(pkg_test_contains(diagnostics.data, c"invalid package name 'Bad.Name'"))
	assert1(pkg_test_contains(diagnostics.data, c"missing 'version' field"))
	assert1(pkg_test_contains(diagnostics.data, c"invalid resource path '../secret.txt'"))


void test_discovery_finds_packages_and_keeps_first_root():
	package_index* index = pkg_index_new()
	assert_equal(1, pkg_index_add_root(index, c"libs/standard/pkg/testdata/root_a"))
	assert_equal(2, pkg_index_add_root(index, c"libs/standard/pkg/testdata/root_b"))
	package_meta* meta = pkg_find(index, c"Example_Pkg")
	assert1(meta != 0)
	assert_strings_equal(c"libs/standard/pkg/testdata/root_a/example_pkg/package.wmeta", meta.meta_path)
	list[char*] modules = pkg_list_modules(meta)
	assert_equal(2, modules.length)
	char* path = pkg_module_path(meta, c"example.sub")
	assert_strings_equal(c"libs/standard/pkg/testdata/root_a/example_pkg/./example/sub.w", path)
	assert1(pkg_module_path(meta, c"example.missing") == 0)
	assert1(pkg_find(index, c"not-installed") == 0)


void test_resources_are_declared_and_traversal_safe():
	package_meta* meta = pkg_read_metadata(c"libs/standard/pkg/testdata/root_a/example_pkg/package.wmeta")
	assert_equal(1, pkg_resource_exists(meta, c"data/message.txt"))
	char* text = pkg_resource_read_text(meta, c"data/message.txt")
	assert_strings_equal(c"hello resource\x0asecond line\x0a", text)
	assert1(pkg_resource_path(meta, c"../secret.txt") == 0)
	assert1(pkg_resource_read_text(meta, c"secret.txt") == 0)


void test_env_roots_default_and_virtual_marker():
	list[char*] roots = pkg_search_roots_from_env(c"W_PKG_TEST_UNSET_ROOTS")
	assert_equal(1, roots.length)
	assert_strings_equal(c"libs", roots[0])
	file_write_text(c"bin/pyvenv.cfg", c"home = /tmp\x0a")
	assert_equal(1, pkg_is_virtual_root(c"bin"))
	assert_equal(0, pkg_is_virtual_root(c"libs/standard/pkg/testdata/root_a"))


void test_install_manifest_reports_duplicates_and_unsafe_paths():
	pkg_install_manifest* manifest = pkg_manifest_read(c"libs/standard/pkg/testdata/root_a/w-install-manifest.txt")
	assert_equal(6, manifest.files.length)
	assert_equal(0, pkg_manifest_validate(manifest, c"libs/standard/pkg/testdata/root_a"))
	assert1(manifest.diagnostics.length >= 4)
	string_builder* joined = string_new()
	for char* diag in manifest.diagnostics:
		string_append(joined, diag)
		string_append_char(joined, 10)
	assert1(pkg_test_contains(joined.data, c"duplicate manifest path: example_pkg/data/message.txt"))
	assert1(pkg_test_contains(joined.data, c"invalid manifest path: /absolute"))
	assert1(pkg_test_contains(joined.data, c"invalid manifest path: ../escape"))
	assert1(pkg_test_contains(joined.data, c"missing manifest file: missing.txt"))
