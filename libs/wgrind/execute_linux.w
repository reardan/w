# Linux x64 ptrace reference executor. Checked instructions execute in the
# child CPU; all state and diagnostics stay in the supervising process.
import libs.wgrind.execute_x64
import libs.wgrind.os
import libs.wgrind.heap
import libs.wgrind.report
import libs.wgrind.execute_symbols
import libs.wgrind.execute_images
import libs.wgrind.execute_threads
import libs.wgrind.leak_report
import libs.wgrind.source
import lib.file
import lib.process


struct wg_native:
	wg_machine machine
	wg_io io
	int syscall_number
	int[6] arguments
	int program_break
	int marker_mode
	int allocator_depth
	wg_symbols symbols
	wg_images images
	wg_threads threads
	int symbol_allocator
	int allocation_zeroed
	int allocation_kind
	int allocation_pointer
	int allocation_size
	int allocation_oldlength
	int allocation_oldsize
	int allocation_entry
	int allocation_site
	int source_site
	int leaks_found
	int[32] allocator_kinds
	int[32] allocator_returns
	int[32] allocator_stack
	wg_registers saved_registers


int wg_native_hex(char* text, int* cursor):
	int n = 0
	while (1):
		int ch = text[*cursor]
		int digit = ch - '0'
		if ((ch >= 'a') && (ch <= 'f')): digit = ch - 'a' + 10
		else if ((ch < '0') || (ch > '9')): break
		n = (n << 4) | digit
		*cursor = *cursor + 1
	return n


int wg_native_maps(wg_machine* m):
	char* number = itoa(m.pid)
	char* prefix = strjoin(c"/proc/", number)
	char* path = strjoin(prefix, c"/maps")
	char* maps = file_read_text(path)
	free(number)
	free(prefix)
	free(path)
	if (maps == 0): return wg_native_incomplete(m)
	int pos = 0
	while (maps[pos]):
		int low = wg_native_hex(maps, &pos)
		if (maps[pos] != '-'):
			free(maps)
			return wg_native_incomplete(m)
		pos = pos + 1
		int high = wg_native_hex(maps, &pos)
		if ((maps[pos] != ' ') || wg_less(high, low)):
			free(maps)
			return wg_native_incomplete(m)
		pos = pos + 1
		int permissions = 0
		if (maps[pos] == 'r'): permissions = permissions | WG_READ
		if (maps[pos + 1] == 'w'): permissions = permissions | WG_WRITE
		# Instruction fetch currently uses readable shadow bytes. Reject
		# execute-only application maps explicitly instead of misreporting
		# a valid CPU instruction fetch as an invalid data read. The high
		# kernel vsyscall mapping is not application executable memory.
		if ((low >= 0) && (maps[pos + 2] == 'x') && ((permissions & WG_READ) == 0)):
			free(maps)
			return wg_native_incomplete(m)
		# Kernel special mappings may reject PEEK. They are harmless until
		# accessed, when the reader fails closed; map only user-readable ones.
		if ((low <= m.raw[19]) && (m.raw[19] < high)):
			m.stack_low = low
			m.stack_high = high
			if (wg_mark(m.context, m.raw[19], high - m.raw[19], permissions, 0, 0) == 0):
				free(maps)
				return 0
			if (wg_mark(m.context, m.raw[19] - 128, 128, permissions, 255, m.raw[16]) == 0):
				free(maps)
				return 0
		else if (permissions && (low >= 0)):
			if (wg_mark(m.context, low, high - low, permissions, 0, 0) == 0):
				free(maps)
				return 0
		while (maps[pos] && (maps[pos] != '\n')): pos = pos + 1
		if (maps[pos]): pos = pos + 1
	free(maps)
	if (m.stack_high == 0): return wg_native_incomplete(m)
	return 1


int wg_native_string(wg_machine* m, int address):
	for i in range(4096):
		if (wg_kernel_read(m.context, address + i, 1, m.raw[16]) == 0): return 0
		int ch = 0
		if (wg_native_reader(m.pid, address + i, 1, &ch) == 0): return wg_native_incomplete(m)
		if (ch == 0): return 1
	return wg_native_incomplete(m)


int wg_native_argument_width(int number, int argument):
	if (((number == 0) || (number == 1) || (number == 17) || (number == 18) || (number == 19) || (number == 20) || (number == 3)) && (argument == 0)): return 4
	if ((number == 2) && (argument > 0)): return 4
	if ((number == 21) && (argument == 1)): return 4
	if ((number == 8) && ((argument == 0) || (argument == 2))): return 4
	if ((number == 9) && ((argument == 2) || (argument == 3) || (argument == 4))): return 4
	if ((number == 10) && (argument == 2)): return 4
	if ((number == 60) || (number == 231)): return 4
	if ((number == 158) && (argument == 0)): return 4
	return 8


int wg_native_syscall_pre(wg_native* n):
	wg_machine* m = &n.machine
	wg_context* c = m.context
	int site = m.raw[16]
	wg_value value
	if (wg_register_read(c, &m.registers, 0, 0, 8, site, &value) == 0): return 0
	if (wg_use(c, &value, site) == 0): return 0
	int number = value.value
	n.syscall_number = number
	int count = -1
	if ((number == 0) || (number == 1) || (number == 10) || (number == 19) || (number == 20)): count = 3
	else if ((number == 17) || (number == 18)): count = 4
	else if (number == 9): count = 6
	else if (number == 56): count = 5
	else if ((number == 435) || (number == 158)): count = 2
	else if (number == 11): count = 2
	else if ((number == 12) || (number == 3) || (number == 60) || (number == 231) || (number == 218)): count = 1
	else if ((number == 39) || (number == 102) || (number == 104) || (number == 107) || (number == 108) || (number == 186)): count = 0
	else if ((number == 8) || (number == 2)): count = 3
	else if (number == 21): count = 2
	if (count < 0): return wg_os_unsupported(c, number, site)
	if (wg_threads_syscall(&n.threads, m, number) == 0): return 0
	for i in range(count):
		int reg = 7
		if (i == 1): reg = 6
		else if (i == 2): reg = 2
		else if (i == 3): reg = 10
		else if (i == 4): reg = 8
		else if (i == 5): reg = 9
		n.arguments[i] = m.registers.values[reg]
		# O_RDONLY/O_WRONLY without create do not consume open's mode.
		if ((number == 2) && (i == 2) && ((n.arguments[1] & 64) == 0) && ((n.arguments[1] & 0x410000) != 0x410000)): continue
		# Anonymous mmap ignores fd. Offset must be page-aligned, but its
		# page-number bits do not select backing-file contents.
		if ((number == 9) && (i == 4) && (n.arguments[3] & 32)): continue
		if (wg_register_read(c, &m.registers, reg, 0, wg_native_argument_width(number, i), site, &value) == 0): return 0
		if ((number == 9) && (i == 5) && (n.arguments[3] & 32)):
			value.undefined = value.undefined & 4095
		if (wg_use(c, &value, site) == 0): return 0
	if ((number == 56) || (number == 435)):
		if (n.allocator_depth): return wg_native_incomplete(m)
		return wg_threads_clone_pre(&n.threads, m, &n.images, &n.arguments[0], number)
	if (number == 158): return wg_threads_arch_pre(&n.threads, m, &n.arguments[0])
	if (number == 218):
		if (n.arguments[0] && (wg_access(c, n.arguments[0], 4, WG_WRITE, site) == 0)): return 0
	if ((number == 2) || (number == 21)):
		if (n.allocator_depth): return 1
		return wg_native_string(m, n.arguments[0])
	if ((number == 0) || (number == 1) || (number == 17) || (number == 18)):
		if (n.allocator_depth): return 1
		return wg_io_pre(c, &n.io, (number == 0) || (number == 17), n.arguments[1], n.arguments[2], site)
	if ((number == 19) || (number == 20)):
		if (n.allocator_depth): return 1
		return wg_io_vector_pre(c, &n.io, number == 19, n.arguments[1], n.arguments[2], 8, wg_native_reader, m.pid, site)
	if ((number == 9) || (number == 10) || (number == 11)):
		if (((number == 9) || (number == 10)) && (n.arguments[2] & 4) && ((n.arguments[2] & 1) == 0)):
			return wg_native_incomplete(m)
		if ((n.arguments[1] < 0) || (n.arguments[1] + 4095 < n.arguments[1])): return wg_native_incomplete(m)
		if ((number == 9) && ((n.arguments[3] & 3) != 2)):
			# Shared mappings need a model for writes from other processes.
			return wg_native_incomplete(m)
	return 1


int wg_native_syscall_post(wg_native* n, int site):
	wg_machine* m = &n.machine
	wg_context* c = m.context
	int result = m.raw[10]
	int number = n.syscall_number
	wg_value value
	wg_value_set(&value, result, 0, 0)
	if (wg_register_write(c, &m.registers, 0, 0, 8, 0, site, &value) == 0): return 0
	wg_value_set(&value, m.raw[11], 0, 0)
	if (wg_register_write(c, &m.registers, 1, 0, 8, 0, site, &value) == 0): return 0
	int flag_unknown = m.flags.cf.undefined | (m.flags.pf.undefined << 2) | (m.flags.zf.undefined << 6) | (m.flags.sf.undefined << 7) | (m.flags.of.undefined << 11) | (m.flags.af.undefined << 4)
	int flag_origin = site
	if (m.flags.cf.undefined): flag_origin = m.flags.cf.origin
	else if (m.flags.pf.undefined): flag_origin = m.flags.pf.origin
	else if (m.flags.zf.undefined): flag_origin = m.flags.zf.origin
	else if (m.flags.sf.undefined): flag_origin = m.flags.sf.origin
	else if (m.flags.of.undefined): flag_origin = m.flags.of.origin
	else if (m.flags.af.undefined): flag_origin = m.flags.af.origin
	wg_value_set(&value, m.raw[6], flag_unknown, flag_origin)
	if (wg_register_write(c, &m.registers, 11, 0, 8, 0, site, &value) == 0): return 0
	if (wg_threads_post(&n.threads, m, number, result, &n.arguments[0]) == 0): return 0
	if (n.io.pending): return wg_io_post(c, &n.io, result)
	if ((result < 0) && (result >= -4095)): return 1
	int size = (n.arguments[1] + 4095) & ~4095
	if (number == 9):
		if (wg_threads_mapping(&n.threads, result, size) == 0): return 0
		int permissions = n.arguments[2] & 3
		if (n.allocator_depth): permissions = 0
		return wg_mapping(c, result, size, permissions, 0, site)
	if (number == 10):
		# Physical allocator guards do not redefine semantic payload bounds.
		if (n.allocator_depth): return 1
		return wg_protect(c, n.arguments[0], size, n.arguments[2] & 3, 0, site)
	if (number == 11):
		if (wg_threads_unmapping(&n.threads, n.arguments[0], size) == 0): return 0
		return wg_unmapping(c, n.arguments[0], size, 0, site)
	if (number == 12):
		if (n.program_break):
			if (result > n.program_break):
				int permissions = 3
				if (n.allocator_depth): permissions = 0
				if (wg_mark(c, n.program_break, result - n.program_break, permissions, 0, 0) == 0): return 0
			else if (result < n.program_break):
				if (wg_mark(c, result, n.program_break - result, 0, 0, 0) == 0): return 0
		n.program_break = result
	return 1


# 0 is no marker, 1 is consumed, -1 is an invalid marker/event.
int wg_native_marker(wg_native* n):
	wg_machine* m = &n.machine
	int head = 0
	if (wg_native_reader(m.pid, m.raw[16], 8, &head) == 0): return 0
	if ((head & 65535) != 0x0b0f): return 0
	int signature = (head >> 16) & wg_mask(4)
	if (signature != 0x44524757): return 0
	int version = (head >> 48) & 255
	int event = (head >> 56) & 255
	int first = 0
	int second = 0
	if ((version != 1) || (wg_native_reader(m.pid, m.raw[16] + 8, 8, &first) == 0) || (wg_native_reader(m.pid, m.raw[16] + 16, 8, &second) == 0)):
		wg_native_incomplete(m)
		return -1
	int site = m.raw[16]
	if ((event != 5) && second):
		wg_native_incomplete(m)
		return -1
	if (event == 0):
		if (n.marker_mode || (first != 8)):
			wg_native_incomplete(m)
			return -1
		n.marker_mode = 1
	else if (n.marker_mode == 0):
		wg_native_incomplete(m)
		return -1
	else if ((event >= 1) && (event <= 3)):
		int hook = 0
		if ((first == 0) || (wg_kernel_read(m.context, first, 8, site) == 0) || (wg_native_reader(m.pid, first, 8, &hook) == 0) || hook):
			wg_native_incomplete(m)
			return -1
		if (n.allocator_depth >= 32):
			wg_native_incomplete(m)
			return -1
		int ret = 0
		if (wg_native_reader(m.pid, m.raw[19], 8, &ret) == 0):
			wg_native_incomplete(m)
			return -1
		n.allocator_kinds[n.allocator_depth] = event
		n.allocator_returns[n.allocator_depth] = ret
		n.allocator_stack[n.allocator_depth] = m.raw[19]
		if (n.allocator_depth == 0):
			int argument_size = 8
			if (event == 3): argument_size = 24
			if (wg_kernel_read(m.context, m.raw[19] + 8, argument_size, site) == 0): return -1
			n.saved_registers = m.registers
			n.allocation_kind = event
			n.allocation_site = site
			if (n.source_site): n.allocation_site = n.source_site
			int arg = 0
			if (wg_native_reader(m.pid, m.raw[19] + 8, 8, &arg) == 0):
				wg_native_incomplete(m)
				return -1
			n.allocation_size = arg
			if (n.allocation_size < 1): n.allocation_size = 1
			n.allocation_oldlength = 0
			n.allocation_oldsize = 0
			n.allocation_pointer = arg
			if (event == 3):
				if (wg_native_reader(m.pid, m.raw[19] + 24, 8, &n.allocation_pointer) == 0):
					wg_native_incomplete(m)
					return -1
			# Check free/realloc pointers before trusted allocator code can
			# crash or mutate its own bookkeeping on an invalid request.
			if (event == 2):
				if (wg_deallocate(m.context, arg, n.allocation_site) == 0): return -1
			else if ((event == 3) && n.allocation_pointer):
				wg_block* block = wg_block_find(m.context, n.allocation_pointer)
				if ((block == 0) || (block.state != 1)):
					wg_error(m.context, WG_BAD_REALLOC, n.allocation_pointer, arg, site, 0)
					return -1
				if ((wg_native_reader(m.pid, m.raw[19] + 16, 8, &n.allocation_oldlength) == 0) || (n.allocation_oldlength < 0) || (n.allocation_oldlength > block.size)):
					wg_error(m.context, WG_BAD_REALLOC, n.allocation_pointer, arg, n.allocation_site, 0)
					return -1
				# W copies min(oldlen, raw newlen), even when its allocator
				# clamps a zero-sized requested payload to one byte.
				if (arg < n.allocation_oldlength): n.allocation_oldlength = arg
				if (n.allocation_oldlength < 0): n.allocation_oldlength = 0
				n.allocation_oldsize = block.size
		n.allocator_depth = n.allocator_depth + 1
	else if (event == 4):
		if ((n.allocator_depth == 0) || (first != n.allocator_kinds[n.allocator_depth - 1])):
			wg_native_incomplete(m)
			return -1
		int ret = 0
		if ((m.raw[19] != n.allocator_stack[n.allocator_depth - 1]) || (wg_native_reader(m.pid, m.raw[19], 8, &ret) == 0) || (ret != n.allocator_returns[n.allocator_depth - 1])):
			wg_native_incomplete(m)
			return -1
		n.allocator_depth = n.allocator_depth - 1
		if (n.allocator_depth == 0):
			int result = m.raw[10]
			if (n.allocation_kind == 1):
				if (wg_allocate(m.context, result, n.allocation_size, 0, n.allocation_site) == 0): return -1
			else if (n.allocation_kind == 3):
				if (wg_reallocate(m.context, n.allocation_pointer, result, n.allocation_size, result != 0, n.allocation_site) == 0): return -1
				if (result && (result != n.allocation_pointer)):
					int end = n.allocation_oldsize
					if (end > n.allocation_size): end = n.allocation_size
					if (end > n.allocation_oldlength):
						if (wg_mark(m.context, result + n.allocation_oldlength, end - n.allocation_oldlength, 3, 255, n.allocation_site) == 0): return -1
			m.registers = n.saved_registers
			wg_flags_init(&m.flags, m.raw[18], 0x8d5, n.allocation_site)
			for reg in range(16):
				if ((reg != 4) && (reg != 5) && (reg < 12)):
					wg_value defined
					int unknown = -1
					if (reg == 0): unknown = 0
					wg_value_set(&defined, m.raw[wg_native_register_offset(reg)], unknown, n.allocation_site)
					wg_register_write(m.context, &m.registers, reg, 0, 8, 0, site, &defined)
	else if (event == 5):
		if ((first < 0) || (second <= 0)):
			wg_native_incomplete(m)
			return -1
		if (n.allocator_depth == 0): n.source_site = site
	else if (event == 6):
		if (n.allocator_depth == 0):
			if ((first < 0) || (first > m.stack_high - m.raw[19])):
				wg_native_incomplete(m)
				return -1
			if (wg_access(m.context, m.raw[19], first, WG_WRITE, site) == 0): return -1
			if (wg_mark(m.context, m.raw[19], first, 3, 255, site) == 0): return -1
	else:
		wg_native_incomplete(m)
		return -1
	m.raw[16] = m.raw[16] + 24
	if (sys_ptrace(13, m.pid, 0, cast(int, &m.raw[0])) < 0):
		wg_native_incomplete(m)
		return -1
	return 1


int wg_native_symbol_event(wg_native* n):
	wg_machine* m = &n.machine
	wg_context* c = m.context
	int site = m.raw[16]
	if (n.symbol_allocator && (site == n.allocator_returns[0])):
		int result = m.raw[10]
		if ((n.allocation_kind == 1) || (n.allocation_kind == 4)):
			if (wg_allocate(c, result, n.allocation_size, n.allocation_zeroed, n.allocation_site) == 0): return 0
		else if (n.allocation_kind == 3):
			if (wg_reallocate(c, n.allocation_pointer, result, n.allocation_size, result != 0, n.allocation_site) == 0): return 0
		n.allocator_depth = 0
		n.symbol_allocator = 0
		m.registers = n.saved_registers
		wg_flags_init(&m.flags, m.raw[18], 0x8d5, n.allocation_site)
		for reg in range(16):
			if ((reg != 3) && (reg != 4) && (reg != 5) && (reg < 12)):
				wg_value value
				int unknown = -1
				if (reg == 0): unknown = 0
				wg_value_set(&value, m.raw[wg_native_register_offset(reg)], unknown, n.allocation_site)
				wg_register_write(c, &m.registers, reg, 0, 8, 0, site, &value)
		if (wg_native_stack(m, m.registers.values[4], m.raw[19]) == 0): return 0
		for reg in range(16): m.registers.values[reg] = m.raw[wg_native_register_offset(reg)]
		return 1
	if (n.allocator_depth): return 1
	int kind = wg_symbols_at(&n.symbols, site)
	if (kind == 0): return 1
	wg_value first
	wg_value second
	wg_value ret
	if (wg_register_read(c, &m.registers, 7, 0, 8, site, &first) == 0): return 0
	if (wg_use(c, &first, site) == 0): return 0
	wg_value_set(&second, 0, 0, 0)
	if ((kind == 3) || (kind == 4)):
		if (wg_register_read(c, &m.registers, 6, 0, 8, site, &second) == 0): return 0
		if (wg_use(c, &second, site) == 0): return 0
	if (wg_native_pop(m, m.raw[19], &ret) == 0): return 0
	if (wg_use(c, &ret, site) == 0): return 0
	n.saved_registers = m.registers
	n.allocation_kind = kind
	n.allocation_pointer = first.value
	n.allocation_size = first.value
	n.allocation_site = site
	n.allocation_entry = site
	n.allocation_zeroed = kind == 4
	if (kind == 3):
		n.allocation_size = second.value
		if (first.value):
			wg_block* block = wg_block_find(c, first.value)
			if ((block == 0) || (block.state != 1)): return wg_error(c, WG_BAD_REALLOC, first.value, second.value, site, 0)
	if (kind == 4):
		if ((first.value < 0) || (second.value < 0)): return wg_native_incomplete(m)
		n.allocation_size = first.value * second.value
		if (first.value && ((n.allocation_size / first.value != second.value) || (n.allocation_size < 0))): return wg_native_incomplete(m)
	if (kind == 2):
		if (wg_deallocate(c, first.value, site) == 0): return 0
	n.allocator_returns[0] = ret.value
	n.allocator_kinds[0] = kind
	n.allocator_depth = 1
	n.symbol_allocator = 1
	return 1


int wg_native_leaks(wg_native* n):
	wg_machine* m = &n.machine
	wg_context* c = m.context
	if (n.allocator_depth): return wg_native_incomplete(m)
	if (c.live_blocks == 0): return 1
	wg_leaks* leaks = wg_leaks_create(c, 65536, 262144, 1048576, 8, wg_native_reader, m.pid)
	if (leaks == 0): return 0
	if (wg_leaks_begin(leaks) == 0): return 0
	if (wg_threads_roots(&n.threads, m, leaks) == 0): return 0
	if (wg_images_roots(&n.images, leaks) == 0): return 0
	if (wg_leaks_finish(leaks) == 0): return 0
	if (wg_leaks_report(leaks, 2) == 0): return wg_native_incomplete(m)
	if (wg_leaks_report_details(leaks, 2) == 0): return wg_native_incomplete(m)
	n.leaks_found = wg_leaks_found(leaks)
	if (n.leaks_found < 0): return wg_native_incomplete(m)
	return 1


int wg_native_run(char* path, char** args):
	wg_native state
	wg_native* n = &state
	wg_machine* m = &n.machine
	n.io.pending = 0
	n.syscall_number = 0
	n.program_break = 0
	n.marker_mode = 0
	n.allocator_depth = 0
	n.symbol_allocator = 0
	n.allocation_zeroed = 0
	n.source_site = 0
	n.leaks_found = 0
	m.stack_low = 0
	m.stack_high = 0
	m.steps = 0
	m.context = wg_create(16384, 65536, 4096)
	if (m.context == 0): return 100
	wg_symbols_init(&n.symbols, m.context, 4096)
	wg_images_init(&n.images, m.context, &n.symbols, 4096)
	if ((wg_threads_init(&n.threads, m.context, 64) == 0) || m.context.error):
		wg_images_destroy(&n.images)
		wg_symbols_destroy(&n.symbols)
		wg_destroy(m.context)
		return 100
	m.pid = fork()
	if (m.pid == 0):
		if (sys_ptrace(0, 0, 0, 0) < 0): exit(100)
		execve(path, args, env_current())
		exit(126)
	if (m.pid < 0):
		wg_images_destroy(&n.images)
		wg_symbols_destroy(&n.symbols)
		wg_destroy(m.context)
		return 100
	int status = 0
	int result = 100
	if (wait4(m.pid, &status, 0, 0) != m.pid): wg_native_incomplete(m)
	if ((status & 255) != 127):
		wg_images_destroy(&n.images)
		wg_symbols_destroy(&n.symbols)
		wg_destroy(m.context)
		if ((status & 127) == 0): return (status >> 8) & 255
		return 100
	if (sys_ptrace(0x4200, m.pid, 0, WG_PTRACE_OPTIONS) < 0): wg_native_incomplete(m)
	if (sys_ptrace(12, m.pid, 0, cast(int, &m.raw[0])) < 0): wg_native_incomplete(m)
	wg_registers_init(&m.registers, m.raw[16])
	for reg in range(16):
		wg_value value
		wg_value_set(&value, m.raw[wg_native_register_offset(reg)], 0, 0)
		wg_register_write(m.context, &m.registers, reg, 0, 8, 0, m.raw[16], &value)
	wg_flags_init(&m.flags, m.raw[18], 0, 0)
	wg_native_maps(m)
	wg_images_refresh(&n.images, m.pid)
	wg_threads_add_initial(&n.threads, m)
	int alive = 1
	while (m.context.error == 0):
		if (m.steps >= 10000000):
			wg_native_incomplete(m)
			break
		m.steps = m.steps + 1
		if (wg_native_symbol_event(n) == 0): break
		int marker = wg_native_marker(n)
		if (marker < 0): break
		if (marker): continue
		if (n.symbols.w_abi && (n.marker_mode == 0)):
			wg_native_incomplete(m)
			break
		int site = m.raw[16]
		int oldsp = m.raw[19]
		int syscall_instruction = 0
		int op = 0
		if (wg_native_reader(m.pid, site, 2, &op) == 0):
			wg_native_incomplete(m)
			break
		if (op == 0x050f): syscall_instruction = 1
		if (n.allocator_depth):
			if (n.symbol_allocator):
				if (wg_symbols_allocator_contains(&n.symbols, n.allocation_entry, site) == 0):
					wg_native_incomplete(m)
					break
				if (wg_decode_native(m) == 0): break
				if ((wg_symbols_allocator_contains(&n.symbols, n.allocation_entry, site + m.instruction.length - 1) == 0) || (strcmp(m.instruction.mnemonic, c"call") == 0) || ((strcmp(m.instruction.mnemonic, c"jmp") == 0) && (m.instruction.op1.kind != ASM_OP_LABEL))):
					wg_native_incomplete(m)
					break
				if ((strcmp(m.instruction.mnemonic, c"ret") == 0) && (m.raw[19] != n.saved_registers.values[4])):
					wg_native_incomplete(m)
					break
			if (site == n.allocator_returns[n.allocator_depth - 1]):
				wg_native_incomplete(m)
				break
			for reg in range(16):
				m.registers.values[reg] = m.raw[wg_native_register_offset(reg)]
				m.registers.undefined[reg] = 0
		else:
			if (wg_decode_native(m) == 0): break
			if (wg_kernel_read(m.context, site, m.instruction.length, site) == 0): break
			if (syscall_instruction == 0):
				if (wg_native_instruction(m) == 0): break
		if (syscall_instruction):
			if (wg_native_syscall_pre(n) == 0): break
			if (((n.syscall_number == 60) && (n.threads.active == 1)) || (n.syscall_number == 231)):
				if (wg_native_leaks(n) == 0): break
		if (sys_ptrace(9, m.pid, 0, 0) < 0):
			wg_native_incomplete(m)
			break
		if (wait4(m.pid, &status, WG_WAIT_ALL, 0) != m.pid):
			wg_native_incomplete(m)
			break
		if ((status & 127) == 0):
			result = (status >> 8) & 255
			if (wg_threads_exit(&n.threads, m) == 0): break
			if ((n.syscall_number != 231) && n.threads.active):
				if (wg_threads_rotate(&n.threads, m, &n.source_site) == 0): break
				continue
			if (n.leaks_found): result = 99
			if (n.threads.active): wg_threads_kill(&n.threads)
			alive = 0
			break
		if ((status >> 16) == 6):
			if (wg_threads_exit_event(&n.threads, m, &status) == 0): break
			result = (status >> 8) & 255
			if (n.threads.active):
				if (wg_threads_rotate(&n.threads, m, &n.source_site) == 0): break
				continue
			if (n.leaks_found): result = 99
			alive = 0
			break
		if ((status >> 16) == 3):
			if (wg_threads_clone_event(&n.threads, m, &status) == 0): break
		if (((status & 255) != 127) || (((status >> 8) & 255) != 5)):
			wg_native_incomplete(m)
			break
		if (sys_ptrace(12, m.pid, 0, cast(int, &m.raw[0])) < 0):
			wg_native_incomplete(m)
			break
		if (syscall_instruction):
			if (wg_native_syscall_post(n, site) == 0): break
			if ((n.syscall_number == 9) || (n.syscall_number == 10) || (n.syscall_number == 11)):
				if (wg_images_refresh(&n.images, m.pid) == 0): break
		if (n.allocator_depth == 0):
			if (wg_native_stack(m, oldsp, m.raw[19]) == 0): break
		for reg in range(16): m.registers.values[reg] = m.raw[wg_native_register_offset(reg)]
		m.flags.zf.value = (m.raw[18] >> 6) & 1
		m.flags.sf.value = (m.raw[18] >> 7) & 1
		m.flags.cf.value = m.raw[18] & 1
		m.flags.of.value = (m.raw[18] >> 11) & 1
		m.flags.pf.value = (m.raw[18] >> 2) & 1
		m.flags.af.value = (m.raw[18] >> 4) & 1
		if (n.allocator_depth == 0):
			if (wg_threads_rotate(&n.threads, m, &n.source_site) == 0): break
	if (m.context.error):
		wg_report(m.context, 2)
		wg_source_report(path, m.context, n.source_site, 2)
		result = 99
		if (m.context.error == WG_INCOMPLETE): result = 100
	if (alive):
		if (n.threads.active): wg_threads_kill(&n.threads)
		else:
			kill(m.pid, 9)
			wait4(m.pid, &status, WG_WAIT_ALL, 0)
	wg_images_destroy(&n.images)
	wg_symbols_destroy(&n.symbols)
	wg_destroy(m.context)
	return result
