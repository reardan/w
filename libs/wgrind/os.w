# Serialized OS events shared by native execution frontends. These are
# guest events: the checker does not perform the application's syscalls.
import libs.wgrind.reader
import libs.wgrind.registers

const int WG_IOV_MAX = 1024

struct wg_io:
	int pending
	int output
	int count
	int total
	int site
	int[1024] addresses
	int[1024] lengths

struct wg_thread:
	int id
	int active
	int stack
	int stack_size
	wg_registers registers
	wg_io io

struct wg_os:
	wg_context* context
	wg_thread* threads
	int limit
	int active


int wg_io_check(wg_context* c, int output, int address, int size, int site):
	if (output): return wg_access(c, address, size, WG_WRITE, site)
	return wg_kernel_read(c, address, size, site)


int wg_io_pre(wg_context* c, wg_io* io, int output, int address, int size, int site):
	if (c.error): return 0
	if (io.pending || ((output != 0) && (output != 1))): return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	if (wg_io_check(c, output, address, size, site) == 0): return 0
	io.output = output
	io.count = 1
	io.total = size
	io.site = site
	io.addresses[0] = address
	io.lengths[0] = size
	io.pending = 1
	return 1


int wg_io_vector_pre(wg_context* c, wg_io* io, int output, int address, int count, int pointer_size, wg_reader* reader, int opaque, int site):
	if (c.error): return 0
	if (io.pending || (reader == 0) || (count < 0) || (count > WG_IOV_MAX) || ((output != 0) && (output != 1)) || ((pointer_size != 4) && (pointer_size != 8)) || (pointer_size > __word_size__)):
		return wg_error(c, WG_INCOMPLETE, address, count, site, 0)
	if (wg_kernel_read(c, address, count * pointer_size * 2, site) == 0): return 0
	int total = 0
	for i in range(count):
		int at = address + i * pointer_size * 2
		int base = 0
		int size = 0
		if ((reader(opaque, at, pointer_size, &base) == 0) || (reader(opaque, at + pointer_size, pointer_size, &size) == 0)):
			return wg_error(c, WG_INCOMPLETE, at, pointer_size * 2, site, 0)
		if ((size < 0) || (total + size < total)): return wg_error(c, WG_INCOMPLETE, base, size, site, 0)
		if (wg_io_check(c, output, base, size, site) == 0): return 0
		io.addresses[i] = base
		io.lengths[i] = size
		total = total + size
	io.output = output
	io.count = count
	io.total = total
	io.site = site
	io.pending = 1
	return 1


int wg_io_post(wg_context* c, wg_io* io, int result):
	if (c.error): return 0
	if (io.pending == 0): return wg_error(c, WG_INCOMPLETE, 0, result, io.site, 0)
	io.pending = 0
	if (result <= 0): return 1
	if (result > io.total): return wg_error(c, WG_INCOMPLETE, 0, result, io.site, 0)
	if (io.output == 0): return 1
	# First validate every written span. Failed validation leaves all
	# definedness untouched, even when another thread unmapped a buffer.
	int remaining = result
	for i in range(io.count):
		int size = io.lengths[i]
		if (size > remaining): size = remaining
		if (wg_access(c, io.addresses[i], size, WG_WRITE, io.site) == 0): return 0
		remaining = remaining - size
	remaining = result
	for i in range(io.count):
		int size = io.lengths[i]
		if (size > remaining): size = remaining
		if (wg_kernel_write(c, io.addresses[i], size, io.site) == 0): return 0
		remaining = remaining - size
	return 1


int wg_unmapping(wg_context* c, int address, int size, int result, int site):
	if (c.error): return 0
	if (result < 0): return 1
	if (wg_range(address, size) == 0): return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	return wg_mark(c, address, size, 0, 0, 0)


int wg_protect(wg_context* c, int address, int size, int permissions, int result, int site):
	if (c.error): return 0
	if (result < 0): return 1
	# Internal permission 4 retains inaccessible shadow and its V bits.
	# It contributes to page.active but satisfies neither access bit.
	if ((permissions < 0) || (permissions > 3) || (wg_range(address, size) == 0)):
		return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	for i in range(size):
		wg_page* p = wg_page_find(c, address + i)
		if ((p == 0) || (p.permissions[(address + i) & 4095] == 0)):
			return wg_error(c, WG_INCOMPLETE, address + i, size, site, 0)
	for i in range(size):
		wg_page* p = wg_page_find(c, address + i)
		int resident = permissions
		if (resident == 0): resident = 4
		p.permissions[(address + i) & 4095] = resident
	return 1


int wg_mapping(wg_context* c, int address, int size, int permissions, int result, int site):
	if (c.error): return 0
	if (result < 0): return 1
	if (wg_range(address, size) == 0): return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	if ((permissions < 0) || (permissions > 3)): return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	int accessible = permissions
	if (accessible == 0): accessible = 3
	if (wg_mark(c, address, size, accessible, 0, 0) == 0): return 0
	if (permissions == 0): return wg_protect(c, address, size, 0, 0, site)
	return 1


wg_os* wg_os_create(wg_context* c, int limit):
	if (c.error): return 0
	if ((limit < 1) || (limit > 1024)):
		wg_error(c, WG_INCOMPLETE, 0, limit, 0, 0)
		return 0
	wg_os* os = cast(wg_os*, wg_reserve(c, sizeof(wg_os)))
	if (os == 0): return 0
	os.context = c
	os.limit = limit
	os.active = 0
	os.threads = cast(wg_thread*, wg_reserve(c, sizeof(wg_thread) * limit))
	if (os.threads == 0): return 0
	for i in range(limit):
		wg_thread fresh
		os.threads[i] = fresh
		os.threads[i].active = 0
		os.threads[i].io.pending = 0
	return os


wg_thread* wg_thread_find(wg_os* os, int id):
	for i in range(os.limit):
		wg_thread* thread = &os.threads[i]
		if (thread.active && (thread.id == id)): return thread
	return 0


wg_thread* wg_thread_start(wg_os* os, int id, int stack, int size, int site):
	wg_context* c = os.context
	if (c.error): return 0
	if ((id <= 0) || (wg_thread_find(os, id) != 0) || (os.active == os.limit) || (wg_range(stack, size) == 0)):
		wg_error(c, WG_INCOMPLETE, stack, size, site, 0)
		return 0
	for i in range(os.limit):
		wg_thread* existing = &os.threads[i]
		if (existing.active && size && existing.stack_size):
			if (wg_less(stack - existing.stack, existing.stack_size) || wg_less(existing.stack - stack, size)):
				wg_error(c, WG_INCOMPLETE, stack, size, site, 0)
				return 0
	for i in range(os.limit):
		wg_thread* thread = &os.threads[i]
		if (thread.active == 0):
			thread.id = id
			thread.stack = stack
			thread.stack_size = size
			thread.io.pending = 0
			wg_registers_init(&thread.registers, site)
			if (wg_mark(c, stack, size, 3, 255, site) == 0): return 0
			thread.active = 1
			os.active = os.active + 1
			return thread
	return 0


int wg_thread_end(wg_os* os, int id, int site):
	wg_context* c = os.context
	if (c.error): return 0
	wg_thread* thread = wg_thread_find(os, id)
	if (thread == 0): return wg_error(c, WG_INCOMPLETE, id, 0, site, 0)
	if (thread.io.pending): return wg_error(c, WG_INCOMPLETE, id, 0, site, 0)
	if (wg_mark(c, thread.stack, thread.stack_size, 0, 0, 0) == 0): return 0
	thread.active = 0
	os.active = os.active - 1
	return 1


int wg_os_unsupported(wg_context* c, int operation, int site):
	# clone flags, signal frames, ioctls and asynchronous memory writes
	# require explicit frontend models; never silently grant coverage.
	return wg_error(c, WG_INCOMPLETE, operation, 0, site, 0)
