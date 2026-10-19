# wbuild: binary=wvm_image arch=x64
# Deterministic newc initramfs assembly from a SHA256-pinned tar archive.
# No host extraction or downloads. All validation precedes atomic publication.
import tools.host_tools
import libs.standard.cli.argparse
import libs.standard.archive.tar
import libs.standard.compression.bzip2
import libs.standard.compression.xz

char* wi_name(char* name):
	ht_require(name[0] != '/', c"unsafe archive path: absolute path")
	string_builder* out = string_new()
	for char* part in ht_split(name, '/'):
		ht_require(strcmp(part, c"..") != 0, c"unsafe archive path: parent traversal")
		if (part[0] == 0 || strcmp(part, c".") == 0): continue
		if (out.length): string_append_char(out, '/')
		string_append(out, part)
	ht_require(out.length <= 4095, c"archive path too long")
	return out.data

void wi_entry(string_builder* out, int inode, char* name, int mode, char* data, int length, int major = 0, int minor = 0):
	int[13] fields
	for i in range(13): fields[i] = 0
	fields[0] = inode
	fields[1] = mode
	fields[4] = 1
	fields[6] = length
	fields[9] = major
	fields[10] = minor
	fields[11] = strlen(name) + 1
	string_append(out, c"070701")
	for i in range(13):
		char* digits = hex(fields[i])
		string_append(out, digits + 2)
		free(digits)
	string_append_bytes(out, name, strlen(name) + 1)
	while (out.length % 4): string_append_char(out, 0)
	string_append_bytes(out, data, length)
	while (out.length % 4): string_append_char(out, 0)

json_value* wi_build(char* rootfs, char* pin, char* init, char* output):
	int max_bytes = 1024 * 1024 * 1024 * 2
	string_builder* archive = ht_read(rootfs)
	char* digest = ht_digest(archive.data, archive.length)
	char* expected = strclone(pin)
	for i in range(strlen(expected)):
		if (expected[i] >= 'A' && expected[i] <= 'F'): expected[i] = expected[i] + 32
	ht_require(strcmp(digest, expected) == 0, c"rootfs SHA256 mismatch")
	char* bytes = archive.data
	int length = archive.length
	# tar_reader handles uncompressed and gzip; retain tarfile's bz2/xz inputs.
	if (length >= 3 && bytes_equal(bytes, 3, c"BZh", 3)):
		wresult[bzip2_result*]* decoded = bzip2_decompress(bytes, length, max_bytes + 256 * 1024 * 1024)
		ht_require(!result_is_error[bzip2_result*](decoded), c"invalid bzip2 archive")
		bzip2_result* contents = result_value[bzip2_result*](decoded)
		bytes = contents.data
		length = contents.length
	else if (length >= 6 && bytes_equal(bytes, 6, c"\xfd7zXZ\x00", 6)):
		int error = 0
		bytes = xz_decompress(bytes, length, max_bytes + 256 * 1024 * 1024, &length, &error)
		ht_require(bytes != 0, xz_error_string(error))
	tar_reader* reader = tar_reader_new(bytes, length)
	map[char*, tar_entry*] entries = new map[char*, tar_entry*]
	int total = 0
	while (1):
		tar_entry* entry = tar_next(reader)
		if (entry == 0): break
		char* name = wi_name(entry.name)
		if (name[0] == 0):
			ht_require(entry.kind == TAR_KIND_DIR, c"root entry must be a directory")
			continue
		ht_require(strcmp(name, c"TRAILER!!!") != 0 && !starts_with(name, c"init/") && !starts_with(name, c"dev/console/"), c"reserved image path")
		ht_require(!(name in entries), c"duplicate archive path")
		ht_require(entry.kind != TAR_KIND_OTHER, c"unsupported archive entry")
		ht_require(entry.size >= 0 && entry.size <= max_bytes - total && entries.length < 200000, c"rootfs exceeds image limits")
		total = total + entry.size
		entries[name] = entry
	ht_require(tar_reader_error(reader) == 0, tar_error_string(tar_reader_error(reader)))
	list[char*] names = entries.keys()
	for char* name in names:
		char* parent = path_dirname(name)
		while (parent[0] != 0 && strcmp(parent, c".") != 0):
			if (parent in entries): ht_require(entries[parent].kind == TAR_KIND_DIR, c"non-directory ancestor")
			else:
				entries[parent] = tar_entry_new(parent, TAR_KIND_DIR)
				ht_require(entries.length <= 200000, c"expanded entry count exceeds image limit")
			parent = path_dirname(parent)
	for char* name in ht_command(c"dev proc sys tmp workspace"):
		if (name in entries): ht_require(entries[name].kind == TAR_KIND_DIR, c"required mountpoint is not a directory")
		entries[name] = tar_entry_new(name, TAR_KIND_DIR)
		if (strcmp(name, c"tmp") == 0): entries[name].mode = 511
	ht_require(entries.length <= 200000, c"expanded entry count exceeds image limit")
	entries.remove(c"init")
	entries.remove(c"dev/console")
	names = entries.keys()
	ht_sort(names)
	string_builder* out = string_new()
	int inode = 1
	total = 0
	for char* name in names:
		tar_entry* entry = entries[name]
		int mode = entry.mode & 511
		char* content = c""
		int size = 0
		if (entry.kind == TAR_KIND_DIR):
			mode = mode | 16384
			if (strcmp(name, c"tmp") == 0): mode = mode | 512
		else if (entry.kind == TAR_KIND_SYMLINK):
			content = entry.linkname
			size = strlen(content)
			ht_require(size <= 4095, c"invalid symlink target")
			mode = mode | 40960
		else:
			if (entry.kind == TAR_KIND_HARDLINK):
				char* target = wi_name(entry.linkname)
				ht_require(target in entries, c"hardlink must name a regular file")
				entry = entries[target]
				ht_require(entry.kind == TAR_KIND_FILE, c"hardlink must name a regular file")
			content = entry.data
			size = entry.size
			mode = mode | 32768
		ht_require(size <= max_bytes - total, c"expanded image exceeds limit")
		total = total + size
		wi_entry(out, inode, name, mode, content, size)
		inode = inode + 1
	string_builder* initial = ht_read(init)
	ht_require(initial.length >= 20 && bytes_equal(initial.data, 6, c"\x7fELF\x02\x01", 6) && ht_uint(initial, 18, 2) == 62, c"init must be a Linux x64 ELF")
	ht_require(initial.length <= 64 * 1024 * 1024, c"init exceeds size limit")
	wi_entry(out, inode, c"init", 32768 | 493, initial.data, initial.length)
	wi_entry(out, inode + 1, c"dev/console", 8192 | 384, c"", 0, 5, 1)
	wi_entry(out, inode + 2, c"TRAILER!!!", 0, c"", 0)
	while (out.length % 512): string_append_char(out, 0)
	char* temporary = 0
	int fd = tempfile_mkstemp_in(path_dirname(output), c".wvm-image-", c"", &temporary)
	ht_require(fd >= 0, c"cannot create temporary image")
	io_result written
	int status = io_write_all(fd, out.data, out.length, &written)
	int closed = close(fd)
	if (status != IO_OK || closed != 0):
		unlink(temporary)
		ht_require(0, c"cannot write image")
	if (rename(temporary, output) != 0):
		unlink(temporary)
		ht_require(0, c"cannot publish image")
	json_value* manifest = json_object()
	json_object_set(manifest, c"entries", json_int(entries.length + 2))
	json_object_set(manifest, c"format", json_int(1))
	json_object_set(manifest, c"image_sha256", json_string(ht_digest(out.data, out.length)))
	json_object_set(manifest, c"init_sha256", json_string(ht_digest(initial.data, initial.length)))
	json_object_set(manifest, c"rootfs_sha256", json_string(expected))
	return manifest

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"wvm_image")
	argparse_arg_required(argparse_add_option(parser, c"--rootfs", c"TAR", c"pinned root filesystem archive"))
	argparse_arg_required(argparse_add_option(parser, c"--sha256", c"HASH", c"rootfs SHA256"))
	argparse_arg_required(argparse_add_option(parser, c"--output", c"CPIO", c"output initramfs"))
	argparse_arg_default(argparse_add_option(parser, c"--init", c"ELF", c"Linux x64 init"), c"bin/wvm_init")
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	char* output = argparse_get(args, c"output")
	json_value* manifest = wi_build(argparse_get(args, c"rootfs"), argparse_get(args, c"sha256"), argparse_get(args, c"init"), output)
	char* encoded = strjoin(json_stringify(manifest), c"\n")
	ht_write(strjoin(output, c".json"), encoded, strlen(encoded))
	print(encoded)
	return 0
