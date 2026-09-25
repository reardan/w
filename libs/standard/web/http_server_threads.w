# Multi-threaded HTTP/1.1 serving on the task runtime (lib/task_runtime.w,
# docs/projects/async.md stage 6). One accept task on worker 0 hands each
# connection to the workers round-robin, where it runs as an ordinary
# connection task (http_server.w's server_connection_task), so every
# worker multiplexes many connections and the workers run in parallel.
#
# Plain HTTP only for now: the TLS handshake's big-number and P-256 code
# (libs/standard/crypto/bignum.w, ecdsa_p256.w) keeps scratch values in
# module globals, which is fine for any number of tasks on one thread
# but not for handshakes running on several threads at once. Serve
# HTTPS with server_context_serve_tasks until that scratch is per call.
#
# Handlers run on several threads at once: anything they share (globals,
# the handler context) must be read-only or guarded by a wmutex that is
# never held across an await.
#
# Linux x86/x86-64 only, like lib/task_runtime.w.
#
#   int server_context_serve_threads(ServerContext* s, int nthreads, int max_connections)
import lib.lib
import lib.net
import lib.thread
import lib.task
import lib.task_io
import lib.task_runtime
import libs.standard.web.http_server


generator int server_threads_accept_task(ServerContext* s, task_runtime* rt, int max_connections, int* out):
	socket_set_nonblocking(s.listener_fd)
	int served = 0
	int next = 0
	while ((max_connections <= 0) || (served < max_connections)):
		sockaddr_in peer
		int conn = task_accept_from(s.listener_fd, &peer)
		if (conn < 0):
			if ((conn == task_err_cancelled()) || (conn == task_err_timed_out())):
				break
			if ((conn == -4) || (conn == -103) || (conn == -24) || (conn == -23)):
				task_sleep_ms(1)
				continue
			break
		generator* g = server_connection_task(s, conn, net_htonl(peer.ip_address), net_htons(peer.port))
		gen_set_stack_size(g, server_task_stack_bytes())
		task_runtime_spawn_on(rt, next, g)
		next = next + 1
		served = served + 1
	out[0] = served


# Serve until max_connections were accepted and served (<= 0: forever)
# on nthreads worker threads. Returns the number of connections
# accepted, or -1 for a TLS server (see the module doc).
int server_context_serve_threads(ServerContext* s, int nthreads, int max_connections):
	if (s.is_tls != 0):
		return -1
	task_runtime* rt = task_runtime_new(nthreads)
	int* served = cast(int*, malloc(__word_size__))
	served[0] = 0
	task_runtime_spawn_on(rt, 0, server_threads_accept_task(s, rt, max_connections, served))
	task_runtime_run(rt)
	task_runtime_free(rt)
	int n = served[0]
	free(cast(void*, served))
	return n
