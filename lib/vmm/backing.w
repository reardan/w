# Build shared memfd backing inside the fleet cgroup, then hand ownership
# to the daemon via SCM_RIGHTS. The parent remains outside the OOM domain.
# Shared metadata is bounded and contains values only, never child pointers.
import lib.vmm.cgroup
import lib.memfd
import lib.mem
import lib.net

type vm_backing_builder = fn(void*, char*) -> int


int vm_backing_send(int socket, int fd):
	char[56] message
	char[16] iov
	char[24] control
	char marker = '!'
	mem_fill[char](&message[0], 0, 56)
	mem_fill[char](&control[0], 0, 24)
	save_int64(&iov[0], cast(int, &marker))
	save_int64(&iov[8], 1)
	save_int64(&control[0], 20)
	save_int32(&control[8], 1)
	save_int32(&control[12], 1)
	save_int32(&control[16], fd)
	save_int64(&message[16], cast(int, &iov[0]))
	save_int64(&message[24], 1)
	save_int64(&message[32], cast(int, &control[0]))
	save_int64(&message[40], 24)
	int sent = syscall(46, socket, cast(int, &message[0]), 16384)
	while (sent == -4): sent = syscall(46, socket, cast(int, &message[0]), 16384)
	return sent == 1


int vm_backing_receive(int socket):
	char[56] message
	char[16] iov
	char[24] control
	char marker = 0
	mem_fill[char](&message[0], 0, 56)
	mem_fill[char](&control[0], 0, 24)
	save_int64(&iov[0], cast(int, &marker))
	save_int64(&iov[8], 1)
	save_int64(&message[16], cast(int, &iov[0]))
	save_int64(&message[24], 1)
	save_int64(&message[32], cast(int, &control[0]))
	save_int64(&message[40], 24)
	int received = syscall(47, socket, cast(int, &message[0]), 1073741888) # CMSG_CLOEXEC|DONTWAIT
	int bytes = load_int64(&control[0])
	int rights = load_int32(&control[8]) == 1 && load_int32(&control[12]) == 1
	if (received != 1 || load_int64(&message[40]) != 24 || bytes != 20 || rights == 0):
		# recvmsg can install descriptors even when a peer sent an invalid
		# message. Close every descriptor fitting our bounded control buffer.
		if (received >= 0 && rights && bytes >= 20 && bytes <= 24):
			close(load_int32(&control[16]))
			if (bytes == 24): close(load_int32(&control[20]))
		return -1
	int fd = load_int32(&control[16])
	if (marker != '!' || (load_int32(&message[48]) & 8)):
		close(fd)
		return -1
	return fd


int vm_backing_create(vm_cgroup* group, vm_backing_builder* builder, void* request, char* metadata, int length):
	if (__word_size__ != 8 || length < 0 || length > 4096): return -1
	int address = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS)
	if (address < 0 && address > -4096): return -1
	int[2] sockets
	if (socket_pair(&sockets[0]) < 0):
		munmap(address, 4096)
		return -1
	int parent = getpid()
	int pid = fork()
	if (pid == 0):
		if (syscall7(157, 1, 9, 0, 0, 0, 0) < 0 || syscall(110, 0, 0, 0) != parent): exit(125)
		close(sockets[0])
		if (group != 0 && vm_cgroup_attach(group, getpid()) == 0): exit(125)
		if (dup2(sockets[1], 3) < 0): exit(125)
		if (syscall(436, 4, 4294967295, 0) < 0): exit(125)
		int backing = builder(request, cast(char*, address))
		if (backing < 0): exit(125)
		if (vm_backing_send(3, backing) == 0): exit(125)
		exit(0)
	close(sockets[1])
	int fd = -1
	if (pid > 0):
		int deadline = process_monotonic_ms() + 30000
		while (deadline > process_monotonic_ms()):
			int remaining = deadline - process_monotonic_ms()
			if (remaining <= 0): break
			int events = poll_single(sockets[0], poll_in, remaining)
			if (events == -4): continue
			if (events > 0): fd = vm_backing_receive(sockets[0])
			break
		int status = 0
		int reaped = wait4(pid, &status, 1, 0)
		while (reaped == 0 && process_monotonic_ms() < deadline):
			process_sleep_ms(1)
			reaped = wait4(pid, &status, 1, 0)
		if (reaped <= 0):
			kill(pid, 9)
			while (wait4(pid, &status, 0, 0) == -4): pass
			status = 125
		if (status != 0 && fd >= 0):
			close(fd)
			fd = -1
	close(sockets[0])
	if (fd >= 0 && length > 0): mem_copy[char](metadata, cast(char*, address), length)
	munmap(address, 4096)
	return fd
