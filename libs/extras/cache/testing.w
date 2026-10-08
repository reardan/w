# Offline scripted peer shared by the cache protocol tests. Requests are
# compared byte-for-byte; responses may split every byte across sends.
import lib.testing
import libs.standard.net.testing
import libs.extras.cache.connection


struct cache_fixture:
	int pid
	int listener
	cache_connection* client


cache_fixture* cache_fixture_start(list[string] requests, list[string] responses, int close_early, int split):
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		int fd = socket_accept_connection(listener)
		asserts(c"accept", fd >= 0)
		cache_connection* peer = cache_attach(fd, 3000)
		for i in range(requests.length):
			string request = requests[i]
			char* buf = cast(char*, malloc(request.length + 1))
			assert_equal(1, connection_context_read_exact(peer.io, buf, request.length))
			asserts(c"wire request mismatch", mem_eq(buf, request.data, request.length))
			free(buf)
			string response = responses[i]
			if (split):
				for j in range(response.length):
					if (connection_context_write_all(peer.io, response.data + j, 1) == 0): break
			else:
				connection_context_write_all(peer.io, response.data, response.length)
		if (close_early == 0):
			# Any extra request (including an accidental retry) is a bug.
			asserts(c"unexpected extra request", connection_context_read_byte(peer.io) < 0)
		cache_close(peer)
		close(listener)
		exit(0)
	cache_connection* c = cache_connect(c"127.0.0.1", port, 1000)
	assert_equal(0, c.error)
	return new cache_fixture(pid, listener, c)


void cache_fixture_finish(cache_fixture* f):
	cache_close(f.client)
	net_test_finish(f.pid, f.listener)
	free(f)


cache_fixture* cache_fixture_one(string request, string response, int close_early):
	list[string] requests = new list[string]
	list[string] responses = new list[string]
	requests.push(request)
	responses.push(response)
	cache_fixture* f = cache_fixture_start(requests, responses, close_early, 1)
	list_free[string](requests)
	list_free[string](responses)
	return f
