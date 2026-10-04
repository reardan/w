# Explicit IPv4 TCP destinations only. Guest descriptors are virtual; all
# host sockets stay nonblocking, including when the guest asks to block.
import lib.vmm.memory
import lib.vmm.filesystem
import lib.vmm.threads
import lib.net
import lib.time

struct cell_net_state:
	int* descriptors
	int* flags
	int* connecting
	int* addresses
	int* ports
	int count


int cell_net_ipv4(char* text):
	int address = 0
	int pos = 0
	for part in range(4):
		int value = 0
		int digits = 0
		while (text[pos] >= 48 && text[pos] <= 57):
			value = value * 10 + text[pos] - 48
			digits = digits + 1
			if (digits > 3 || value > 255): return -1
			pos = pos + 1
		if (digits == 0): return -1
		address = address | (value << (part * 8))
		if (part < 3):
			if (text[pos] != 46): return -1
			pos = pos + 1
	if (text[pos] != 0): return -1
	return address


void cell_net_free(vm_cell* cell);


int cell_net_allow(vm_cell* cell, char* ipv4, int port):
	if (cell.started || port < 1 || port > 65535): return 0
	int address = cell_net_ipv4(ipv4)
	if (address < 0): return 0
	cell_net_state* state = cast(cell_net_state*, cell.net_state)
	if (state == 0):
		state = malloc(sizeof(cell_net_state))
		state.descriptors = malloc(64 * __word_size__)
		state.flags = malloc(64 * __word_size__)
		state.connecting = malloc(64 * __word_size__)
		state.addresses = malloc(64 * __word_size__)
		state.ports = malloc(64 * __word_size__)
		state.count = 0
		for i in range(64):
			state.descriptors[i] = -1
			state.flags[i] = 0
			state.connecting[i] = 0
		cell.net_state = state
		cell.net_cleanup = cast(void*, cell_net_free)
	for i in range(state.count):
		if (state.addresses[i] == address && state.ports[i] == port): return 1
	if (state.count == 64): return 0
	state.addresses[state.count] = address
	state.ports[state.count] = port
	state.count = state.count + 1
	return 1


void cell_net_free(vm_cell* cell):
	if (cell == 0 || cell.net_state == 0): return
	cell_net_state* state = cast(cell_net_state*, cell.net_state)
	for i in range(64):
		if (state.descriptors[i] >= 0): close(state.descriptors[i])
	free(state.descriptors)
	free(state.flags)
	free(state.connecting)
	free(state.addresses)
	free(state.ports)
	free(state)
	cell.net_state = 0


int cell_net_host_fd(vm_cell* cell, int fd):
	if (cell.net_state == 0 || fd < 64 || fd >= 128): return -1
	cell_net_state* state = cast(cell_net_state*, cell.net_state)
	return state.descriptors[fd - 64]


type cell_net_wait_fn = fn(vm_cell*, int, int) -> int


int cell_net_wait(vm_cell* cell, int fd, int events):
	if (cell.thread_io_wait != 0):
		int ready = poll_single(fd, events, 0)
		if (ready != 0): return ready
		cell_net_wait_fn* wait = cast(cell_net_wait_fn*, cell.thread_io_wait)
		return wait(cell, fd, events)
	int remaining = cell.deadline_ms - time_monotonic_ms()
	if (remaining <= 0): return -110
	int result = poll_single(fd, events, remaining)
	if (result == 0): return -110
	return result


int cell_net_socket(vm_cell* cell, int domain, int kind, int protocol):
	if (cell.net_state == 0): return -13
	if (domain != 2 || (kind & ~526336) != 1 || (protocol != 0 && protocol != 6)): return -13
	cell_net_state* state = cast(cell_net_state*, cell.net_state)
	for i in range(64):
		if (state.descriptors[i] < 0):
			int fd = sys_socket(2, 526337, 6) # STREAM | NONBLOCK | CLOEXEC
			if (fd < 0): return fd
			state.descriptors[i] = fd
			state.flags[i] = kind & 2048
			state.connecting[i] = 0
			return 64 + i
	return -24


int cell_net_connect(vm_cell* cell, int guest_fd, int address, int length):
	int fd = cell_net_host_fd(cell, guest_fd)
	if (fd < 0): return -9
	if (length != 16): return -22
	if (cell_range(cell, address, 16, 0) == 0): return -14
	char* addr = cell.ram + address
	if (load_int16(addr) != 2): return -13
	int ip = 0
	for i in range(4): ip = ip | ((cast(int, addr[4 + i]) & 255) << (i * 8))
	int port = (cast(int, addr[2]) & 255) * 256 + (cast(int, addr[3]) & 255)
	cell_net_state* state = cast(cell_net_state*, cell.net_state)
	int allowed = 0
	for i in range(state.count):
		if (state.addresses[i] == ip && state.ports[i] == port): allowed = 1
	if (allowed == 0): return -13
	int result = -115
	if (state.connecting[guest_fd - 64] == 0): result = sys_connect(fd, cast(int, addr), 16)
	if (result != -115 || state.flags[guest_fd - 64]): return result
	state.connecting[guest_fd - 64] = 1
	result = cell_net_wait(cell, fd, 4)
	if (result < 0): return result
	state.connecting[guest_fd - 64] = 0
	int error = 0
	int size = 4
	result = syscall7(55, fd, 1, 4, cast(int, &error), cast(int, &size), 0)
	if (result < 0): return result
	return 0 - error


int cell_net_io(vm_cell* cell, int guest_fd, int address, int length, int flags, int receiving):
	int fd = cell_net_host_fd(cell, guest_fd)
	if (fd < 0): return -9
	# DONTWAIT, NOSIGNAL and (receive only) PEEK are supported.
	int permitted = 16448
	if (receiving): permitted = permitted | 2
	if ((flags & ~permitted) != 0): return -22
	if (length < 0): return -22
	if (length == 0): return 0
	if (cell_range(cell, address, length, receiving) == 0): return -14
	cell_net_state* state = cast(cell_net_state*, cell.net_state)
	int blocking = (state.flags[guest_fd - 64] == 0 && (flags & 64) == 0)
	while (1):
		int result = 0
		if (receiving): result = syscall7(45, fd, cast(int, cell.ram + address), length, flags | 64, 0, 0)
		else: result = syscall7(44, fd, cast(int, cell.ram + address), length, flags | 16448, 0, 0)
		if (result != -11 || blocking == 0): return result
		int events = 4
		if (receiving): events = 1
		result = cell_net_wait(cell, fd, events)
		if (result < 0): return result
	return -5


int cell_net_poll_fd(vm_cell* cell, int guest):
	if (guest >= 64): return cell_net_host_fd(cell, guest)
	if (guest >= 3 && cell.fs_state != 0): return cell_fs_descriptor(cast(cell_filesystem*, cell.fs_state), guest)
	return -1


int cell_net_poll_virtual(vm_cell* cell, int guest, int events):
	if (guest < 0): return 0
	if (guest < 3):
		if (cell.closed_fds & (1 << guest)): return 32
		if (guest == 0): return events & 1
		return events & 4
	if (cell_net_poll_fd(cell, guest) < 0): return 32
	return 0


int cell_net_poll(vm_cell* cell, int address, int count, int timeout):
	if (count < 0 || count > 128 || timeout < -1): return -22
	if (count > 0 && cell_range(cell, address, count * 8, 1) == 0): return -14
	char[1024] copied
	int virtual_ready = 0
	for i in range(count):
		char* source = cell.ram + address + i * 8
		char* target = &copied[i * 8]
		int guest = load_int32(source)
		int events = load_int16(source + 4)
		if (cell_net_poll_virtual(cell, guest, events)): virtual_ready = virtual_ready + 1
		save_int32(target, cell_net_poll_fd(cell, guest))
		save_int16(target + 4, events)
		save_int16(target + 6, 0)
	int now = time_monotonic_ms()
	int until = cell.deadline_ms
	cell_thread* thread = 0
	if (cell.thread_state != 0):
		cell_threads* threads = cast(cell_threads*, cell.thread_state)
		thread = &threads.slots[threads.current]
		if (thread.poll_deadline_ms != 0): until = thread.poll_deadline_ms
		else:
			if (timeout >= 0 && timeout < until - now): until = now + timeout
			thread.poll_deadline_ms = until
	else:
		if (timeout >= 0 && timeout < until - now): until = now + timeout
	int remaining = until - now
	if (remaining < 0): remaining = 0
	int wait_ms = remaining
	if (virtual_ready || thread != 0): wait_ms = 0
	int result = sys_poll(cast(int, &copied[0]), count, wait_ms)
	if (result == 0 && virtual_ready == 0 && remaining > 0 && thread != 0):
		cell_net_wait_fn* wait = cast(cell_net_wait_fn*, cell.thread_io_wait)
		return wait(cell, -1, 1)
	if (thread != 0): thread.poll_deadline_ms = 0
	if (result < 0): return result
	for i in range(count):
		char* target = cell.ram + address + i * 8
		int events = load_int16(&copied[i * 8 + 6])
		events = events | cell_net_poll_virtual(cell, load_int32(target), load_int16(target + 4))
		save_int16(target + 6, events)
	return result + virtual_ready


int cell_net_syscall(vm_cell* cell):
	int nr = load_int64(cell.regs)
	int a = load_int64(cell.regs + 40)
	int b = load_int64(cell.regs + 32)
	int c = load_int64(cell.regs + 24)
	int d = load_int64(cell.regs + 80)
	int e = load_int64(cell.regs + 64)
	int f = load_int64(cell.regs + 72)
	if (nr == 41): return cell_net_socket(cell, a, b, c)
	if (nr == 42): return cell_net_connect(cell, a, b, c)
	if (nr == 7): return cell_net_poll(cell, a, b, c)
	# No bind, listen, accept, socketpair or ancillary-message APIs.
	if (nr == 43 || nr == 46 || nr == 47 || nr == 49 || nr == 50 || nr == 53 || nr == 288): return -13
	if (nr != 0 && nr != 1 && nr != 3 && nr != 44 && nr != 45 && nr != 48 && nr != 51 && nr != 52 && nr != 54 && nr != 55 && nr != 72): return -4096
	if (a < 64 || a >= 128):
		if (nr >= 44 && nr <= 55): return -9
		return -4096
	int fd = cell_net_host_fd(cell, a)
	if (fd < 0): return -9
	cell_net_state* state = cast(cell_net_state*, cell.net_state)
	if (nr == 0 || nr == 1): return cell_net_io(cell, a, b, c, 0, nr == 0)
	if (nr == 44 || nr == 45):
		# Connected TCP only: a send address could bypass the allowlist.
		if (e != 0 || f != 0): return -22
		return cell_net_io(cell, a, b, c, d, nr == 45)
	if (nr == 3):
		int canceled = cell_thread_cancel_io(cell, fd)
		if (canceled < 0): return canceled
		state.descriptors[a - 64] = -1
		return close(fd)
	if (nr == 48):
		if (b < 0 || b > 2): return -22
		return syscall(48, fd, b, 0)
	if (nr == 72):
		if (b == 1): return 1 # F_GETFD: always CLOEXEC on host
		if (b == 2): return 0
		if (b == 3): return state.flags[a - 64] | 2
		if (b == 4):
			if ((c & ~2050) != 0): return -22
			state.flags[a - 64] = c & 2048
			return 0
		return -22
	if (nr == 55):
		if (b != 1 || (c != 4 && c != 3)): return -92 # SO_ERROR / SO_TYPE
		if (cell_range(cell, e, 4, 1) == 0): return -14
		if (load_int32(cell.ram + e) < 4): return -22
		if (cell_range(cell, d, 4, 1) == 0): return -14
		int value = 0
		int length = 4
		int result = syscall7(55, fd, b, c, cast(int, &value), cast(int, &length), 0)
		if (result < 0): return result
		save_int32(cell.ram + d, value)
		save_int32(cell.ram + e, 4)
		return 0
	if (nr == 54): return -92
	return -4096
