# wbuild: tool=tools/wvm_image.w
import tools.host_tools
import libs.standard.archive.tar

process_result* wit_build(char* directory, char* pin, char* output):
	list[char*] command = ht_command(c"bin/wvm_image --rootfs")
	command.push(path_join(directory, c"rootfs.tar"))
	command.push(c"--sha256")
	command.push(pin)
	command.push(c"--init")
	command.push(path_join(directory, c"init"))
	command.push(c"--output")
	command.push(path_join(directory, output))
	return ht_run(command, 0, 0, 30000)

char* wit_archive(char* directory, int scenario):
	tar_writer* writer = tar_writer_new()
	if (scenario == 0):
		ht_require(tar_add_file(writer, c"bin/tool", c"hello", 5, 2541, 1234567) == 0, c"fixture creation failed")
		ht_require(tar_add_symlink(writer, c"bin/sh", c"tool", 1234567) == 0, c"fixture creation failed")
	if (scenario == 1): tar_add_file(writer, c"../escape", c"x", 1, 2541, 1234567)
	if (scenario == 2): tar_add_file(writer, c"/escape", c"x", 1, 2541, 1234567)
	if (scenario == 3):
		tar_add_symlink(writer, c"bin", c"/host", 0)
		tar_add_file(writer, c"bin/tool", c"x", 1, 2541, 0)
	if (scenario == 4): tar_add_symlink(writer, c"proc", c"/host", 0)
	if (scenario == 5):
		tar_add_file(writer, c"same", c"a", 1, 2541, 0)
		tar_add_file(writer, c"same", c"b", 1, 2541, 0)
	if (scenario == 6): tar_add_file(writer, c"TRAILER!!!", c"x", 1, 2541, 0)
	if (scenario == 7): tar_add_file(writer, c"init/evil", c"x", 1, 2541, 0)
	if (scenario == 8): tar_add_file(writer, c"dev/console/evil", c"x", 1, 2541, 0)
	int length = 0
	char* contents = tar_writer_finish(writer, &length)
	ht_write(path_join(directory, c"rootfs.tar"), contents, length)
	return ht_digest(contents, length)

int main():
	char* directory = ht_temp()
	char[64] initial
	for i in range(64): initial[i] = 0
	for i in range(6): initial[i] = c"\x7fELF\x02\x01"[i]
	initial[18] = 62
	ht_write(path_join(directory, c"init"), &initial[0], 64)
	char* digest = wit_archive(directory, 0)
	process_result* first = wit_build(directory, digest, c"a.cpio")
	process_result* second = wit_build(directory, digest, c"b.cpio")
	ht_success(first)
	ht_success(second)
	string_builder* a = ht_read(path_join(directory, c"a.cpio"))
	string_builder* b = ht_read(path_join(directory, c"b.cpio"))
	ht_require(bytes_equal(a.data, a.length, b.data, b.length) && strcmp(first.stdout_text, second.stdout_text) == 0, c"image is not reproducible")
	json_value* report = json_parse(first.stdout_text)
	ht_require(strcmp(ht_text(report, c"image_sha256"), ht_digest(a.data, a.length)) == 0, c"image digest mismatch")
	int console = 0
	int pos = 0
	while (pos + 110 <= a.length && bytes_equal(a.data + pos, 6, c"070701", 6)):
		int mode = from_hex(path_clone_range(a.data + pos + 14, 8))
		int size = from_hex(path_clone_range(a.data + pos + 54, 8))
		int name_size = from_hex(path_clone_range(a.data + pos + 94, 8))
		char* name = a.data + pos + 110
		ht_require((mode & 3072) == 0, c"setuid/setgid permissions leaked into image")
		if (strcmp(name, c"dev/console") == 0): console = 1
		if (strcmp(name, c"tmp") == 0): ht_require(mode == (16384 | 1023), c"tmp lost sticky/world-write permissions")
		pos = (pos + 110 + name_size + 3) / 4 * 4
		pos = (pos + size + 3) / 4 * 4
	ht_require(console, c"missing early console")
	process_result* mismatch = wit_build(directory, c"0000000000000000000000000000000000000000000000000000000000000000", c"a.cpio")
	ht_require(mismatch.status != 0 && ht_contains(mismatch.stderr_text, c"SHA256"), c"unpinned archive accepted")
	string_builder* unchanged = ht_read(path_join(directory, c"a.cpio"))
	ht_require(bytes_equal(a.data, a.length, unchanged.data, unchanged.length), c"failed image overwrote previous output")
	for scenario in range(1, 9):
		digest = wit_archive(directory, scenario)
		ht_require(wit_build(directory, digest, c"bad.cpio").status != 0, strjoin(c"unsafe archive accepted: ", itoa(scenario)))
		ht_require(!path_exists(path_join(directory, c"bad.cpio")), c"failed image created output")
	digest = wit_archive(directory, 0)
	ht_write(path_join(directory, c"init"), c"not an ELF", 10)
	ht_write(path_join(directory, c"image"), c"previous", 8)
	process_result* invalid = wit_build(directory, digest, c"image")
	ht_require(invalid.status != 0 && ht_contains(invalid.stderr_text, c"ELF"), c"invalid init accepted")
	ht_equal_file(path_join(directory, c"image"), c"previous")
	ht_cleanup()
	println(c"VM image assembly checks OK")
	return 0
