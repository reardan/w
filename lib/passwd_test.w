# wbuild: x64
import lib.testing
import lib.passwd
import lib.path
import lib.file


char* pw_work_root


char* pw_work():
	if (pw_work_root == 0):
		pw_work_root = c"bin/passwd_test_work"
		mkdir(c"bin", 493)
		rmdir(pw_work_root)
		assert_equal(0, mkdir(pw_work_root, 493))
	return pw_work_root


char* pw_join(char* name):
	return path_join(pw_work(), name)


void test_passwd_uid_and_name_roundtrip():
	char* path = pw_join(c"passwd")
	assert_equal(1, file_write_text(path, c"root:x:0:0:root:/root:/bin/bash\x0aalice:x:1000:1000:Alice:/home/alice:/bin/sh\x0a# comment\x0abob:x:1001:1001:Bob:/home/bob:/bin/sh\x0a"))
	char* root = passwd_uid_name_at(path, 0)
	assert1(root != 0)
	assert_strings_equal(c"root", root)
	free(root)
	char* alice = passwd_uid_name_at(path, 1000)
	assert1(alice != 0)
	assert_strings_equal(c"alice", alice)
	free(alice)
	assert1(passwd_uid_name_at(path, 9999) == 0)
	assert_equal(0, passwd_name_uid_at(path, c"root"))
	assert_equal(1000, passwd_name_uid_at(path, c"alice"))
	assert_equal(1001, passwd_name_uid_at(path, c"bob"))
	assert_equal(0 - 1, passwd_name_uid_at(path, c"missing"))
	unlink(path)


void test_group_gid_and_name_roundtrip():
	char* path = pw_join(c"group")
	assert_equal(1, file_write_text(path, c"root:x:0:\x0asudo:x:27:alice,bob\x0ausers:x:100:\x0a"))
	char* sudo = passwd_gid_name_at(path, 27)
	assert1(sudo != 0)
	assert_strings_equal(c"sudo", sudo)
	free(sudo)
	assert_equal(27, passwd_name_gid_at(path, c"sudo"))
	assert_equal(0, passwd_name_gid_at(path, c"root"))
	assert_equal(0 - 1, passwd_name_gid_at(path, c"nogroup"))
	unlink(path)


void test_live_passwd_root_uid():
	# Sanity check against the real database when present.
	char* root = passwd_uid_name(0)
	if (root != 0):
		assert_strings_equal(c"root", root)
		assert_equal(0, passwd_name_uid(c"root"))
		free(root)
