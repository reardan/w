# wbuild: binary=android_check_elf
# Validate Android ELF headers without an NDK installation.
import tools.host_tools

void android_check_elf(char* path):
	string_builder* data = ht_read(path)
	ht_require(data.length >= 64 && bytes_equal(data.data, 7, c"\x7fELF\x02\x01\x01", 7), c"expected little-endian ELF64")
	ht_require(ht_uint(data, 16, 2) == 3 && ht_uint(data, 18, 2) == 183, c"expected ARM64 ET_DYN")
	int phoff = ht_uint(data, 32, 8)
	int phnum = ht_uint(data, 56, 2)
	ht_require(ht_uint(data, 54, 2) == 56, c"invalid program header size")
	ht_require(phoff <= data.length && phnum <= (data.length - phoff) / 56, c"truncated program headers")
	int loads = 0
	for i in range(phnum):
		int pos = phoff + i * 56
		int kind = ht_uint(data, pos, 4)
		int flags = ht_uint(data, pos + 4, 4)
		int offset = ht_uint(data, pos + 8, 8)
		int addr = ht_uint(data, pos + 16, 8)
		int size = ht_uint(data, pos + 32, 8)
		int memsize = ht_uint(data, pos + 40, 8)
		int alignment = ht_uint(data, pos + 48, 8)
		ht_require(offset <= data.length && size <= data.length - offset, c"segment extends beyond file")
		if (kind == 1):
			loads = loads + 1
			ht_require(alignment >= 16384 && (alignment & (alignment - 1)) == 0, c"LOAD alignment below 16 KB")
			ht_require((addr - offset) % 16384 == 0, c"LOAD not congruent on 16 KB pages")
			ht_require((flags & 3) != 3, c"writable executable LOAD")
			ht_require(memsize >= size, c"LOAD memsz below filesz")
		if (kind == 0x6474e551): ht_require((flags & 1) == 0, c"executable stack")
		if (kind == 2):
			int p = offset
			while (p < offset + size):
				ht_require(offset + size - p >= 16, c"truncated dynamic entry")
				int tag = ht_uint(data, p, 8)
				int value = ht_uint(data, p + 8, 8)
				ht_require(tag != 22 && !(tag == 30 && (value & 4)), c"text relocations")
				if (tag == 0): break
				p = p + 16
	ht_require(loads >= 2, c"expected separate code/data LOAD segments")
	println(strjoin(path, c": ARM64 shared object, 16 KB alignment, W^X: OK"))
	string_free(data)

int main(int argc, int argv):
	args_init(argc, argv)
	ht_require(argc >= 2, c"usage: android_check_elf library.so [...]")
	for i in range(1, argc): android_check_elf(args_get(i))
	return 0
