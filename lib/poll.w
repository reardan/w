# poll(2) helpers: wait for readiness on one or more file descriptors.
#
# A pollfd record is 8 bytes on both x86 and x64 (int32 fd + two int16
# masks), matching the kernel layout, so arrays of pollfd can be passed
# straight to the syscall.
import lib.lib


struct pollfd:
	int32 fd
	int16 events
	int16 revents


const int pollfd_size = 8
const int poll_in = 1
const int poll_out = 4
const int poll_err = 8
const int poll_hup = 16
const int poll_nval = 32


# Returns the pollfd at index within a contiguous array.
pollfd* pollfd_at(pollfd* fds, int index):
	return cast(pollfd*, cast(int, fds) + index * pollfd_size)


pollfd* pollfd_new_array(int count):
	char* buffer = malloc(count * pollfd_size)
	int i = 0
	while (i < count * pollfd_size):
		buffer[i] = 0
		i = i + 1
	return cast(pollfd*, buffer)


void pollfd_set(pollfd* fds, int index, int fd, int events):
	pollfd* p = pollfd_at(fds, index)
	p.fd = fd
	p.events = events
	p.revents = 0


# Waits until a descriptor is ready or timeout_ms elapses.
# timeout_ms < 0 blocks forever; 0 returns immediately.
# Returns the number of ready descriptors (0 on timeout) or a negative errno.
int poll_wait(pollfd* fds, int nfds, int timeout_ms):
	return sys_poll(cast(int, fds), nfds, timeout_ms)


# Polls a single descriptor. Returns its revents mask (0 on timeout) or a
# negative errno.
int poll_single(int fd, int events, int timeout_ms):
	pollfd p
	p.fd = fd
	p.events = events
	p.revents = 0
	int result = sys_poll(cast(int, &p), 1, timeout_ms)
	if (result <= 0):
		return result
	return p.revents
