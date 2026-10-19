# wbuild: binary=ios_check_macho arch=x64
import tools.host_tools

int main(int argc, int argv):
	args_init(argc, argv)
	ht_require(argc == 3, c"usage: ios_check_macho executable device|simulator")
	string_builder* data = ht_read(args_get(1))
	int expected = 0
	if (strcmp(args_get(2), c"device") == 0): expected = 2
	if (strcmp(args_get(2), c"simulator") == 0): expected = 7
	ht_require(expected != 0, c"unknown iOS platform")
	ht_require(ht_uint(data, 0, 4) == (0xfeed * 65536 + 0xfacf) && ht_uint(data, 4, 4) == 0x0100000c, c"expected ARM64 Mach-O")
	ht_require(ht_uint(data, 12, 4) == 2 && (ht_uint(data, 24, 4) & 0x200000), c"expected PIE executable")
	int count = ht_uint(data, 16, 4)
	int size = ht_uint(data, 20, 4)
	ht_require(data.length >= 32 && size <= data.length - 32 && count <= size / 8, c"truncated Mach-O commands")
	int offset = 32
	int platforms = 0
	int entries = 0
	int imports = 0
	int signatures = 0
	for i in range(count):
		int cmd = ht_uint(data, offset, 4)
		int length = ht_uint(data, offset + 4, 4)
		ht_require(length >= 8 && length % 8 == 0 && length <= 32 + size - offset, c"invalid Mach-O command size")
		if (cmd == 0x32):
			ht_require(length >= 24 && ht_uint(data, offset + 8, 4) == expected && ht_uint(data, offset + 12, 4) == (17 << 16) && ht_uint(data, offset + 16, 4) == (17 << 16), c"unexpected iOS deployment platform")
			platforms = platforms + 1
		else if (cmd == (0x8000 * 65536 + 0x28)):
			ht_require(length >= 24 && ht_uint(data, offset + 8, 8) < data.length, c"invalid entry point")
			entries = entries + 1
		else if (cmd == 12):
			ht_require(length >= 24, c"truncated dylib command")
			int name_offset = ht_uint(data, offset + 8, 4)
			ht_require(name_offset >= 24 && name_offset < length, c"invalid dylib name offset")
			char* name = path_clone_range(data.data + offset + name_offset, length - name_offset)
			if (strcmp(name, c"@executable_path/Frameworks/WIOS.framework/WIOS") == 0): imports = imports + 1
		else if (cmd == 0x19):
			ht_require(length >= 72, c"truncated segment command")
			int maxprot = ht_uint(data, offset + 56, 4)
			int initprot = ht_uint(data, offset + 60, 4)
			ht_require(!((initprot & 2) && (initprot & 4)) && (initprot & maxprot) == initprot, c"invalid segment protection")
		else if (cmd == 0x1d):
			ht_require(length >= 16, c"truncated signature command")
			int start = ht_uint(data, offset + 8, 4)
			int bytes = ht_uint(data, offset + 12, 4)
			ht_require(start <= data.length && bytes <= data.length - start, c"signature extends beyond file")
			signatures = signatures + 1
		offset = offset + length
	ht_require(offset == 32 + size && platforms == 1 && entries == 1 && imports > 0 && signatures > 0, c"missing or duplicate required Mach-O commands")
	println(strjoin(strjoin(c"iOS Mach-O valid: ", args_get(2)), c", ARM64, iOS 17+, PIE, W^X, UIKit bridge"))
	return 0
