# The graphics.control socket on Linux and Darwin: an AF_UNIX stream
# client (lib/net.w) the driver listens for. Reads are polled with a
# zero timeout so the frame loop never blocks; writes block until the
# whole response is out and never raise SIGPIPE when the driver went
# away (the next read then reports EOF).
import lib.lib
import lib.net
import lib.poll


# Connected descriptor, or a negative errno.
int gfx_control_transport_connect(char* path):
	int fd = socket_connect_unix_path(path)
	if (fd >= 0): socket_set_nosigpipe(fd)
	return fd


# 1 when a read would not block (data, EOF or an error is pending).
int gfx_control_transport_readable(int fd):
	int revents = poll_single(fd, poll_in, 0)
	if (revents < 0): return 1
	return revents != 0


# Bytes read (>0), 0 on EOF, negative on error.
int gfx_control_transport_recv(int fd, char* buf, int n):
	return socket_recv(fd, buf, n, 0)


# Writes all n bytes; returns n, or negative once the peer is gone.
int gfx_control_transport_send(int fd, char* buf, int n):
	int sent = 0
	while (sent < n):
		int k = socket_send(fd, buf + sent, n - sent, msg_nosignal())
		if (k <= 0): return 0 - 1
		sent = sent + k
	return n


void gfx_control_transport_close(int fd):
	close(fd)
