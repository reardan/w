/*
Cryptographically secure random bytes (plan 11 phase 1, issue #193).

random_bytes fills a caller-owned buffer from the kernel CSPRNG: the
getrandom(2) syscall where the target has one (Linux x86/x86-64/arm64),
with a /dev/urandom read fallback for kernels that predate it. Darwin has
no getrandom syscall at all, so arm64_darwin's sys_getrandom wrapper
returns ENOSYS by design (lib/__arch__/arm64_darwin/syscalls.w) and that
target always takes the fallback path.

Both entry points return 1 on success and 0 on failure; on failure the
buffer contents are unspecified and must not be used as randomness.
*/
import lib.linux


# EINTR: a signal interrupted the call before any bytes arrived; retry.
int random_eintr():
	return 0 - 4


# Fallback path: reads exactly len bytes from /dev/urandom. Returns 1 on
# success, 0 when the device cannot be opened or the read comes up short.
int random_urandom_fill(char* buf, int len):
	if (len < 0):
		return 0
	int fd = open(c"/dev/urandom", 0, 0)
	if (fd < 0):
		return 0
	int off = 0
	while (off < len):
		int got = read(fd, buf + off, len - off)
		if (got > 0):
			off = off + got
		else if (got != random_eintr()):
			close(fd)
			return 0
	close(fd)
	return 1


# Fills buf[0..len) with random bytes from getrandom(2), retrying short
# reads and EINTR; any other failure (ENOSYS on old kernels and on
# arm64_darwin) falls back to /dev/urandom for the remainder. Returns 1
# on success, 0 on failure.
int random_bytes(char* buf, int len):
	if (len < 0):
		return 0
	int off = 0
	while (off < len):
		int got = sys_getrandom(buf + off, len - off, 0)
		if (got > 0):
			off = off + got
		else if (got != random_eintr()):
			return random_urandom_fill(buf + off, len - off)
	return 1
