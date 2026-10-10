# Kernel page size, without depending on malloc or lib.lib (_main).
# Linux supplies AT_PAGESZ in auxv after the initial envp vector. Reading
# /proc/self/auxv also supports programs that provide their own _main.
# An mmap probe is the fallback when procfs is unavailable. Every probe
# stays inside one owned mapping; mprotect rejects unaligned addresses.
import lib.linux


int runtime_page_size_cached


int runtime_page_size_valid(int size):
	return (size >= 4096) && (size <= 65536) && ((size & (size - 1)) == 0)


int runtime_page_size_from_auxv(int* entries):
	int i = 0
	while (entries[i] != 0):
		if (entries[i] == 6):
			if (runtime_page_size_valid(entries[i + 1])): return entries[i + 1]
			return 0
		i = i + 2
	return 0


# Only Android startup calls this: Darwin appends an apple vector here,
# and Windows/Wasm do not provide the Linux initial-stack contract.
void runtime_page_size_init(int* envp):
	if (os_android() == 0): return
	int i = 0
	while (envp[i] != 0): i = i + 1
	runtime_page_size_cached = runtime_page_size_from_auxv(envp + (i + 1) * __word_size__)


int runtime_page_size():
	if (runtime_page_size_cached != 0): return runtime_page_size_cached
	# Retain the established defaults outside Linux AArch64/Android.
	# Darwin also uses AArch64 but lacks procfs; probing works there.
	if (__target_isa__ != 1): return 4096
	int fd = open(c"/proc/self/auxv", 0, 0)
	if (fd >= 0):
		int[2] entry
		while (read(fd, cast(char*, &entry[0]), 2 * __word_size__) == 2 * __word_size__):
			if (entry[0] == 0): break
			if ((entry[0] == 6) && runtime_page_size_valid(entry[1])):
				runtime_page_size_cached = entry[1]
				break
		close(fd)
	if (runtime_page_size_cached != 0): return runtime_page_size_cached
	int region = mmap(0, 131072, 3, 34)
	if ((region < 0) && (region > -4096)): return 65536
	int size = 4096
	while (size < 65536):
		if (mprotect(region + size, size, 3) == 0): break
		size = size * 2
	munmap(region, 131072)
	runtime_page_size_cached = size
	return size
