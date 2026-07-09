import lib.lib
import lib.file
import lib.process
import lib.net
import lib.framing
import lib.json_rpc
import tools.index.w_index_core


int stop_windexd_timeout_ms():
	return 5000


char* stop_windexd_spawn_lock_file():
	return c"bin/.windexd.spawn.lock"


int stop_windexd_spawned_pid():
	char* text = file_read_text(stop_windexd_spawn_lock_file())
	if (text == 0):
		return -1
	int pid = atoi(text)
	free(text)
	return pid


int stop_windexd_port_reachable(int port):
	if (port <= 0):
		return 0
	int sock = socket_tcp_ipv4()
	if (sock < 0):
		return 0
	int reachable = socket_connect_ipv4(sock, ip4_from_string(c"127.0.0.1"), port) >= 0
	close(sock)
	return reachable


void stop_windexd_wait_port_closed(int port):
	int waited = 0
	while (waited < stop_windexd_timeout_ms()):
		if (stop_windexd_port_reachable(port) == 0):
			return
		process_sleep_ms(20)
		waited = waited + 20


void stop_windexd_wait_pid_exit(int pid):
	if (pid <= 0):
		return
	int waited = 0
	while (waited < stop_windexd_timeout_ms()):
		if (kill(pid, 0) < 0):
			return
		process_sleep_ms(20)
		waited = waited + 20


int stop_windexd_try_shutdown_port(int port):
	if (port <= 0):
		return 0
	int sock = socket_tcp_ipv4()
	if (sock < 0):
		return 0
	int connected = 0
	if (socket_connect_ipv4(sock, ip4_from_string(c"127.0.0.1"), port) >= 0):
		connected = 1
		jsonrpc_write_request(sock, 1, c"shutdown", 0)
		frame_reader* r = frame_reader_new(sock)
		json_value* response = jsonrpc_read_message(r)
		json_free(response)
		frame_reader_free(r)
	close(sock)
	if (connected):
		stop_windexd_wait_port_closed(port)
	return connected


int main():
	int pid = stop_windexd_spawned_pid()
	if (stop_windexd_try_shutdown_port(windexd_read_port())):
		stop_windexd_wait_pid_exit(pid)
	return 0
