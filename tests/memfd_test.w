# wbuild: x64 arch=arm64
# Linux-only M0 gate (issue #519): no KVM or external runtime needed.
import lib.testing
import lib.memfd


# 64 KiB is aligned on Linux x86/x64 and all supported ARM64 page sizes.
const int MEMFD_TEST_PAGE = 65536


char* memfd_test_map(int fd, int length, int flags, int offset):
	int addr = mmap_fd(0, length, PROT_READ | PROT_WRITE, flags, fd, offset)
	asserts(c"mapping succeeds (high x86 addresses are valid)", !(addr < 0 && addr > -4096))
	return cast(char*, addr)


void test_memfd_snapshot_clones():
	int size = MEMFD_TEST_PAGE * 2
	int fd = memfd_create(c"w-snapshot-test", MFD_CLOEXEC | MFD_ALLOW_SEALING)
	asserts(c"memfd_create", fd >= 0)
	assert_equal(1, sys_fcntl(fd, 1, 0) & 1) # F_GETFD / FD_CLOEXEC
	assert_equal(0, sys_fcntl(fd, F_GET_SEALS, 0))
	assert_equal(0, seek(fd, 0, 2)) # new memfd starts empty
	assert_equal(0, sys_ftruncate(fd, size))

	char* parent = memfd_test_map(fd, size, MAP_SHARED, 0)
	parent[0] = 17
	parent[MEMFD_TEST_PAGE] = 41
	parent[size - 1] = 93
	char* shared = memfd_test_map(fd, size, MAP_SHARED, 0)
	assert_equal(17, shared[0])
	shared[1] = 29
	assert_equal(29, parent[1])

	# Writable shared mappings must be gone before WRITE sealing.
	assert_equal(-16, sys_fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE)) # EBUSY
	assert_equal(0, munmap(cast(int, shared), size))
	assert_equal(0, munmap(cast(int, parent), size))
	int seals = F_SEAL_WRITE | F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL
	assert_equal(0, sys_fcntl(fd, F_ADD_SEALS, seals))
	assert_equal(seals, sys_fcntl(fd, F_GET_SEALS, 0))
	assert_equal(-1, write(fd, c"x", 1)) # EPERM: immutable data
	assert_equal(-1, sys_ftruncate(fd, size - MEMFD_TEST_PAGE))
	assert_equal(-1, sys_ftruncate(fd, size + MEMFD_TEST_PAGE))
	assert_equal(-1, sys_fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE))
	assert_equal(-1, mmap_fd(0, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0))

	char* first = memfd_test_map(fd, size, MAP_PRIVATE, 0)
	char* second = memfd_test_map(fd, size, MAP_PRIVATE, 0)
	assert_equal(17, first[0])
	assert_equal(29, first[1])
	assert_equal(41, second[MEMFD_TEST_PAGE])
	assert_equal(93, second[size - 1])
	first[0] = 99
	first[MEMFD_TEST_PAGE] = 77
	second[1] = 88
	assert_equal(17, second[0])
	assert_equal(41, second[MEMFD_TEST_PAGE])
	assert_equal(29, first[1])
	char[2] buffer
	assert_equal(0, seek(fd, 0, 0))
	assert_equal(2, read(fd, &buffer[0], 2))
	assert_equal(17, buffer[0])
	assert_equal(29, buffer[1])

	# A partial reset restores just the discarded range.
	assert_equal(0, madvise(cast(int, first), MEMFD_TEST_PAGE, MADV_DONTNEED))
	assert_equal(17, first[0])
	assert_equal(77, first[MEMFD_TEST_PAGE])
	assert_equal(88, second[1])
	assert_equal(0, madvise(cast(int, first), size, MADV_DONTNEED))
	assert_equal(41, first[MEMFD_TEST_PAGE])

	# Nonzero BYTE offsets catch passing bytes directly to i386 mmap2.
	char* tail = memfd_test_map(fd, MEMFD_TEST_PAGE, MAP_PRIVATE, MEMFD_TEST_PAGE)
	assert_equal(41, tail[0])
	assert_equal(93, tail[MEMFD_TEST_PAGE - 1])
	tail[0] = 3
	assert_equal(41, first[MEMFD_TEST_PAGE])
	assert_equal(0, madvise(cast(int, tail), MEMFD_TEST_PAGE, MADV_DONTNEED))
	assert_equal(41, tail[0])

	# The mapping holds a reference even after the fd is closed.
	assert_equal(0, close(fd))
	assert_equal(0, madvise(cast(int, second), size, MADV_DONTNEED))
	assert_equal(29, second[1])
	assert_equal(0, munmap(cast(int, tail), MEMFD_TEST_PAGE))
	assert_equal(0, munmap(cast(int, first), size))
	assert_equal(0, munmap(cast(int, second), size))


void test_memfd_errors():
	assert_equal(-22, memfd_create(c"w-invalid-flags", 32768))
	int fd = memfd_create(c"w-unsealable", 0)
	asserts(c"memfd without sealing", fd >= 0)
	assert_equal(F_SEAL_SEAL, sys_fcntl(fd, F_GET_SEALS, 0))
	assert_equal(-1, sys_fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE))
	assert_equal(0, sys_ftruncate(fd, MEMFD_TEST_PAGE))
	assert_equal(-22, mmap_fd(0, MEMFD_TEST_PAGE, PROT_READ, MAP_PRIVATE, fd, 1))
	assert_equal(-22, mmap_fd(0, MEMFD_TEST_PAGE, PROT_READ, MAP_PRIVATE, fd, -MEMFD_TEST_PAGE))
	assert_equal(-22, mmap_fd(0, 0, PROT_READ, MAP_PRIVATE, fd, 0))
	assert_equal(-9, mmap_fd(0, MEMFD_TEST_PAGE, PROT_READ, MAP_PRIVATE, -1, 0))
	char* p = memfd_test_map(fd, MEMFD_TEST_PAGE, MAP_PRIVATE, 0)
	assert_equal(-22, madvise(cast(int, p) + 1, MEMFD_TEST_PAGE - 1, MADV_DONTNEED))
	assert_equal(-22, madvise(cast(int, p), MEMFD_TEST_PAGE, -1))
	assert_equal(0, munmap(cast(int, p), MEMFD_TEST_PAGE))
	assert_equal(0, close(fd))


void test_memfd_anonymous_mmap_unchanged():
	int addr = mmap(0, MEMFD_TEST_PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS)
	asserts(c"anonymous mmap still works", !(addr < 0 && addr > -4096))
	char* p = cast(char*, addr)
	assert_equal(0, p[0])
	p[0] = 71
	assert_equal(0, madvise(addr, MEMFD_TEST_PAGE, MADV_DONTNEED))
	assert_equal(0, p[0])
	assert_equal(0, munmap(addr, MEMFD_TEST_PAGE))


void test_memfd_large_offset():
	if (__word_size__ == 4): return
	# Sparse backing beyond 4 GiB catches truncating a 64-bit byte offset.
	int offset = MEMFD_TEST_PAGE
	offset = offset * MEMFD_TEST_PAGE
	int fd = memfd_create(c"w-large-offset", MFD_CLOEXEC)
	asserts(c"large-offset memfd", fd >= 0)
	assert_equal(0, sys_ftruncate(fd, offset + MEMFD_TEST_PAGE))
	char* p = memfd_test_map(fd, MEMFD_TEST_PAGE, MAP_SHARED, offset)
	p[0] = 57
	assert_equal(offset, seek(fd, offset, 0))
	char[1] value
	assert_equal(1, read(fd, &value[0], 1))
	assert_equal(57, value[0])
	assert_equal(0, seek(fd, 0, 0))
	assert_equal(1, read(fd, &value[0], 1))
	assert_equal(0, value[0])
	assert_equal(0, munmap(cast(int, p), MEMFD_TEST_PAGE))
	assert_equal(0, close(fd))
