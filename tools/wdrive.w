# wbuild: binary=wdrive arch=x64
/*
wdrive: drive a real, unmodified W graphics program through its
graphics.control channel (docs/projects/wdrive.md) -- inject input,
step frames, take screenshots, read pixels and the accessibility
tree -- with or without a physical display.

	wdrive run [options] [--script steps.json | --steps '<json array>'] -- PROGRAM [args...]
	wdrive serve [options] -- PROGRAM [args...]

options:
	--xvfb            always start a private Xvfb (default: only without DISPLAY)
	--screen WxH      the Xvfb screen size (default 1280x1024)
	--size WxH        resize the program's window after it connects
	--out DIR         where relative and default screenshot paths go (created)
	--timeout-ms N    per-step and connect timeout (default 10000)
	--keep-going      run: report failed steps and continue

run executes the steps and prints one NDJSON line per step on stdout,
after a first {"step":0,"cmd":"hello",...} line; it exits 0 when every
step passed, 1 when one failed or timed out, 2 on a usage error and 3
when the program or the display could not be started. serve reads the
same step objects as NDJSON from stdin and answers each with one line,
until stdin ends. The program's own stdout and stderr go to wdrive's
stderr, so stdout stays pure NDJSON. The program and the Xvfb wdrive
started are killed at the end either way.

Steps are protocol requests ({"cmd":"click","x":10,"y":20}) plus the
driver-side wait_ms, assert_pixel, assert_a11y and click_node.
*/
import lib.lib
import lib.process
import lib.net
import lib.poll
import lib.env
import lib.file
import structures.string
import structures.json
import libs.standard.fs.tempfile
import libs.standard.fs.shutil
import tools.host_tools


struct wd_state:
	process* program
	process* xvfb
	char* display
	int listen_fd
	int fd
	char* dir
	char* sock_path
	char* out_dir
	string_builder* input
	string_builder* stdin_buf
	int stdin_eof
	int next_id
	int timeout_ms
	int failures
	char* error
	# the last raw response line (owned)
	char* line


wd_state* wd


void wd_say(char* text):
	write(1, text, strlen(text))


void wd_note(char* text):
	print_error(c"wdrive: ")
	print_error(text)
	print_error(c"\n")


void wd_set_error(char* text):
	if (wd.error != 0): free(wd.error)
	wd.error = strclone(text)


void wd_cleanup():
	if (wd == 0): return
	if (wd.fd >= 0):
		close(wd.fd)
		wd.fd = 0 - 1
	if (wd.program != 0):
		if (wd.program.reaped == 0):
			# Give a clean exit a moment before forcing it.
			int deadline = process_monotonic_ms() + 1000
			while ((process_try_wait(wd.program) == process_status_running) && (process_monotonic_ms() < deadline)): process_sleep_ms(10)
			if (wd.program.reaped == 0):
				process_kill_group(wd.program, sigkill)
				process_wait(wd.program)
	if (wd.xvfb != 0):
		if (wd.xvfb.reaped == 0):
			process_kill_group(wd.xvfb, sigterm)
			int deadline = process_monotonic_ms() + 2000
			while ((process_try_wait(wd.xvfb) == process_status_running) && (process_monotonic_ms() < deadline)): process_sleep_ms(10)
			if (wd.xvfb.reaped == 0):
				process_kill_group(wd.xvfb, sigkill)
				process_wait(wd.xvfb)
	if (wd.listen_fd >= 0):
		close(wd.listen_fd)
		wd.listen_fd = 0 - 1
	if (wd.dir != 0):
		shutil_rmtree(wd.dir)
		wd.dir = 0


void wd_exit(int status):
	wd_cleanup()
	exit(status)


# ---- I/O pump ------------------------------------------------------------

# Copy what fd has to our stderr; returns 0 (and closes it) at EOF.
int wd_forward(int fd):
	char* buf = cast(char*, malloc(4096))
	int n = read(fd, buf, 4096)
	if (n > 0): write(2, buf, n)
	free(buf)
	if (n <= 0):
		close(fd)
		return 0
	return 1


# Wait up to timeout_ms for the control socket, the program's output
# and (with want_stdin) our stdin, and handle what is ready.
void wd_pump(int timeout_ms, int want_stdin):
	pollfd* fds = pollfd_new_array(4)
	int n = 0
	int sock_at = 0 - 1
	int out_at = 0 - 1
	int err_at = 0 - 1
	int in_at = 0 - 1
	if (wd.fd >= 0):
		sock_at = n
		pollfd_set(fds, n, wd.fd, poll_in)
		n = n + 1
	if ((wd.program != 0) && (wd.program.stdout_fd >= 0)):
		out_at = n
		pollfd_set(fds, n, wd.program.stdout_fd, poll_in)
		n = n + 1
	if ((wd.program != 0) && (wd.program.stderr_fd >= 0)):
		err_at = n
		pollfd_set(fds, n, wd.program.stderr_fd, poll_in)
		n = n + 1
	if (want_stdin && (wd.stdin_eof == 0)):
		in_at = n
		pollfd_set(fds, n, 0, poll_in)
		n = n + 1
	if (n == 0):
		process_sleep_ms(timeout_ms)
		free(fds)
		return
	int ready = poll_wait(fds, n, timeout_ms)
	if (ready > 0):
		if ((out_at >= 0) && (pollfd_at(fds, out_at).revents != 0)):
			if (wd_forward(wd.program.stdout_fd) == 0): wd.program.stdout_fd = 0 - 1
		if ((err_at >= 0) && (pollfd_at(fds, err_at).revents != 0)):
			if (wd_forward(wd.program.stderr_fd) == 0): wd.program.stderr_fd = 0 - 1
		if ((sock_at >= 0) && (pollfd_at(fds, sock_at).revents != 0)):
			char* buf = cast(char*, malloc(65536))
			int k = socket_recv(wd.fd, buf, 65536, 0)
			if (k > 0): string_append_bytes(wd.input, buf, k)
			else:
				close(wd.fd)
				wd.fd = 0 - 1
			free(buf)
		if ((in_at >= 0) && (pollfd_at(fds, in_at).revents != 0)):
			char* buf = cast(char*, malloc(4096))
			int k = read(0, buf, 4096)
			if (k > 0): string_append_bytes(wd.stdin_buf, buf, k)
			else: wd.stdin_eof = 1
			free(buf)
	free(fds)


# The next complete line of s (malloc'd, without its newline), or 0.
char* wd_take_line(string_builder* s):
	for i in range(s.length):
		if (s.data[i] == '\n'):
			char* line = cast(char*, malloc(i + 1))
			for k in range(i): line[k] = s.data[k]
			line[i] = 0
			int rest = s.length - i - 1
			for k in range(rest): s.data[k] = s.data[i + 1 + k]
			s.length = rest
			s.data[rest] = 0
			return line
	return cast(char*, 0)


int wd_member_int(json_value* object, char* key, int def):
	json_value* v = json_object_get(object, key)
	if (v == 0): return def
	if ((v.type == json_type_int()) || (v.type == json_type_bool())): return v.int_value
	if (v.type == json_type_float()): return cast(int, v.float_value)
	return def


char* wd_member_text(json_value* object, char* key):
	json_value* v = json_object_get(object, key)
	if ((v == 0) || (v.type != json_type_string())): return cast(char*, 0)
	return v.string_value


int wd_program_running():
	if (wd.program == 0): return 0
	return process_try_wait(wd.program) == process_status_running


# Send request (its "id" is replaced) and wait for the matching
# response. Returns the parsed response (raw line in wd.line) or 0 with
# wd.error set.
json_value* wd_request(json_value* request, int timeout_ms):
	wd.next_id = wd.next_id + 1
	int id = wd.next_id
	json_object_set(request, c"id", json_int(id))
	if (wd.fd < 0):
		wd_set_error(c"the program closed the control connection")
		return 0
	char* text = json_stringify(request)
	string_builder* sb = string_from(text)
	free(text)
	string_append_char(sb, '\n')
	int sent = 0
	while (sent < sb.length):
		int k = socket_send(wd.fd, sb.data + sent, sb.length - sent, msg_nosignal())
		if (k <= 0):
			string_free(sb)
			wd_set_error(c"cannot write to the program's control connection")
			return 0
		sent = sent + k
	string_free(sb)
	int deadline = process_monotonic_ms() + timeout_ms
	while (1):
		char* line = wd_take_line(wd.input)
		while (line != 0):
			json_value* response = json_parse(line)
			if ((response != 0) && (response.type == json_type_object()) && (wd_member_int(response, c"id", 0 - 1) == id)):
				if (wd.line != 0): free(wd.line)
				wd.line = line
				return response
			if (response != 0): json_free(response)
			free(line)
			line = wd_take_line(wd.input)
		if (wd.fd < 0):
			wd_set_error(c"the program closed the control connection")
			return 0
		if (wd_program_running() == 0):
			string_builder* m = string_from(c"the program exited with status ")
			string_append_int(m, process_decode_status(wd.program.status))
			wd_set_error(m.data)
			string_free(m)
			return 0
		int left = deadline - process_monotonic_ms()
		if (left <= 0):
			wd_set_error(c"timed out waiting for the program")
			return 0
		if (left > 50): left = 50
		wd_pump(left, 0)
	return 0


# ---- startup ---------------------------------------------------------------

int wd_parse_size(char* text, int* w, int* h):
	if (text == 0): return 0
	int i = 0
	int a = 0
	while ((text[i] >= '0') && (text[i] <= '9')):
		a = a * 10 + text[i] - '0'
		i = i + 1
	if ((text[i] != 'x') && (text[i] != 'X')): return 0
	i = i + 1
	int b = 0
	int digits = 0
	while ((text[i] >= '0') && (text[i] <= '9')):
		b = b * 10 + text[i] - '0'
		i = i + 1
		digits = digits + 1
	if ((text[i] != 0) || (a <= 0) || (b <= 0) || (digits == 0)): return 0
	w[0] = a
	h[0] = b
	return 1


# Start Xvfb on the first free display from :90 and wait until it
# accepts connections. Returns 0 when Xvfb is missing or never came up.
int wd_start_xvfb(int screen_w, int screen_h):
	char* xvfb = process_which(c"Xvfb")
	if (xvfb == 0):
		wd_set_error(c"Xvfb is not installed")
		return 0
	string_builder* geometry = string_new()
	string_append_int(geometry, screen_w)
	string_append_char(geometry, 'x')
	string_append_int(geometry, screen_h)
	string_append(geometry, c"x24")
	int attempts = 0
	int n = 90
	while ((n < 400) && (attempts < 8)):
		string_builder* lock = string_from(c"/tmp/.X")
		string_append_int(lock, n)
		string_append(lock, c"-lock")
		string_builder* sock = string_from(c"/tmp/.X11-unix/X")
		string_append_int(sock, n)
		int taken = process_path_readable(lock.data) || process_path_readable(sock.data)
		if (taken == 0):
			attempts = attempts + 1
			string_builder* display = string_from(c":")
			string_append_int(display, n)
			char** argv = strv_new(7)
			strv_set(argv, 0, xvfb)
			strv_set(argv, 1, display.data)
			strv_set(argv, 2, c"-screen")
			strv_set(argv, 3, c"0")
			strv_set(argv, 4, geometry.data)
			strv_set(argv, 5, c"-nolisten")
			strv_set(argv, 6, c"tcp")
			spawn_options* opts = spawn_options_new()
			opts.stdin_mode = process_null
			opts.stdout_mode = process_null
			opts.stderr_mode = process_null
			opts.new_group = 1
			process* p = process_spawn(xvfb, argv, opts)
			if (p != 0):
				int deadline = process_monotonic_ms() + 5000
				while ((process_try_wait(p) == process_status_running) && (process_monotonic_ms() < deadline)):
					int probe = socket_connect_unix_path(sock.data)
					if (probe >= 0):
						close(probe)
						wd.xvfb = p
						wd.display = strclone(display.data)
						return 1
					process_sleep_ms(20)
				if (process_try_wait(p) == process_status_running):
					process_kill_group(p, sigkill)
				process_wait(p)
		n = n + 1
	wd_set_error(c"Xvfb did not start")
	return 0


# Launch command with W_GFX_CONTROL (and DISPLAY) set and wait for it
# to connect. Returns 0 with wd.error set on failure.
int wd_launch(list[char*] command):
	wd.dir = tempfile_mkdtemp_in(c"/tmp", c"wdrive-", c"")
	if (wd.dir == 0):
		wd_set_error(c"cannot create a temporary directory in /tmp")
		return 0
	wd.sock_path = path_join(wd.dir, c"control.sock")
	wd.listen_fd = socket_listen_unix_path(wd.sock_path, 1)
	if (wd.listen_fd < 0):
		wd_set_error(c"cannot listen on the control socket")
		return 0
	char* executable = process_which(command[0])
	if (executable == 0):
		wd_set_error(strjoin(c"program not found: ", command[0]))
		return 0
	char** argv = strv_new(command.length)
	for i in range(command.length): strv_set(argv, i, command[i])
	char** env = env_copy_with(env_current(), c"W_GFX_CONTROL", wd.sock_path)
	if (wd.display != 0): env = env_copy_with(env, c"DISPLAY", wd.display)
	spawn_options* opts = spawn_options_new()
	opts.env = env
	opts.stdin_mode = process_null
	opts.stdout_mode = process_pipe
	opts.stderr_mode = process_pipe
	opts.new_group = 1
	wd.program = process_spawn(executable, argv, opts)
	if (wd.program == 0):
		wd_set_error(strjoin(c"cannot start ", executable))
		return 0
	int deadline = process_monotonic_ms() + wd.timeout_ms
	while (1):
		int revents = poll_single(wd.listen_fd, poll_in, 20)
		if (revents > 0):
			wd.fd = socket_accept_connection(wd.listen_fd)
			if (wd.fd >= 0): return 1
		wd_pump(0, 0)
		if (wd_program_running() == 0):
			string_builder* m = string_from(c"the program exited with status ")
			string_append_int(m, process_decode_status(wd.program.status))
			string_append(m, c" before connecting (no display or no GL?)")
			wd_set_error(m.data)
			string_free(m)
			return 0
		if (process_monotonic_ms() > deadline):
			wd_set_error(c"the program did not connect to W_GFX_CONTROL (does it open a graphics.window?)")
			return 0
	return 0


# ---- steps -------------------------------------------------------------------

# {"step":index,"cmd":cmd, ...the response's fields after its id...}
string_builder* wd_result_begin(int index, char* cmd, json_value* echo_id):
	string_builder* sb = string_from(c"{\"step\":")
	string_append_int(sb, index)
	if (echo_id != 0):
		char* id_text = json_stringify(echo_id)
		string_append(sb, c",\"id\":")
		string_append(sb, id_text)
		free(id_text)
	string_append(sb, c",\"cmd\":")
	json_value* name = json_string(cmd)
	char* name_text = json_stringify(name)
	string_append(sb, name_text)
	free(name_text)
	json_free(name)
	return sb


void wd_result_raw(string_builder* sb, char* line):
	# line is {"id":N,...}: keep what follows the id.
	int i = 0
	while ((line[i] != 0) && (line[i] != ',') && (line[i] != '}')): i = i + 1
	if (line[i] == ','): string_append(sb, line + i)
	else: string_append(sb, c"}")


void wd_result_error(string_builder* sb, char* message):
	string_append(sb, c",\"ok\":false,\"error\":")
	json_value* m = json_string(message)
	char* text = json_stringify(m)
	string_append(sb, text)
	free(text)
	json_free(m)
	string_append(sb, c"}")


int wd_step_timeout(json_value* step):
	json_value* v = json_object_get(step, c"timeout_ms")
	if ((v != 0) && (v.type == json_type_int())): return v.int_value
	return wd.timeout_ms


int wd_hex_digit(int c):
	if ((c >= '0') && (c <= '9')): return c - '0'
	if ((c >= 'a') && (c <= 'f')): return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')): return c - 'A' + 10
	return 0 - 1


# The expected colour: [r,g,b] / [r,g,b,a] or "#rrggbb" / "#rrggbbaa".
# Returns the channel count (3 or 4), 0 when malformed.
int wd_expected_rgba(json_value* step, int* out):
	json_value* v = json_object_get(step, c"rgba")
	if (v == 0): v = json_object_get(step, c"rgb")
	if (v == 0): return 0
	if (v.type == json_type_array()):
		int n = json_array_length(v)
		if ((n != 3) && (n != 4)): return 0
		for i in range(n):
			json_value* c = json_array_get(v, i)
			if (c.type != json_type_int()): return 0
			out[i] = c.int_value
		return n
	if (v.type == json_type_string()):
		char* s = v.string_value
		if (s[0] == '#'): s = s + 1
		int n = strlen(s)
		if ((n != 6) && (n != 8)): return 0
		for i in range(n / 2):
			int hi = wd_hex_digit(s[i * 2])
			int lo = wd_hex_digit(s[i * 2 + 1])
			if ((hi < 0) || (lo < 0)): return 0
			out[i] = hi * 16 + lo
		return n / 2
	return 0


int wd_step_assert_pixel(json_value* step, string_builder* sb):
	int[4] want
	int channels = wd_expected_rgba(step, &want[0])
	if (channels == 0):
		wd_result_error(sb, c"assert_pixel needs rgba as [r,g,b(,a)] or \"#rrggbb\"")
		return 0
	int tolerance = wd_member_int(step, c"tolerance", 0)
	json_value* request = json_object()
	json_object_set(request, c"cmd", json_string(c"pixel"))
	json_object_set(request, c"x", json_int(wd_member_int(step, c"x", 0)))
	json_object_set(request, c"y", json_int(wd_member_int(step, c"y", 0)))
	json_value* response = wd_request(request, wd_step_timeout(step))
	json_free(request)
	if (response == 0):
		wd_result_error(sb, wd.error)
		return 0
	json_value* got = json_object_get(response, c"rgba")
	if ((json_object_get(response, c"ok") == 0) || (json_object_get(response, c"ok").int_value == 0) || (got == 0)):
		wd_result_raw(sb, wd.line)
		json_free(response)
		return 0
	int ok = 1
	for i in range(channels):
		int d = json_array_get(got, i).int_value - want[i]
		if (d < 0): d = 0 - d
		if (d > tolerance): ok = 0
	char* got_text = json_stringify(got)
	if (ok): string_append(sb, c",\"ok\":true")
	else: string_append(sb, c",\"ok\":false,\"error\":\"pixel mismatch\"")
	string_append(sb, c",\"x\":")
	string_append_int(sb, wd_member_int(step, c"x", 0))
	string_append(sb, c",\"y\":")
	string_append_int(sb, wd_member_int(step, c"y", 0))
	string_append(sb, c",\"rgba\":")
	string_append(sb, got_text)
	string_append(sb, c",\"expected\":[")
	for i in range(channels):
		if (i > 0): string_append_char(sb, ',')
		string_append_int(sb, want[i])
	string_append(sb, c"]}")
	free(got_text)
	json_free(response)
	return ok


int wd_text_contains(char* text, char* needle):
	if ((text == 0) || (needle == 0)): return 0
	return ht_contains(text, needle)


# Does node satisfy the selector fields of step (role, name,
# name_contains, value, value_contains, focused, state)?
int wd_node_matches(json_value* node, json_value* step):
	char* role = wd_member_text(step, c"role")
	if ((role != 0) && ((wd_member_text(node, c"role") == 0) || (strcmp(role, wd_member_text(node, c"role")) != 0))): return 0
	char* name = wd_member_text(step, c"name")
	char* node_name = wd_member_text(node, c"name")
	if (node_name == 0): node_name = c""
	if ((name != 0) && (strcmp(name, node_name) != 0)): return 0
	char* name_part = wd_member_text(step, c"name_contains")
	if ((name_part != 0) && (wd_text_contains(node_name, name_part) == 0)): return 0
	char* node_value = wd_member_text(node, c"value")
	if (node_value == 0): node_value = c""
	char* value = wd_member_text(step, c"value")
	if ((value != 0) && (strcmp(value, node_value) != 0)): return 0
	char* value_part = wd_member_text(step, c"value_contains")
	if ((value_part != 0) && (wd_text_contains(node_value, value_part) == 0)): return 0
	if (json_object_get(step, c"focused") != 0):
		if (wd_member_int(step, c"focused", 0) != wd_member_int(node, c"focused", 0)): return 0
	char* state = wd_member_text(step, c"state")
	if (state != 0):
		json_value* states = json_object_get(node, c"states")
		int found = 0
		if (states != 0):
			for i in range(json_array_length(states)):
				json_value* s = json_array_get(states, i)
				if ((s.type == json_type_string()) && (strcmp(s.string_value, state) == 0)): found = 1
		if (found == 0): return 0
	return 1


void wd_find_nodes(json_value* node, json_value* step, list[json_value*] out):
	if ((node == 0) || (node.type != json_type_object())): return
	if (wd_node_matches(node, step)): out.push(node)
	json_value* children = json_object_get(node, c"children")
	if (children == 0): return
	for i in range(json_array_length(children)): wd_find_nodes(json_array_get(children, i), step, out)


# assert_a11y and click_node: fetch the tree and match nodes.
int wd_step_a11y(json_value* step, string_builder* sb, int click):
	json_value* request = json_object()
	json_object_set(request, c"cmd", json_string(c"a11y_tree"))
	json_value* response = wd_request(request, wd_step_timeout(step))
	json_free(request)
	if (response == 0):
		wd_result_error(sb, wd.error)
		return 0
	json_value* tree = json_object_get(response, c"tree")
	if (tree == 0):
		wd_result_raw(sb, wd.line)
		json_free(response)
		return 0
	list[json_value*] matches = new list[json_value*]
	wd_find_nodes(tree, step, matches)
	int ok = 1
	char* error = cast(char*, 0)
	int want = wd_member_int(step, c"count", 0 - 1)
	if (wd_member_int(step, c"absent", 0)):
		if (matches.length != 0):
			ok = 0
			error = c"a matching node is present"
	else if ((want >= 0) && (matches.length != want)):
		ok = 0
		error = c"wrong number of matching nodes"
	else if (matches.length == 0):
		ok = 0
		error = c"no matching node"
	int cx = 0
	int cy = 0
	if (ok && click):
		json_value* bounds = json_object_get(matches[0], c"bounds")
		if ((bounds == 0) || (json_array_length(bounds) != 4)):
			ok = 0
			error = c"the node has no bounds"
		else:
			cx = json_array_get(bounds, 0).int_value + json_array_get(bounds, 2).int_value / 2
			cy = json_array_get(bounds, 1).int_value + json_array_get(bounds, 3).int_value / 2
			json_value* click_request = json_object()
			json_object_set(click_request, c"cmd", json_string(c"click"))
			json_object_set(click_request, c"x", json_int(cx))
			json_object_set(click_request, c"y", json_int(cy))
			json_object_set(click_request, c"button", json_int(wd_member_int(step, c"button", 1)))
			json_object_set(click_request, c"count", json_int(wd_member_int(step, c"count_clicks", 1)))
			json_value* clicked = wd_request(click_request, wd_step_timeout(step))
			json_free(click_request)
			if (clicked == 0):
				ok = 0
				error = wd.error
			else:
				if (wd_member_int(clicked, c"ok", 0) == 0):
					ok = 0
					error = wd_member_text(clicked, c"error")
					if (error == 0): error = c"click failed"
					error = strclone(error)
				json_free(clicked)
	if (ok): string_append(sb, c",\"ok\":true")
	else:
		string_append(sb, c",\"ok\":false,\"error\":")
		json_value* m = json_string(error)
		char* m_text = json_stringify(m)
		string_append(sb, m_text)
		free(m_text)
		json_free(m)
	string_append(sb, c",\"matches\":")
	string_append_int(sb, matches.length)
	if (click && ok):
		string_append(sb, c",\"x\":")
		string_append_int(sb, cx)
		string_append(sb, c",\"y\":")
		string_append_int(sb, cy)
	if (matches.length > 0):
		# The first match, without its subtree.
		json_value* node = json_clone(matches[0])
		if (json_object_has(node, c"children")):
			json_value* children = json_object_get(node, c"children")
			json_object_set(node, c"children_count", json_int(json_array_length(children)))
			json_object_set(node, c"children", json_null())
		char* node_text = json_stringify(node)
		string_append(sb, c",\"node\":")
		string_append(sb, node_text)
		free(node_text)
		json_free(node)
	string_append(sb, c"}")
	list_free[json_value*](matches)
	json_free(response)
	return ok


# Absolute path for a screenshot: relative to --out (or cwd), defaulting
# to shot-<index>.png.
char* wd_shot_path(json_value* step, int index):
	char* path = wd_member_text(step, c"path")
	char* chosen = 0
	if ((path == 0) || (path[0] == 0)):
		string_builder* name = string_from(c"shot-")
		string_append_int(name, index)
		string_append(name, c".png")
		chosen = strclone(name.data)
		string_free(name)
	else: chosen = strclone(path)
	if ((chosen[0] != '/') && (wd.out_dir != 0)): chosen = path_join(wd.out_dir, chosen)
	return tempfile_abspath(chosen)


# Run one step; returns 1 when it passed. The result line goes to stdout.
int wd_step(json_value* step, int index):
	json_value* echo_id = json_object_get(step, c"id")
	char* cmd = wd_member_text(step, c"cmd")
	if (cmd == 0): cmd = c""
	string_builder* sb = wd_result_begin(index, cmd, echo_id)
	int ok = 0
	if (step.type != json_type_object()): wd_result_error(sb, c"a step must be a JSON object")
	else if (cmd[0] == 0): wd_result_error(sb, c"a step needs a cmd")
	else if (strcmp(cmd, c"wait_ms") == 0):
		int ms = wd_member_int(step, c"ms", 0)
		int deadline = process_monotonic_ms() + ms
		while (process_monotonic_ms() < deadline):
			int left = deadline - process_monotonic_ms()
			if (left > 50): left = 50
			if (left > 0): wd_pump(left, 0)
		string_append(sb, c",\"ok\":true}")
		ok = 1
	else if (strcmp(cmd, c"assert_pixel") == 0): ok = wd_step_assert_pixel(step, sb)
	else if (strcmp(cmd, c"assert_a11y") == 0): ok = wd_step_a11y(step, sb, 0)
	else if (strcmp(cmd, c"click_node") == 0): ok = wd_step_a11y(step, sb, 1)
	else:
		json_value* request = json_clone(step)
		json_object_set(request, c"timeout_ms", json_null())
		if (strcmp(cmd, c"screenshot") == 0):
			char* path = wd_shot_path(step, index)
			char* parent = path_dirname(path)
			ht_mkdir(parent)
			json_object_set(request, c"path", json_string(path))
		json_value* response = wd_request(request, wd_step_timeout(step))
		json_free(request)
		if (response == 0): wd_result_error(sb, wd.error)
		else:
			ok = wd_member_int(response, c"ok", 0)
			wd_result_raw(sb, wd.line)
			json_free(response)
	string_append_char(sb, '\n')
	wd_say(sb.data)
	string_free(sb)
	return ok


# ---- driver modes --------------------------------------------------------

void wd_usage():
	print_error(c"usage: wdrive run [--xvfb] [--screen WxH] [--size WxH] [--out DIR] [--timeout-ms N] [--keep-going] [--script FILE | --steps JSON] -- PROGRAM [ARGS...]\n")
	print_error(c"       wdrive serve [--xvfb] [--screen WxH] [--size WxH] [--out DIR] [--timeout-ms N] -- PROGRAM [ARGS...]\n")
	print_error(c"see docs/projects/wdrive.md\n")
	exit(2)


# Steps from a JSON array or NDJSON text.
list[json_value*] wd_parse_steps(char* text):
	list[json_value*] steps = new list[json_value*]
	int i = 0
	while ((text[i] == ' ') || (text[i] == '\n') || (text[i] == '\t') || (text[i] == '\r')): i = i + 1
	if (text[i] == '['):
		json_value* all = json_parse(text)
		if ((all == 0) || (all.type != json_type_array())):
			wd_note(c"the steps are not a valid JSON array")
			exit(2)
		for k in range(json_array_length(all)): steps.push(json_clone(json_array_get(all, k)))
		json_free(all)
		return steps
	string_builder* buf = string_from(text + i)
	string_append_char(buf, '\n')
	char* line = wd_take_line(buf)
	while (line != 0):
		int blank = 1
		for k in range(strlen(line)):
			if ((line[k] != ' ') && (line[k] != '\t') && (line[k] != '\r')): blank = 0
		if (blank == 0):
			json_value* step = json_parse(line)
			if (step == 0):
				wd_note(strjoin(c"not a JSON step: ", line))
				exit(2)
			steps.push(step)
		free(line)
		line = wd_take_line(buf)
	string_free(buf)
	return steps


int main(int argc, int argv):
	wd = new wd_state()
	wd.listen_fd = 0 - 1
	wd.fd = 0 - 1
	wd.input = string_new()
	wd.stdin_buf = string_new()
	wd.timeout_ms = 10000
	char** args = cast(char**, argv)
	if (argc < 2): wd_usage()
	char* mode = args[1]
	int serve = strcmp(mode, c"serve") == 0
	if ((serve == 0) && (strcmp(mode, c"run") != 0)): wd_usage()
	int force_xvfb = 0
	int keep_going = 0
	int screen_w = 1280
	int screen_h = 1024
	int size_w = 0
	int size_h = 0
	char* steps_text = 0
	list[char*] command = new list[char*]
	int i = 2
	while (i < argc):
		char* a = args[i]
		char* next = 0
		if (i + 1 < argc): next = args[i + 1]
		if (strcmp(a, c"--") == 0):
			i = i + 1
			while (i < argc):
				command.push(args[i])
				i = i + 1
			break
		else if (strcmp(a, c"--xvfb") == 0): force_xvfb = 1
		else if (strcmp(a, c"--keep-going") == 0): keep_going = 1
		else if ((strcmp(a, c"--screen") == 0) && (next != 0)):
			if (wd_parse_size(next, &screen_w, &screen_h) == 0): wd_usage()
			i = i + 1
		else if ((strcmp(a, c"--size") == 0) && (next != 0)):
			if (wd_parse_size(next, &size_w, &size_h) == 0): wd_usage()
			i = i + 1
		else if ((strcmp(a, c"--out") == 0) && (next != 0)):
			wd.out_dir = tempfile_abspath(next)
			i = i + 1
		else if ((strcmp(a, c"--timeout-ms") == 0) && (next != 0)):
			wd.timeout_ms = atoi(next)
			if (wd.timeout_ms <= 0): wd_usage()
			i = i + 1
		else if ((strcmp(a, c"--script") == 0) && (next != 0) && (serve == 0)):
			steps_text = file_read_text(next)
			if (steps_text == 0):
				wd_note(strjoin(c"cannot read ", next))
				exit(2)
			i = i + 1
		else if ((strcmp(a, c"--steps") == 0) && (next != 0) && (serve == 0)):
			steps_text = next
			i = i + 1
		else: wd_usage()
		i = i + 1
	if (command.length == 0): wd_usage()
	list[json_value*] steps = new list[json_value*]
	if (steps_text != 0): steps = wd_parse_steps(steps_text)
	if (wd.out_dir != 0): ht_mkdir(wd.out_dir)

	char* display = env_get(c"DISPLAY")
	if (force_xvfb || (display == 0) || (display[0] == 0)):
		if (wd_start_xvfb(screen_w, screen_h) == 0):
			wd_note(wd.error)
			wd_exit(3)
	if (wd_launch(command) == 0):
		wd_note(wd.error)
		wd_exit(3)

	# Step 0: the handshake (after the optional --size resize).
	if (size_w > 0):
		json_value* resize = json_object()
		json_object_set(resize, c"cmd", json_string(c"resize"))
		json_object_set(resize, c"w", json_int(size_w))
		json_object_set(resize, c"h", json_int(size_h))
		json_value* resized = wd_request(resize, wd.timeout_ms)
		json_free(resize)
		if ((resized == 0) || (wd_member_int(resized, c"ok", 0) == 0)):
			if (resized == 0): wd_note(wd.error)
			else: wd_note(c"--size: the window could not be resized")
			wd_exit(3)
		json_free(resized)
	json_value* hello = json_object()
	json_object_set(hello, c"cmd", json_string(c"hello"))
	int hello_ok = wd_step(hello, 0)
	json_free(hello)
	if (hello_ok == 0): wd_exit(3)

	int failed = 0
	int closed = 0
	if (serve):
		int index = 0
		while (1):
			char* line = wd_take_line(wd.stdin_buf)
			if (line != 0):
				int blank = 1
				for k in range(strlen(line)):
					if ((line[k] != ' ') && (line[k] != '\t') && (line[k] != '\r')): blank = 0
				if (blank == 0):
					index = index + 1
					json_value* step = json_parse(line)
					if (step == 0):
						string_builder* sb = wd_result_begin(index, c"", cast(json_value*, 0))
						wd_result_error(sb, c"not a JSON object")
						string_append_char(sb, '\n')
						wd_say(sb.data)
						string_free(sb)
					else:
						# A failed step is the client's to judge; serve only
						# fails when the program dies unasked.
						int passed = wd_step(step, index)
						char* cmd = wd_member_text(step, c"cmd")
						if (passed && (cmd != 0) && (strcmp(cmd, c"close") == 0)): closed = 1
						json_free(step)
				free(line)
				continue
			if (wd.stdin_eof): break
			if (wd_program_running() == 0):
				if (closed == 0):
					wd_note(c"the program exited")
					failed = 1
				break
			wd_pump(100, 1)
	else:
		for k in range(steps.length):
			if (wd_step(steps[k], k + 1) == 0):
				failed = failed + 1
				if (keep_going == 0): break
	# Ask for a clean exit; cleanup kills whatever is left.
	if ((wd.fd >= 0) && wd_program_running()):
		json_value* close_request = json_object()
		json_object_set(close_request, c"cmd", json_string(c"close"))
		json_value* closed = wd_request(close_request, 2000)
		json_free(close_request)
		if (closed != 0): json_free(closed)
	if (failed > 0):
		if (serve == 0):
			string_builder* m = string_new()
			string_append_int(m, failed)
			string_append(m, c" step(s) failed")
			wd_note(m.data)
		wd_exit(1)
	wd_exit(0)
	return 0
