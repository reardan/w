# Darwin ready-template backing. The trusted owner finalizes an exclusive
# file in a private directory, reopens read-only, unlinks and closes every
# writable handle before publishing. This is lifecycle immutability, NOT
# Linux kernel seals or protection against a malicious host owner.
#
# Private clones each own a duplicate read-only fd. Reset replaces the
# complete private mapping: callers MUST detach/quiesce Hypervisor first.
# Linux memfd/mmap_fd/madvise semantics deliberately remain untouched.
import lib.lib
import lib.mem
import structures.string

c_lib "/usr/lib/libSystem.B.dylib"
extern char* mkdtemp(char* pattern)
extern int darwin_snapshot_getpagesize_raw() = "getpagesize"
extern int pread(int fd, char* data, int count, int offset)
extern int darwin_snapshot_ftruncate_raw(int fd, int length) = "ftruncate"

# C int results occupy w0; upper x0 is unspecified by the AArch64 ABI.
int darwin_snapshot_c_int(int value):
	return (value & ((1 << 31) - 1)) - (value & (1 << 31))

int getpagesize():
	return darwin_snapshot_c_int(darwin_snapshot_getpagesize_raw())

int ftruncate(int fd, int length):
	return darwin_snapshot_c_int(darwin_snapshot_ftruncate_raw(fd, length))


const int DARWIN_BACKING_MAGIC = 0x57564d44
const int DARWIN_BACKING_VERSION = 1
const int DARWIN_BACKING_MAX_RAM = 1073741824
const int DARWIN_BACKING_MAX_METADATA = 8388608

struct darwin_backing:
	int fd
	int length
	int granule
	int metadata_length

struct darwin_clone:
	int fd
	char* address
	char* ram
	int length
	int granule
	char* metadata
	int metadata_length
	int ram_offset
	int mapping_length


int darwin_backing_geometry(int length, int metadata_length, int page):
	if (page != 4096 && page != 16384): return 0
	if (length <= 0 || length > DARWIN_BACKING_MAX_RAM || length % page != 0): return 0
	return metadata_length >= 0 && metadata_length <= DARWIN_BACKING_MAX_METADATA


int darwin_backing_map(int fd, int length, int writable_shared):
	int flags = 2
	if (writable_shared): flags = 1
	return syscall7(197, 0, length, 3, flags, fd, 0)


int darwin_backing_map_failed(int address):
	return address < 0 && address > -4096


void darwin_backing_free(darwin_backing* backing):
	if (backing == 0): return
	close(backing.fd)
	free(backing)


# Header words: magic,version,arch,ABI,host page,RAM bytes,metadata bytes,
# RAM offset,total bytes,guest page,ready state. Reserved words are zero.
# Metadata is an opaque caller-versioned record at the first host page.
darwin_backing* darwin_backing_create(char* ram, int length, char* metadata, int metadata_length):
	int page = getpagesize()
	if (darwin_backing_geometry(length, metadata_length, page) == 0 || ram == 0): return 0
	if (metadata_length != 0 && metadata == 0): return 0
	int ram_offset = page + ((metadata_length + page - 1) / page) * page
	int total = ram_offset + length
	char[64] directory
	strcpy(directory, c"/tmp/wvm-template.XXXXXX")
	if (mkdtemp(directory) == 0): return 0
	string_builder* path = string_from(directory)
	string_append(path, c"/backing")
	# O_RDWR|O_CREAT|O_EXCL, mode 0600. The private directory is 0700.
	int writable = open(path.data, 2 | 64 | 128, 384)
	int readonly = -1
	int address = -1
	int success = 0
	if (writable >= 0 && ftruncate(writable, total) == 0):
		address = darwin_backing_map(writable, total, 1)
		if (darwin_backing_map_failed(address) == 0):
			int* header = cast(int*, address)
			header[0] = DARWIN_BACKING_MAGIC
			header[1] = DARWIN_BACKING_VERSION
			header[2] = 183
			header[3] = 1
			header[4] = page
			header[5] = length
			header[6] = metadata_length
			header[7] = ram_offset
			header[8] = total
			header[9] = 4096
			header[10] = 1
			if (metadata_length != 0): mem_copy[char](cast(char*, address) + page, metadata, metadata_length)
			# Preserve sparse zero pages. Capture scans RAM once; clone and
			# reset never copy it. Framework registration costs are separate.
			for index in range(length / page):
				char* source = ram + index * page
				int nonzero = 0
				int offset = 0
				while (offset < page && nonzero == 0):
					if (load_int64(source + offset) != 0): nonzero = 1
					offset = offset + 8
				if (nonzero): mem_copy[char](cast(char*, address) + ram_offset + index * page, source, page)
			# The shared writable view is removed before reopening/publishing.
			if (munmap(address, total) == 0):
				address = -1
				readonly = open(path.data, 524288, 0)
				if (readonly >= 0): success = 1
	if (address != -1 && darwin_backing_map_failed(address) == 0): munmap(address, total)
	if (unlink(path.data) < 0): success = 0
	if (writable >= 0): close(writable)
	if (rmdir(directory) < 0): success = 0
	string_free(path)
	if (success == 0):
		if (readonly >= 0): close(readonly)
		return 0
	darwin_backing* backing = new darwin_backing()
	backing.fd = readonly
	backing.length = length
	backing.granule = page
	backing.metadata_length = metadata_length
	return backing


void darwin_clone_free(darwin_clone* clone):
	if (clone == 0): return
	if (clone.address != 0): munmap(cast(int, clone.address), clone.mapping_length)
	close(clone.fd)
	free(clone)


# Input fd remains caller-owned. Only exact-size, read-only ready ARM64
# records are accepted. No descriptor number is supplied by the guest.
darwin_clone* darwin_clone_from_fd(int fd):
	int flags = sys_fcntl(fd, 3, 0)
	if (flags < 0 || (flags & 3) != 0): return 0
	int[16] header
	if (pread(fd, cast(char*, &header[0]), 128, 0) != 128): return 0
	if (header[0] != DARWIN_BACKING_MAGIC || header[1] != DARWIN_BACKING_VERSION): return 0
	if (header[2] != 183 || header[3] != 1 || header[9] != 4096 || header[10] != 1): return 0
	int page = getpagesize()
	if (header[4] != page || darwin_backing_geometry(header[5], header[6], page) == 0): return 0
	int offset = page + ((header[6] + page - 1) / page) * page
	if (header[7] != offset || header[8] != offset + header[5]): return 0
	for index in range(11, 16):
		if (header[index] != 0): return 0
	if (seek(fd, 0, 2) != header[8]): return 0
	int owned_fd = sys_fcntl(fd, 0, 0)
	if (owned_fd < 0): return 0
	if (sys_fcntl(owned_fd, 2, 1) < 0):
		close(owned_fd)
		return 0
	int address = darwin_backing_map(owned_fd, header[8], 0)
	if (darwin_backing_map_failed(address)):
		close(owned_fd)
		return 0
	darwin_clone* clone = new darwin_clone()
	clone.fd = owned_fd
	clone.address = cast(char*, address)
	clone.ram = clone.address + offset
	clone.length = header[5]
	clone.granule = page
	clone.metadata = clone.address + page
	clone.metadata_length = header[6]
	clone.ram_offset = offset
	clone.mapping_length = header[8]
	return clone


darwin_clone* darwin_backing_clone(darwin_backing* backing):
	if (backing == 0): return 0
	return darwin_clone_from_fd(backing.fd)


# Mapping failure preserves the old clone. Caller must have destroyed or
# detached its VM before calling, including before replacing RAM pointers.
int darwin_clone_reset(darwin_clone* clone):
	if (clone == 0 || clone.fd < 0 || clone.address == 0): return 0
	int address = darwin_backing_map(clone.fd, clone.mapping_length, 0)
	if (darwin_backing_map_failed(address)): return 0
	if (munmap(cast(int, clone.address), clone.mapping_length) < 0):
		munmap(address, clone.mapping_length)
		return 0
	clone.address = cast(char*, address)
	clone.ram = clone.address + clone.ram_offset
	clone.metadata = clone.address + clone.granule
	return 1
