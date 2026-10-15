# wbuild: arch=arm64_darwin
# wbuild: target=mac_build_test tag=tests_darwin dep=wtest dep=build_host_test_darwin dep=manifest_check
# wbuild: step="tools/mac/test_build.sh" expect_stdout="mac build tooling OK"
import lib.testing
import lib.dir
import tools.manifest_host
import tools.deps_cache


manifest* bh_manifest():
	return manifest_parse(c"{\"targets\":[{\"name\":\"wv2\",\"steps\":[{\"cmd\":[\"./w\",\"w.w\"]}]},{\"name\":\"wtest\",\"deps\":[\"wv2\"],\"steps\":[{\"cmd\":[\"bin/wv2\",\"tools/test_map.w\",\"-o\",\"bin/wtest\"]}]},{\"name\":\"linux_test\",\"deps\":[\"wv2\"],\"steps\":[{\"cmd\":[\"bin/wv2\",\"tests/hello.w\",\"-o\",\"bin/hello\"]},{\"cmd\":[\"bin/hello\"]}]},{\"name\":\"cross\",\"deps\":[\"wv2\"],\"steps\":[{\"cmd\":[\"bin/wv2\",\"win64\",\"tests/hello.w\",\"-o\",\"bin/hello.exe\"]}]},{\"name\":\"native_test\",\"steps\":[{\"cmd\":[\"bin/wv2_darwin\",\"arm64_darwin\",\"tests/hello.w\",\"-o\",\"bin/native\"]},{\"cmd\":[\"bin/native\"]}]},{\"name\":\"tests_darwin\",\"deps\":[\"native_test\"]},{\"name\":\"tests\",\"deps\":[\"linux_test\",\"cross\"]}]}", c"host fixture", 1)


json_value* bh_command(manifest* m, char* name):
	json_value* steps = jfield_array(m.by_name[name], c"steps")
	return jfield_array(json_array_get(steps, 0), c"cmd")


void test_host_plan_preserves_targets_and_selectors():
	manifest* m = bh_manifest()
	assert1(m != 0)
	manifest_host_prepare_darwin(m, 1)
	assert_equal(7, m.names.length)
	json_value* cmd = bh_command(m, c"wtest")
	assert_strings_equal(c"bin/wv2_darwin", json_array_get(cmd, 0).string_value)
	assert_strings_equal(c"arm64_darwin", json_array_get(cmd, 1).string_value)
	assert_strings_equal(c"tools/test_map.w", json_array_get(cmd, 2).string_value)
	assert_strings_equal(c"-o", json_array_get(cmd, 3).string_value)
	assert_strings_equal(c"bin/wtest", json_array_get(cmd, 4).string_value)
	cmd = bh_command(m, c"cross")
	assert_strings_equal(c"win64", json_array_get(cmd, 1).string_value)
	cmd = bh_command(m, c"linux_test")
	assert_strings_equal(c"tests/hello.w", json_array_get(cmd, 1).string_value)
	assert1(jfield_string(m.by_name[c"linux_test"], c"host_unavailable") != 0)
	assert1(jfield_string(m.by_name[c"cross"], c"host_unavailable") == 0)
	assert1(jfield_string(m.by_name[c"native_test"], c"host_unavailable") == 0)
	json_value* tests = m.by_name[c"tests"]
	assert_strings_equal(c"tests_darwin", json_array_get(jfield_array(tests, c"deps"), 0).string_value)
	assert_equal(2, jfield_int(tests, c"host_skipped", -1))
	assert_equal(0, json_array_length(jfield_array(m.by_name[c"wv2"], c"steps")))
	# Free the transformed tree too: copied command elements must be owned.
	json_free(m.root)


void test_custom_manifest_keeps_architecture():
	manifest* m = bh_manifest()
	manifest_host_prepare_darwin(m, 0)
	json_value* cmd = bh_command(m, c"wtest")
	assert_equal(4, json_array_length(cmd))
	assert_strings_equal(c"tools/test_map.w", json_array_get(cmd, 1).string_value)
	assert_equal(0, json_object_has(m.by_name[c"tests"], c"host_skipped"))
	json_free(m.root)


void test_native_host_preserves_ios_selectors():
	for i in range(2):
		char* arch = c"arm64_ios"
		if (i == 1): arch = c"arm64_ios_sim"
		manifest* m = bh_manifest()
		json_value* target = m.by_name[c"cross"]
		json_value* cmd = bh_command(m, c"cross")
		json_value* selector = json_array_get(cmd, 1)
		free(selector.string_value)
		selector.string_value = strclone(arch)
		manifest_host_commands(target, 1)
		cmd = bh_command(m, c"cross")
		assert_equal(5, json_array_length(cmd))
		assert_strings_equal(c"bin/wv2_darwin", json_array_get(cmd, 0).string_value)
		assert_strings_equal(arch, json_array_get(cmd, 1).string_value)
		assert_strings_equal(c"tests/hello.w", json_array_get(cmd, 2).string_value)
		json_free(m.root)


void test_unavailable_dependency_and_explicit_atomic_output():
	manifest* m = bh_manifest()
	json_value* deps = json_array()
	json_array_push(deps, json_string(c"linux_test"))
	json_object_set(m.by_name[c"cross"], c"deps", deps)
	json_value* step = json_array_get(jfield_array(m.by_name[c"cross"], c"steps"), 0)
	json_object_set(step, c"atomic_output", json_string(c"explicit.out"))
	manifest_host_prepare_darwin(m, 1)
	assert1(jfield_string(m.by_name[c"cross"], c"host_unavailable") != 0)
	assert_strings_equal(c"explicit.out", jfield_string(step, c"atomic_output"))
	json_free(m.root)


void test_other_hosts_keep_the_manifest():
	if (build_host_darwin() || build_host_android()): return
	manifest* m = bh_manifest()
	char* before = json_stringify(m.root)
	manifest_host_prepare(m, 1)
	char* after = json_stringify(m.root)
	assert_strings_equal(before, after)
	free(before)
	free(after)
	json_free(m.root)


void test_host_deps_command_and_failure_cache():
	char** args = deps_wv2_argv(c"win64|tests/wtest/host tests/wtest/host/root.w", c"check")
	assert_strings_equal(build_host_compiler(), strv_get(args, 0))
	assert_strings_equal(c"win64", strv_get(args, 1))
	assert_strings_equal(c"check", strv_get(args, 2))
	assert_strings_equal(c"--import-root", strv_get(args, 3))
	assert_strings_equal(c"tests/wtest/host", strv_get(args, 4))
	free(cast(char*, args))
	args = deps_wv2_argv(c"x86 tests/wtest/host/root.w", c"deps")
	assert_strings_equal(c"deps", strv_get(args, 1))
	free(cast(char*, args))
	deps_entry* entry = deps_entry_new(c"x86 tests/wtest/host/root.w", 0)
	entry.failed = 1
	entry.digest = deps_file_hash(entry.root)
	entry.vhash = c"old Linux compiler or previous native compiler"
	assert_equal(0, deps_entry_valid(entry, 1))
	entry.vhash = deps_file_hash(build_host_compiler())
	assert_equal(1, deps_entry_valid(entry, 1))


void test_native_directory_discovery():
	# The shell makes the symlink: Darwin's W symlink syscall is still a
	# stub. Enumeration itself, including kind decoding, is the W API.
	if (build_host_darwin() == 0): return
	list[dir_entry*] entries = dir_read(c"bin/mac_build_dir")
	assert1(entries != 0)
	assert_equal(4, entries.length)
	assert_strings_equal(c"a", entries[0].name)
	assert_equal(DIR_KIND_DIR, entries[0].kind)
	assert_strings_equal(c"b.txt", entries[1].name)
	assert_equal(DIR_KIND_FILE, entries[1].kind)
	assert_strings_equal(c"empty", entries[2].name)
	assert_equal(DIR_KIND_DIR, entries[2].kind)
	assert_strings_equal(c"link", entries[3].name)
	assert_equal(DIR_KIND_LINK, entries[3].kind)
	dir_entries_free(entries)
	list[char*] files = new list[char*]
	dir_walk_files(c"bin/mac_build_dir", files)
	assert_equal(2, files.length)
	assert_strings_equal(c"bin/mac_build_dir/a/nested.w", files[0])
	assert_strings_equal(c"bin/mac_build_dir/b.txt", files[1])
	assert1(dir_read(c"bin/mac_build_dir/missing") == 0)
	entries = dir_read(c"bin/mac_build_dir/empty")
	assert_equal(0, entries.length)
	dir_entries_free(entries)


void test_android_host_plan():
	manifest* m = bh_manifest()
	# Rename the fixture's native suite to qualify it for Android.
	m.by_name[c"tests_android"] = m.by_name[c"tests_darwin"]
	manifest_host_prepare_android(m, 1)
	json_value* cmd = bh_command(m, c"wtest")
	assert_strings_equal(c"bin/wv2_android", json_array_get(cmd, 0).string_value)
	assert_strings_equal(c"arm64_android", json_array_get(cmd, 1).string_value)
	assert_strings_equal(c"win64", json_array_get(bh_command(m, c"cross"), 1).string_value)
	assert1(jfield_string(m.by_name[c"linux_test"], c"host_unavailable") != 0)
	assert1(jfield_string(m.by_name[c"cross"], c"host_unavailable") == 0)
	assert_strings_equal(c"tests_android", json_array_get(jfield_array(m.by_name[c"tests"], c"deps"), 0).string_value)
	assert_strings_equal(c"bin/wv2_android", json_array_get(jfield_array(m.by_name[c"wv2"], c"inputs"), 0).string_value)
	json_free(m.root)


void test_android_custom_manifest_and_selector():
	manifest* m = bh_manifest()
	manifest_host_prepare_android(m, 0)
	json_value* cmd = bh_command(m, c"wtest")
	assert_strings_equal(c"bin/wv2_android", json_array_get(cmd, 0).string_value)
	assert_strings_equal(c"tools/test_map.w", json_array_get(cmd, 1).string_value)
	assert_equal(4, json_array_length(cmd))
	assert_equal(1, manifest_host_selector(c"arm64_android"))
	assert_equal(0, json_object_has(m.by_name[c"tests"], c"host_skipped"))
	json_free(m.root)


# wbuild: target=android_build_host_test tag=tests_android dep=wv2
# wbuild: step="bin/wv2_android arm64_android tests/build_host_test.w -o bin/build_host_test_android"
# wbuild: step="bin/build_host_test_android"


void test_android_build_verify_aliases():
	manifest* m = manifest_parse(c"{\"targets\":[{\"name\":\"build\",\"steps\":[{\"cmd\":[\"./w\",\"w.w\"]}]},{\"name\":\"verify\",\"deps\":[\"build\"]},{\"name\":\"build_android\"},{\"name\":\"verify_android\",\"deps\":[\"build_android\"]},{\"name\":\"tests_android\",\"deps\":[\"verify_android\"]}]}", c"Android aliases", 1)
	assert1(m != 0)
	manifest_host_prepare_android(m, 1)
	assert_equal(0, json_array_length(jfield_array(m.by_name[c"build"], c"steps")))
	assert_strings_equal(c"build_android", json_array_get(jfield_array(m.by_name[c"build"], c"deps"), 0).string_value)
	assert_strings_equal(c"verify_android", json_array_get(jfield_array(m.by_name[c"verify"], c"deps"), 0).string_value)
	assert1(jfield_string(m.by_name[c"build"], c"host_unavailable") == 0)
	assert1(jfield_string(m.by_name[c"verify"], c"host_unavailable") == 0)
	json_free(m.root)


# wbuild: target=android_bootstrap_test tag=tests
# wbuild: step="python3 tests/android_bootstrap_test.py"


void test_android_native_targets_require_device():
	manifest* m = manifest_parse(c"{\"targets\":[{\"name\":\"native\",\"steps\":[{\"cmd\":[\"bin/wv2_android\",\"arm64_android\",\"w.w\"]}]},{\"name\":\"tests_android\",\"deps\":[\"native\"]},{\"name\":\"cross\",\"steps\":[{\"cmd\":[\"bin/wv2\",\"arm64_android\",\"w.w\"]}]}]}", c"Android device gate", 1)
	assert1(m != 0)
	manifest_host_require_android(m)
	assert1(jfield_string(m.by_name[c"native"], c"host_unavailable") != 0)
	assert1(jfield_string(m.by_name[c"tests_android"], c"host_unavailable") != 0)
	assert1(jfield_string(m.by_name[c"cross"], c"host_unavailable") == 0)
	json_free(m.root)
