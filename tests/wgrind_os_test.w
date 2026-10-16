# wbuild: x64
import lib.assert
import libs.wgrind.os
import libs.wgrind.heap

int[8] os_vector


int os_reader(int opaque, int address, int size, int* out):
	if ((opaque != 7) || (size != __word_size__) || (address < 65536) || (address >= 65536 + (__word_size__ * 8))): return 0
	*out = os_vector[(address - 65536) / __word_size__]
	return 1


void io_boundaries():
	wg_context* c = wg_create(32, 32, 4)
	assert1(c != 0)
	wg_io storage
	wg_io* io = &storage
	io.pending = 0
	assert1(wg_allocate(c, 8192, 16, 0, 51))
	assert1(wg_io_pre(c, io, 1, 8192, 16, 60))
	assert1(wg_io_post(c, io, -4))
	wg_value value
	assert1(wg_load(c, 8192, 1, 61, &value))
	assert_equal(255, value.undefined)
	assert1(wg_io_pre(c, io, 1, 8192, 16, 62))
	assert1(wg_io_post(c, io, 3))
	assert1(wg_io_pre(c, io, 0, 8192, 3, 63))
	assert1(wg_io_post(c, io, 2))
	assert_equal(0, wg_io_pre(c, io, 0, 8192, 4, 64))
	assert_equal(WG_UNDEFINED, c.error)
	assert_equal(51, c.error_origin)
	assert_equal(8195, c.error_address)
	wg_clear_error(c)
	assert_equal(0, wg_io_pre(c, io, 1, 8192, 17, 65))
	assert_equal(WG_INVALID_WRITE, c.error)
	wg_clear_error(c)
	assert1(wg_io_pre(c, io, 1, 8192, 16, 66))
	assert_equal(0, wg_io_post(c, io, 17))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)


void real_kernel_io():
	wg_context* c = wg_create(8, 8, 2)
	assert1(c != 0)
	char[8] bytes
	int address = cast(int, &bytes[0])
	assert1(wg_allocate(c, address, 8, 0, 70))
	int[2] fds
	assert_equal(0, pipe(&fds[0]))
	int reader = load_int32(cast(char*, &fds[0]))
	int writer = load_int32(cast(char*, &fds[0]) + 4)
	assert_equal(3, write(writer, c"abc", 3))
	wg_io io
	io.pending = 0
	assert1(wg_io_pre(c, &io, 1, address, 8, 71))
	int count = read(reader, &bytes[0], 8)
	assert_equal(3, count)
	assert1(wg_io_post(c, &io, count))
	assert1(wg_kernel_read(c, address, 3, 72))
	wg_value value
	assert1(wg_load(c, address + 3, 1, 73, &value))
	assert_equal(255, value.undefined)
	assert_equal(70, value.origin)
	assert1(wg_io_pre(c, &io, 1, address, 8, 74))
	count = read(-1, &bytes[0], 8)
	assert1(count < 0)
	assert1(wg_io_post(c, &io, count))
	assert1(wg_load(c, address + 3, 1, 75, &value))
	assert_equal(255, value.undefined)
	assert_equal(0, close(reader))
	assert_equal(0, close(writer))
	wg_destroy(c)


void vector_boundaries():
	wg_context* c = wg_create(32, 32, 4)
	assert1(c != 0)
	wg_io storage
	wg_io* io = &storage
	io.pending = 0
	assert1(wg_mark(c, 65536, (__word_size__ * 8), 3, 0, 0))
	assert1(wg_allocate(c, 8192, 8, 0, 81))
	assert1(wg_allocate(c, 12288, 8, 0, 82))
	os_vector[0] = 8192
	os_vector[1] = 8
	os_vector[2] = 12288
	os_vector[3] = 8
	assert1(wg_io_vector_pre(c, io, 1, 65536, 2, __word_size__, &os_reader, 7, 83))
	# The post hook uses the entry snapshot, even if iov memory changed.
	os_vector[2] = 99999
	assert1(wg_io_post(c, io, 10))
	assert1(wg_kernel_read(c, 8192, 8, 84))
	assert1(wg_kernel_read(c, 12288, 2, 85))
	wg_value value
	assert1(wg_load(c, 12290, 1, 86, &value))
	assert_equal(255, value.undefined)
	assert_equal(82, value.origin)
	# An undefined vector descriptor fails before any output is marked.
	assert1(wg_mark(c, 65536, __word_size__, 3, 255, 87))
	assert_equal(0, wg_io_vector_pre(c, io, 1, 65536, 2, __word_size__, &os_reader, 7, 88))
	assert_equal(WG_UNDEFINED, c.error)
	wg_clear_error(c)
	assert1(wg_mark(c, 65536, (__word_size__ * 8), 3, 0, 0))
	os_vector[2] = 12288
	assert1(wg_io_vector_pre(c, io, 1, 65536, 2, __word_size__, &os_reader, 7, 89))
	assert1(wg_unmapping(c, 12288, 8, 0, 90))
	assert_equal(0, wg_io_post(c, io, 9))
	assert_equal(WG_INVALID_WRITE, c.error)
	wg_destroy(c)


void mapping_boundaries():
	wg_context* c = wg_create(32, 32, 4)
	assert1(c != 0)
	assert1(wg_mapping(c, 8192, 4096, 3, 0, 100))
	assert1(wg_mark(c, 8200, 1, 3, 0x80, 101))
	assert1(wg_protect(c, 8192, 4096, 0, 0, 102))
	assert_equal(1, c.page_count)
	assert_equal(0, wg_access(c, 8200, 1, WG_READ, 103))
	assert_equal(WG_INVALID_READ, c.error)
	wg_clear_error(c)
	assert1(wg_protect(c, 8192, 4096, 1, 0, 104))
	wg_value value
	assert1(wg_load(c, 8200, 1, 105, &value))
	assert_equal(0x80, value.undefined)
	assert_equal(101, value.origin)
	assert_equal(0, wg_access(c, 8200, 1, WG_WRITE, 106))
	wg_clear_error(c)
	assert1(wg_unmapping(c, 8192, 4096, -22, 107))
	assert_equal(1, c.page_count)
	assert1(wg_unmapping(c, 8192, 4096, 0, 108))
	assert_equal(0, c.page_count)
	assert1(wg_mapping(c, 8192, 4096, 0, 0, 109))
	assert1(wg_protect(c, 8192, 4096, 3, 0, 110))
	assert1(wg_load(c, 8200, 1, 111, &value))
	assert_equal(0, value.undefined)
	assert1(wg_unmapping(c, 8192, 4096, 0, 112))
	assert_equal(0, wg_protect(c, 8192, 4096, 3, 0, 113))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)


void thread_lifecycle():
	wg_context* c = wg_create(32, 32, 4)
	assert1(c != 0)
	wg_os* os = wg_os_create(c, 2)
	assert1(os != 0)
	wg_thread* first = wg_thread_start(os, 11, 8192, 4096, 120)
	wg_thread* second = wg_thread_start(os, 12, 16384, 4096, 121)
	assert1(first != 0)
	assert1(second != 0)
	assert_equal(2, os.active)
	wg_value value
	wg_value_set(&value, 42, 0, 0)
	assert1(wg_register_write(c, &first.registers, 0, 0, __word_size__, 0, 122, &value))
	assert1(wg_register_read(c, &second.registers, 0, 0, __word_size__, 123, &value))
	assert_equal(-1, value.undefined)
	assert_equal(121, value.origin)
	assert1(wg_io_pre(c, &first.io, 1, 8192, 1, 124))
	assert1(wg_io_pre(c, &second.io, 1, 16384, 1, 125))
	assert1(wg_io_post(c, &second.io, 1))
	assert1(wg_io_post(c, &first.io, -4))
	assert1(wg_load(c, 8192, 1, 126, &value))
	assert_equal(255, value.undefined)
	assert1(wg_load(c, 16384, 1, 127, &value))
	assert_equal(0, value.undefined)
	assert1(wg_thread_end(os, 11, 128))
	assert_equal(1, os.active)
	assert_equal(0, cast(int, wg_thread_find(os, 11)))
	first = wg_thread_start(os, 13, 8192, 4096, 129)
	assert1(first != 0)
	assert1(wg_register_read(c, &first.registers, 0, 0, __word_size__, 130, &value))
	assert_equal(-1, value.undefined)
	assert_equal(129, value.origin)
	assert_equal(0, wg_os_unsupported(c, 56, 131))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)


int main():
	io_boundaries()
	real_kernel_io()
	vector_boundaries()
	mapping_boundaries()
	thread_lifecycle()
	print("wgrind_os_test: OK\n")
	return 0
