/*
SCM_RIGHTS descriptor passing over a connected AF_UNIX stream socket
(Linux x86, x86-64 and arm64; the sendmsg/recvmsg shims live in
lib/__arch__/<arch>/syscalls.w).

	unix_send_fds(sock, data, n, fds, count)
		sends n bytes (n >= 1: the kernel attaches the descriptors to
		data, never to an empty write) with count descriptors from
		the int array fds attached. Returns bytes sent or -errno.
	unix_recv_fds(sock, buf, cap, fds_out, max, count_out)
		receives up to cap bytes; descriptors that arrived with them
		are installed close-on-exec and stored in fds_out (at most
		max of them; *count_out says how many). Returns bytes read,
		0 on EOF, or -errno.

Layouts (Linux, both word sizes): struct msghdr is seven word-sized
fields (name, namelen, iov, iovlen, control, controllen, flags -- the
two int fields are padded to a word on 64-bit), struct iovec is two
words, and struct cmsghdr is {size_t len, int level, int type} followed
by the descriptors at the next word boundary.
*/
import lib.lib
import lib.mem


int unix_fds_sol_socket():
	return 1


int unix_fds_scm_rights():
	return 1


# MSG_CMSG_CLOEXEC: received descriptors do not leak into programs the
# receiver later execs.
int unix_fds_msg_cmsg_cloexec():
	return 1073741824


int unix_fds_align(int n):
	return (n + __word_size__ - 1) & (0 - __word_size__)


# Offset of the descriptor array inside one cmsghdr (CMSG_DATA).
int unix_fds_cmsg_data_offset():
	return unix_fds_align(__word_size__ + 8)


# Bytes of control buffer holding count descriptors (CMSG_SPACE).
int unix_fds_cmsg_space(int count):
	return unix_fds_cmsg_data_offset() + unix_fds_align(count * 4)


char* unix_fds_msghdr(char* iov, char* control, int control_length):
	char* msg = malloc(7 * __word_size__)
	save_word(msg, 0)
	save_word(msg + __word_size__, 0)
	save_word(msg + 2 * __word_size__, cast(int, iov))
	save_word(msg + 3 * __word_size__, 1)
	save_word(msg + 4 * __word_size__, cast(int, control))
	save_word(msg + 5 * __word_size__, control_length)
	save_word(msg + 6 * __word_size__, 0)
	return msg


char* unix_fds_iovec(char* data, int n):
	char* iov = malloc(2 * __word_size__)
	save_word(iov, cast(int, data))
	save_word(iov + __word_size__, n)
	return iov


int unix_send_fds(int sock, char* data, int n, int* fds, int count):
	int space = unix_fds_cmsg_space(count)
	char* control = malloc(space)
	mem_fill(control, 0, space)
	save_word(control, unix_fds_cmsg_data_offset() + count * 4)
	save_int(control + __word_size__, unix_fds_sol_socket())
	save_int(control + __word_size__ + 4, unix_fds_scm_rights())
	int i = 0
	while (i < count):
		save_int(control + unix_fds_cmsg_data_offset() + i * 4, fds[i])
		i = i + 1
	char* iov = unix_fds_iovec(data, n)
	char* msg = unix_fds_msghdr(iov, control, space)
	int sent = sys_sendmsg(sock, cast(int, msg), 0)
	free(msg)
	free(iov)
	free(control)
	return sent


int unix_recv_fds(int sock, char* buf, int cap, int* fds_out, int max, int* count_out):
	*count_out = 0
	int space = unix_fds_cmsg_space(max)
	char* control = malloc(space)
	char* iov = unix_fds_iovec(buf, cap)
	char* msg = unix_fds_msghdr(iov, control, space)
	int got = sys_recvmsg(sock, cast(int, msg), unix_fds_msg_cmsg_cloexec())
	if (got >= 0):
		int control_length = load_word(msg + 5 * __word_size__)
		int off = 0
		while (off + unix_fds_cmsg_data_offset() <= control_length):
			int length = load_word(control + off)
			if (length < unix_fds_cmsg_data_offset()):
				break
			int level = load_int32(control + off + __word_size__)
			int kind = load_int32(control + off + __word_size__ + 4)
			if ((level == unix_fds_sol_socket()) && (kind == unix_fds_scm_rights())):
				int n = (length - unix_fds_cmsg_data_offset()) / 4
				int i = 0
				while (i < n):
					int fd = load_int32(control + off + unix_fds_cmsg_data_offset() + i * 4)
					if (*count_out < max):
						fds_out[*count_out] = fd
						*count_out = *count_out + 1
					else:
						# More than the caller has room for: never leak.
						close(fd)
					i = i + 1
			off = off + unix_fds_align(length)
	free(msg)
	free(iov)
	free(control)
	return got
