# wbuild: binary=wdbg_web arch=x64 staged dep=wdbg_ui
/*
wdbg_web: a browser front end for wdbg (issue #98).

Usage:
  wdbg_web [options] <file.w> [-- program args...]
  wdbg_web [options] --core <core> [--binary <exe>]

Starts an https server on 127.0.0.1 and prints the URL to open, with a
one-time access code in its query string:

  https://127.0.0.1:PORT/?code=CODE

The page it serves is a W program: tools/wdbg_ui.w, compiled to wasm
against graphics/ui and drawn with WebGL on a full-window canvas
(tools/wdbg_web/index.html is only the host glue). Its layout follows
OllyDbg: a CPU view (disassembly, registers + locals, memory dump,
stack), source / log / call stack / breakpoint views, a toolbar, a
command line and a status bar.

Transport: the server runs bin/wdbg as a child process over pipes and
speaks its existing text command loop, which is fully scriptable and
prints a "wdbg> " prompt before reading each command even when stdin is
not a tty. A command is answered by everything wdbg prints up to its
next prompt; nothing in debugger/*.w changes to support this front end,
and the same HTTP API serves scripts (curl) as well as the page.
With --core, wcore --json processes a core dump once at startup and the
page shows its report (signal, registers, symbolized backtrace) instead
of a live session.

HTTP API (JSON unless noted; every request needs the access code):
  GET  /api/state            {"state", "program", "files", "has_core"}
  POST /api/cmd              body = one wdbg command line; runs it and
                             returns {"state", "output"} once wdbg
                             prompts again or ~2s pass ("running")
  GET  /api/poll             output produced since the last call
  GET  /api/inspect          l / bt / i locals / i args / i b / i w /
                             r / st / disas outputs in one round trip
                             (stopped sessions only)
  POST /api/query            body = one inspection command (x, disas,
                             p, bt, l, list, r, st, i); its output alone,
                             kept out of the program-output stream
  GET  /api/source?file=P    source text of P (text/plain), only for
                             files wdbg's 'i files' lists
  POST /api/restart          kill the session and start a fresh one
  GET  /api/core             the wcore --json report (--core mode)
State is "stopped" (at a wdbg prompt), "running", "exited" or "none".

Security: binds to 127.0.0.1 unless --bind says otherwise. Every
request must carry the access code, as ?code=, an X-Wdbg-Code header,
or the wdbg_code cookie the first page load sets (HttpOnly,
SameSite=Strict, so another site cannot ride it). By default the TLS
certificate is a throwaway self-signed ECDSA P-256 one minted at startup
(libs/standard/net/selfsigned.w), held in memory only; the browser
shows its usual warning for it. --cert/--key serve a real key pair.

Concurrency: http_server.w's own accept loop serves one connection at a
time, start to finish, which a browser defeats immediately (it opens
speculative connections and keeps idle ones alive). This tool therefore
drives the server with its own poll(2) loop over the listener, every
open connection and wdbg's pipes, and serves one request from whichever
connection is readable. TLS handshakes and request parsing still block,
but only once the peer has already started sending.

Options:
  --port N        listen port (default 0: pick a free one)
  --bind IP       listen address (default 127.0.0.1)
  --http          plain http instead of https
  --cert F --key F  serve this PEM cert chain / P-256 key instead of a
                  generated self-signed pair
  --code C        use this access code instead of a random one
  --no-break-start  do not stop before main (default: stop there, so
                  breakpoints can be set first)
  --wdbg PATH     debugger binary (default: wdbg next to this binary)
  --wcore PATH    core processor (default: wcore next to this binary)
  --static DIR    page files (default: ../tools/wdbg_web from this binary;
                  the wasm host glue is served from DIR/../web)
  --ui PATH       the W UI module (default: wdbg_ui.wasm next to this binary)
  --max-requests N  exit after serving N requests (tests)

This is a leaf tool (not in the seed's import graph); built as a 64-bit
binary because the pure-W TLS handshake crypto is its hot path.
*/
import lib.lib
import lib.str
import lib.net
import lib.poll
import lib.process
import lib.file
import lib.path
import lib.stat
import structures.string
import libs.standard.crypto.random
import libs.standard.crypto.base64
import libs.standard.net.tls
import libs.standard.net.selfsigned
import libs.standard.web.connection
import libs.standard.web.http_server


# ---- configuration -------------------------------------------------------------

char* ww_bind_ip
int ww_port
int ww_use_tls
char* ww_cert_path
char* ww_key_path
char* ww_code
int ww_break_start
char* ww_wdbg_path
char* ww_wcore_path
char* ww_static_dir
char* ww_web_dir         # tools/web: the shared wasm host glue
char* ww_ui_wasm_path    # the W UI module (tools/wdbg_ui.w, compiled to wasm)
char* ww_program
char* ww_core_path
char* ww_binary_path
list[char*] ww_program_args
int ww_max_requests
int ww_requests_served


int ww_state_none():
	return 0
int ww_state_stopped():
	return 1
int ww_state_running():
	return 2
int ww_state_exited():
	return 3


char* ww_state_name(int st):
	if (st == ww_state_stopped()):
		return c"stopped"
	if (st == ww_state_running()):
		return c"running"
	if (st == ww_state_exited()):
		return c"exited"
	return c"none"


void ww_json_string(string_builder* s, char* text);


# ---- the wdbg session ----------------------------------------------------------

process* ww_proc
int ww_state
string_builder* ww_out      # output not yet handed to the page
list[char*] ww_files        # 'i files', absolute paths, filled at the first stop
char* ww_core_json          # wcore --json output (--core mode), or 0


# The largest amount of unread program output kept; older bytes are dropped.
int ww_out_cap():
	return 1048576


char* ww_prompt():
	return c"wdbg> "


void ww_out_append(char* data, int n):
	string_append_bytes(ww_out, data, n)
	if (ww_out.length > ww_out_cap()):
		int drop = ww_out.length - ww_out_cap() / 2
		string_builder* kept = string_new()
		string_append(kept, c"[... earlier output dropped ...]\n")
		string_append_bytes(kept, ww_out.data + drop, ww_out.length - drop)
		string_free(ww_out)
		ww_out = kept


# If the buffered output ends with wdbg's prompt, strip it and report 1.
int ww_out_take_prompt():
	int plen = strlen(ww_prompt())
	if (ww_out.length < plen):
		return 0
	if (ends_with(ww_out.data, ww_prompt()) == 0):
		return 0
	ww_out.length = ww_out.length - plen
	ww_out.data[ww_out.length] = 0
	return 1


# Hand over (and clear) the buffered output. The caller frees it.
char* ww_out_drain():
	char* text = strclone(ww_out.data)
	string_clear(ww_out)
	return text


void ww_close_fd(int fd):
	if (fd >= 0):
		close(fd)


void ww_session_reap():
	if (ww_proc == 0):
		return
	ww_close_fd(ww_proc.stdin_fd)
	ww_close_fd(ww_proc.stdout_fd)
	ww_close_fd(ww_proc.stderr_fd)
	ww_proc.stdin_fd = -1
	ww_proc.stdout_fd = -1
	ww_proc.stderr_fd = -1
	int status = process_wait_or_kill(ww_proc, 2000)
	string_builder* note = string_new()
	string_append(note, c"\n[wdbg exited with status ")
	string_append_int(note, status)
	string_append(note, c"]\n")
	ww_out_append(note.data, note.length)
	string_free(note)
	process_free(ww_proc)
	ww_proc = 0
	ww_state = ww_state_exited()


# Read whatever one of wdbg's pipes has. Returns the byte count, 0 at EOF.
int ww_read_pipe(int fd):
	char* buf = malloc(4096)
	int n = read(fd, buf, 4096)
	if (n > 0):
		ww_out_append(buf, n)
	free(buf)
	if (n < 0):
		return 0
	return n


# Move wdbg's output into ww_out for up to timeout_ms, returning as soon
# as wdbg prompts (state becomes stopped) or exits. A timeout of 0 just
# drains what is already there.
void ww_pump(int timeout_ms):
	if (ww_proc == 0):
		return
	int deadline = process_monotonic_ms() + timeout_ms
	while (ww_proc != 0):
		int wait = deadline - process_monotonic_ms()
		if (wait < 0):
			wait = 0
		pollfd* fds = pollfd_new_array(2)
		pollfd_set(fds, 0, ww_proc.stdout_fd, poll_in())
		pollfd_set(fds, 1, ww_proc.stderr_fd, poll_in())
		int nready = poll_wait(fds, 2, wait)
		int out_ev = pollfd_at(fds, 0).revents
		int err_ev = pollfd_at(fds, 1).revents
		free(cast(char*, fds))
		if (nready <= 0):
			return
		if (err_ev != 0):
			ww_read_pipe(ww_proc.stderr_fd)
		if (out_ev != 0):
			if (ww_read_pipe(ww_proc.stdout_fd) == 0):
				ww_session_reap()
				return
			if (ww_out_take_prompt()):
				ww_state = ww_state_stopped()
				return


# Send one command line and wait (bounded) for the next prompt.
void ww_send_command(char* line, int timeout_ms):
	string_builder* cmd = string_from(line)
	string_append_char(cmd, 10)
	write(ww_proc.stdin_fd, cmd.data, cmd.length)
	string_free(cmd)
	ww_state = ww_state_running()
	ww_pump(timeout_ms)


# Run a command whose output the page wants separately from the program
# output stream (the inspect panes). Only valid while stopped.
char* ww_query(char* line):
	char* before = ww_out_drain()
	ww_send_command(line, 5000)
	char* result = ww_out_drain()
	ww_out_append(before, strlen(before))
	free(before)
	return result


void ww_load_files():
	if (ww_files.length > 0):
		return
	if (ww_state != ww_state_stopped()):
		return
	char* text = ww_query(c"i files")
	list[char*] lines = split(text, 10)
	for char* ln in lines:
		if (starts_with(ln, c"/")):
			ww_files.push(strclone(ln))
		free(ln)
	list_free[char*](lines)
	free(text)


char* ww_dirname_of_self():
	char* buf = malloc(4096)
	int n = file_readlink(c"/proc/self/exe", buf, 4095)
	if (n <= 0):
		free(buf)
		return strclone(c"bin")
	buf[n] = 0
	char* dir = path_dirname(buf)
	free(buf)
	return dir


int ww_session_start():
	list[char*] args = new list[char*]
	args.push(ww_wdbg_path)
	args.push(ww_program)
	if (ww_break_start):
		args.push(c"--break_start")
	args.push(c"--break_end")
	for char* a in ww_program_args:
		args.push(a)
	char** argv = strv_new(args.length + 1)
	int i = 0
	while (i < args.length):
		strv_set(argv, i, args[i])
		i = i + 1
	strv_set(argv, args.length, 0)
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_pipe()
	opts.stdout_mode = process_pipe()
	opts.stderr_mode = process_pipe()
	ww_proc = process_spawn(ww_wdbg_path, argv, opts)
	free(cast(char*, opts))
	free(cast(char*, argv))
	list_free[char*](args)
	if (ww_proc == 0):
		ww_state = ww_state_none()
		return 0
	ww_state = ww_state_running()
	# Compiling the program in-process takes a moment; wait for the
	# first stop (or exit) so the page starts with a real state.
	ww_pump(60000)
	ww_load_files()
	return 1


void ww_session_kill():
	if (ww_proc == 0):
		return
	process_kill(ww_proc, sigkill())
	ww_session_reap()


# The page may show the source files a core report's frames name.
void ww_core_collect_files():
	char* key = c"\"file\":\""
	char* p = ww_core_json
	int at = index_of(p, key)
	while (at >= 0):
		p = p + at + strlen(key)
		int n = 0
		while ((p[n] != 0) && (p[n] != '"') && (p[n] != 92)):
			n = n + 1
		char* f = substring(p, 0, n)
		int seen = 0
		for char* g in ww_files:
			if (strcmp(g, f) == 0):
				seen = 1
		if (seen):
			free(f)
		else:
			ww_files.push(f)
		at = index_of(p, key)


void ww_run_core():
	list[char*] args = new list[char*]
	args.push(ww_wcore_path)
	args.push(c"--json")
	args.push(ww_core_path)
	if (ww_binary_path != 0):
		args.push(ww_binary_path)
	char** argv = strv_new(args.length + 1)
	int i = 0
	while (i < args.length):
		strv_set(argv, i, args[i])
		i = i + 1
	strv_set(argv, args.length, 0)
	process_result* r = process_run(ww_wcore_path, argv, 0, c"", 60000)
	free(cast(char*, argv))
	list_free[char*](args)
	if (r == 0):
		ww_core_json = strclone(c"{\"error\": \"could not run wcore\"}")
		return
	string_builder* sb = string_new()
	if ((r.status == 0) && (strlen(r.stdout_text) > 0)):
		string_append(sb, r.stdout_text)
	else:
		string_append(sb, c"{\"error\": ")
		ww_json_string(sb, r.stderr_text)
		string_append(sb, c"}")
	ww_core_json = strclone(sb.data)
	string_free(sb)
	process_result_free(r)
	ww_core_collect_files()


# ---- JSON / HTTP helpers -------------------------------------------------------

int ww_hex_digit(int v):
	if (v < 10):
		return '0' + v
	return 'a' + v - 10


void ww_json_string(string_builder* s, char* text):
	string_append_char(s, '"')
	int i = 0
	while (text[i] != 0):
		int ch = text[i] & 255
		if (ch == '"'):
			string_append(s, c"\\\"")
		else if (ch == 92):
			string_append(s, c"\\\\")
		else if (ch == 10):
			string_append(s, c"\\n")
		else if (ch == 9):
			string_append(s, c"\\t")
		else if (ch < 32):
			string_append(s, c"\\u00")
			string_append_char(s, ww_hex_digit(ch >> 4))
			string_append_char(s, ww_hex_digit(ch & 15))
		else if (ch == 127):
			string_append(s, c"\\u007f")
		else:
			string_append_char(s, ch)
		i = i + 1
	string_append_char(s, '"')


void ww_json_field(string_builder* s, char* name, char* value, int comma):
	if (comma):
		string_append(s, c", ")
	ww_json_string(s, name)
	string_append(s, c": ")
	ww_json_string(s, value)


void ww_reply_json(RequestContext* rc, int status, string_builder* s):
	request_context_set_header(rc, c"Cache-Control", c"no-store")
	request_context_json(rc, status, s.data)
	string_free(s)


void ww_reply_error(RequestContext* rc, int status, char* message):
	string_builder* s = string_new()
	string_append(s, c"{")
	ww_json_field(s, c"error", message, 0)
	string_append(s, c"}")
	ww_reply_json(rc, status, s)


# Constant-time comparison of a presented code with the real one.
int ww_code_matches(char* given):
	if (given == 0):
		return 0
	int n = strlen(ww_code)
	if (strlen(given) != n):
		return 0
	int diff = 0
	for i in range(n):
		diff = diff | ((given[i] ^ ww_code[i]) & 255)
	return diff == 0


# The value of cookie name in a Cookie header, malloc'd, or 0.
char* ww_cookie_value(char* header, char* name):
	if (header == 0):
		return 0
	int nlen = strlen(name)
	int i = 0
	while (header[i] != 0):
		while ((header[i] == ' ') || (header[i] == ';')):
			i = i + 1
		int start = i
		while ((header[i] != 0) && (header[i] != ';')):
			i = i + 1
		if ((i - start > nlen) && (header[start + nlen] == '=')):
			int same = 1
			for k in range(nlen):
				if (header[start + k] != name[k]):
					same = 0
			if (same):
				return substring(header, start + nlen + 1, i)
	return 0


# 1 when the request carries the access code (query, header or cookie).
int ww_authorized(RequestContext* rc):
	char* q = request_query_param(rc, c"code")
	int ok = ww_code_matches(q)
	if (q != 0):
		free(q)
	if (ok):
		return 1
	if (ww_code_matches(request_context_header(rc, c"x-wdbg-code"))):
		return 1
	char* ck = ww_cookie_value(request_context_header(rc, c"cookie"), c"wdbg_code")
	ok = ww_code_matches(ck)
	if (ck != 0):
		free(ck)
	return ok


char* ww_content_type(char* path):
	if (ends_with(path, c".html")):
		return c"text/html; charset=utf-8"
	if (ends_with(path, c".js") || ends_with(path, c".mjs")):
		return c"text/javascript; charset=utf-8"
	if (ends_with(path, c".css")):
		return c"text/css; charset=utf-8"
	if (ends_with(path, c".svg")):
		return c"image/svg+xml"
	if (ends_with(path, c".png")):
		return c"image/png"
	if (ends_with(path, c".wasm")):
		return c"application/wasm"
	if (ends_with(path, c".json")):
		return c"application/json"
	return c"application/octet-stream"


# A static path is served only when every character is from a small
# safe set and it never names a parent directory.
int ww_safe_static_path(char* p):
	if (index_of(p, c"..") >= 0):
		return 0
	int i = 0
	while (p[i] != 0):
		int ch = p[i]
		int ok = isalnum(ch) || (ch == '/') || (ch == '.') || (ch == '_') || (ch == '-')
		if (ok == 0):
			return 0
		i = i + 1
	return 1


# Read a whole file as bytes. Returns the malloc'd buffer (length in
# *out_len), or 0.
char* ww_read_file(char* path, int* out_len):
	int fd = open(path, 0, 0)
	if (fd < 0):
		return 0
	string_builder* sb = string_new()
	char* buf = malloc(65536)
	int n = read(fd, buf, 65536)
	while (n > 0):
		string_append_bytes(sb, buf, n)
		n = read(fd, buf, 65536)
	free(buf)
	close(fd)
	*out_len = sb.length
	char* data = sb.data
	free(cast(char*, sb))
	return data


void ww_serve_static(RequestContext* rc, char* path):
	char* rel = path
	if (strcmp(path, c"/") == 0):
		rel = c"/index.html"
	if (ww_safe_static_path(rel) == 0):
		request_context_text(rc, 404, c"not found\n")
		return
	# Three roots: the W UI module (a build output, next to this
	# binary), the shared wasm host glue under /web/ (tools/web), and
	# the page itself (tools/wdbg_web).
	char* full = 0
	if (strcmp(rel, c"/wdbg_ui.wasm") == 0):
		full = strclone(ww_ui_wasm_path)
	else if (starts_with(rel, c"/web/")):
		full = strjoin(ww_web_dir, rel + 4)
	else:
		full = strjoin(ww_static_dir, rel)
	int len = 0
	char* data = ww_read_file(full, &len)
	if (data == 0):
		free(full)
		request_context_text(rc, 404, c"not found\n")
		return
	request_context_set_status(rc, 200)
	request_context_set_header(rc, c"Content-Type", ww_content_type(full))
	request_context_set_header(rc, c"Cache-Control", c"no-store")
	request_context_write_body(rc, data, len)
	free(data)
	free(full)


# ---- API handlers --------------------------------------------------------------

void ww_api_state(RequestContext* rc):
	ww_pump(0)
	string_builder* s = string_new()
	string_append(s, c"{")
	ww_json_field(s, c"state", ww_state_name(ww_state), 0)
	char* prog = ww_program
	if (prog == 0):
		prog = c""
	ww_json_field(s, c"program", prog, 1)
	string_append(s, c", \"has_core\": ")
	if (ww_core_json != 0):
		string_append(s, c"true")
	else:
		string_append(s, c"false")
	string_append(s, c", \"files\": [")
	int i = 0
	while (i < ww_files.length):
		if (i > 0):
			string_append(s, c", ")
		ww_json_string(s, ww_files[i])
		i = i + 1
	string_append(s, c"]}")
	ww_reply_json(rc, 200, s)


void ww_reply_state_output(RequestContext* rc):
	char* out = ww_out_drain()
	string_builder* s = string_new()
	string_append(s, c"{")
	ww_json_field(s, c"state", ww_state_name(ww_state), 0)
	ww_json_field(s, c"output", out, 1)
	string_append(s, c"}")
	free(out)
	ww_reply_json(rc, 200, s)


void ww_api_cmd(RequestContext* rc):
	if (ww_state != ww_state_stopped()):
		ww_reply_error(rc, 409, c"the debugger is not stopped at a prompt")
		return
	# One line only: anything after the first newline is ignored, so a
	# request cannot smuggle a second command into wdbg.
	char* body = request_context_body(rc)
	int n = 0
	while ((body[n] != 0) && (body[n] != 10) && (body[n] != 13)):
		n = n + 1
	char* line = substring(body, 0, n)
	ww_send_command(line, 2000)
	free(line)
	ww_load_files()
	ww_reply_state_output(rc)


void ww_api_poll(RequestContext* rc):
	ww_pump(0)
	ww_reply_state_output(rc)


void ww_inspect_field(string_builder* s, char* name, char* cmd, int comma):
	char* text = ww_query(cmd)
	ww_json_field(s, name, text, comma)
	free(text)


void ww_api_inspect(RequestContext* rc):
	if (ww_state != ww_state_stopped()):
		ww_reply_error(rc, 409, c"the debugger is not stopped at a prompt")
		return
	string_builder* s = string_new()
	string_append(s, c"{")
	ww_inspect_field(s, c"where", c"l", 0)
	ww_inspect_field(s, c"backtrace", c"bt", 1)
	ww_inspect_field(s, c"locals", c"i locals", 1)
	ww_inspect_field(s, c"args", c"i args", 1)
	ww_inspect_field(s, c"breakpoints", c"i b", 1)
	ww_inspect_field(s, c"watchpoints", c"i w", 1)
	ww_inspect_field(s, c"registers", c"r", 1)
	ww_inspect_field(s, c"stack", c"st", 1)
	ww_inspect_field(s, c"disas", c"disas", 1)
	string_append(s, c"}")
	ww_reply_json(rc, 200, s)


# 1 when line starts with one of wdbg's inspection-only commands (no
# execution, no state change), the only ones /api/query runs.
int ww_query_allowed(char* line):
	char* words = c"x disas p print bt backtrace l list r registers st stack i info"
	list[char*] allowed = split(words, ' ')
	int n = 0
	while ((line[n] != 0) && (line[n] != ' ')):
		n = n + 1
	char* first = substring(line, 0, n)
	int ok = 0
	for char* w in allowed:
		if (strcmp(w, first) == 0):
			ok = 1
		free(w)
	list_free[char*](allowed)
	free(first)
	return ok


# Run one inspection command and return its output on its own, without
# mixing it into the program-output stream /api/cmd and /api/poll carry
# (the W UI's memory dump and code-bytes panes use this).
void ww_api_query(RequestContext* rc):
	if (ww_state != ww_state_stopped()):
		ww_reply_error(rc, 409, c"the debugger is not stopped at a prompt")
		return
	char* body = request_context_body(rc)
	int n = 0
	while ((body[n] != 0) && (body[n] != 10) && (body[n] != 13)):
		n = n + 1
	char* line = substring(body, 0, n)
	if (ww_query_allowed(line) == 0):
		free(line)
		ww_reply_error(rc, 400, c"/api/query runs inspection commands only (x, disas, p, bt, l, list, r, st, i)")
		return
	char* out = ww_query(line)
	free(line)
	string_builder* s = string_new()
	string_append(s, c"{")
	ww_json_field(s, c"state", ww_state_name(ww_state), 0)
	ww_json_field(s, c"output", out, 1)
	string_append(s, c"}")
	free(out)
	ww_reply_json(rc, 200, s)


void ww_api_source(RequestContext* rc):
	char* file = request_query_param(rc, c"file")
	if (file == 0):
		ww_reply_error(rc, 400, c"missing ?file=")
		return
	int allowed = 0
	for char* f in ww_files:
		if (strcmp(f, file) == 0):
			allowed = 1
	if ((ww_program != 0) && (strcmp(file, ww_program) == 0)):
		allowed = 1
	if (allowed == 0):
		free(file)
		ww_reply_error(rc, 403, c"not one of the program's source files")
		return
	int len = 0
	char* data = ww_read_file(file, &len)
	free(file)
	if (data == 0):
		ww_reply_error(rc, 404, c"cannot read that file")
		return
	request_context_set_status(rc, 200)
	request_context_set_header(rc, c"Content-Type", c"text/plain; charset=utf-8")
	request_context_set_header(rc, c"Cache-Control", c"no-store")
	request_context_write_body(rc, data, len)
	free(data)


void ww_api_restart(RequestContext* rc):
	if (ww_program == 0):
		ww_reply_error(rc, 400, c"no program to debug (started with --core only)")
		return
	ww_session_kill()
	string_clear(ww_out)
	ww_session_start()
	ww_reply_state_output(rc)


void ww_api_core(RequestContext* rc):
	if (ww_core_json == 0):
		ww_reply_error(rc, 404, c"not started with --core")
		return
	request_context_set_header(rc, c"Cache-Control", c"no-store")
	request_context_json(rc, 200, ww_core_json)


# The single route: authorization first, then dispatch on the path.
void ww_handle(RequestContext* rc, void* user_data):
	char* method = request_context_method(rc)
	char* path = request_context_path(rc)
	if (ww_authorized(rc) == 0):
		request_context_text(rc, 403, c"wdbg_web: missing or wrong access code; open the URL wdbg_web printed\n")
		return
	# Remember the code for the rest of this browser session.
	string_builder* cookie = string_from(c"wdbg_code=")
	string_append(cookie, ww_code)
	string_append(cookie, c"; Path=/; HttpOnly; SameSite=Strict")
	if (ww_use_tls):
		string_append(cookie, c"; Secure")
	request_context_set_header(rc, c"Set-Cookie", cookie.data)
	string_free(cookie)
	request_context_set_header(rc, c"X-Content-Type-Options", c"nosniff")

	int is_get = strcmp(method, c"GET") == 0
	int is_post = strcmp(method, c"POST") == 0
	if (starts_with(path, c"/api/") == 0):
		if (is_get):
			ww_serve_static(rc, path)
		else:
			ww_reply_error(rc, 405, c"method not allowed")
		return
	if (is_get && (strcmp(path, c"/api/state") == 0)):
		ww_api_state(rc)
	else if (is_post && (strcmp(path, c"/api/cmd") == 0)):
		ww_api_cmd(rc)
	else if (is_get && (strcmp(path, c"/api/poll") == 0)):
		ww_api_poll(rc)
	else if (is_get && (strcmp(path, c"/api/inspect") == 0)):
		ww_api_inspect(rc)
	else if (is_post && (strcmp(path, c"/api/query") == 0)):
		ww_api_query(rc)
	else if (is_get && (strcmp(path, c"/api/source") == 0)):
		ww_api_source(rc)
	else if (is_post && (strcmp(path, c"/api/restart") == 0)):
		ww_api_restart(rc)
	else if (is_get && (strcmp(path, c"/api/core") == 0)):
		ww_api_core(rc)
	else:
		ww_reply_error(rc, 404, c"no such endpoint")


# ---- the poll-driven server loop -----------------------------------------------

struct ww_conn:
	int fd
	ConnectionContext* cc     # 0 until the TLS handshake (if any) is done
	int last_ms


list[ww_conn*] ww_conns


# Connections idle longer than this are closed.
int ww_idle_ms():
	return 120000


int ww_max_conns():
	return 32


void ww_conn_close(ww_conn* k):
	if (k.cc != 0):
		connection_context_destroy(k.cc)
	else:
		close(k.fd)
	free(cast(char*, k))


# 1 when a request's bytes are already buffered past the socket (so
# poll would not report them).
int ww_conn_buffered(ww_conn* k):
	if (k.cc == 0):
		return 0
	wstream* r = k.cc.reader
	if (r.position < r.limit):
		return 1
	tls_conn* t = k.cc.tls
	if (t != 0):
		if (t.app_pos < t.app_len):
			return 1
	return 0


# Serve one request on k. Returns 1 to keep the connection open.
int ww_serve_one(ServerContext* s, ww_conn* k):
	ConnectionContext* c = k.cc
	ServerRequest* req = server_read_request(c)
	if (req == 0):
		return 0
	if (req.error != 0):
		server_write_error(c, req.error)
		server_request_free(req)
		return 0
	RequestContext* rc = request_context_new(req, c)
	ww_handle(rc, 0)
	int ok = request_context_flush(rc)
	int keep = rc.keep_alive
	request_context_free(rc)
	ww_requests_served = ww_requests_served + 1
	return ok && keep


# The connection is readable: finish its handshake or serve requests.
# Returns 1 to keep it.
int ww_conn_ready(ServerContext* s, ww_conn* k):
	k.last_ms = process_monotonic_ms()
	if (k.cc == 0):
		tls_conn* tls = 0
		if (ww_use_tls):
			tls = tls_accept(k.fd, s.tls_cfg)
			if (tls == 0):
				return 0
		k.cc = connection_context_new(k.fd, s.timeout_ms, tls)
		if (ww_conn_buffered(k) == 0):
			if (ww_use_tls):
				return 1
	int keep = ww_serve_one(s, k)
	while (keep && ww_conn_buffered(k)):
		keep = ww_serve_one(s, k)
	return keep


void ww_accept(ServerContext* s):
	sockaddr_in peer
	int fd = socket_accept_connection_from(s.listener_fd, &peer)
	if (fd < 0):
		return
	socket_set_recv_timeout(fd, s.timeout_ms)
	socket_set_send_timeout(fd, s.timeout_ms)
	if (ww_conns.length >= ww_max_conns()):
		# Make room by dropping the least recently used connection.
		int oldest = 0
		int i = 1
		while (i < ww_conns.length):
			if (ww_conns[i].last_ms < ww_conns[oldest].last_ms):
				oldest = i
			i = i + 1
		ww_conn_close(ww_conns[oldest])
		ww_conns.remove(oldest)
	ww_conn* k = new ww_conn()
	k.fd = fd
	k.cc = 0
	k.last_ms = process_monotonic_ms()
	ww_conns.push(k)


int ww_done():
	return (ww_max_requests > 0) && (ww_requests_served >= ww_max_requests)


void ww_serve_forever(ServerContext* s):
	while (ww_done() == 0):
		int npipes = 0
		if ((ww_proc != 0) && (ww_state == ww_state_running())):
			npipes = 2
		int n = 1 + ww_conns.length + npipes
		pollfd* fds = pollfd_new_array(n)
		pollfd_set(fds, 0, s.listener_fd, poll_in())
		int i = 0
		while (i < ww_conns.length):
			pollfd_set(fds, 1 + i, ww_conns[i].fd, poll_in())
			i = i + 1
		if (npipes > 0):
			pollfd_set(fds, n - 2, ww_proc.stdout_fd, poll_in())
			pollfd_set(fds, n - 1, ww_proc.stderr_fd, poll_in())
		int nready = poll_wait(fds, n, 1000)
		int now = process_monotonic_ms()
		if (nready > 0):
			if (npipes > 0):
				if ((pollfd_at(fds, n - 2).revents != 0) || (pollfd_at(fds, n - 1).revents != 0)):
					ww_pump(0)
			# Walk the connections back to front so removal keeps the
			# remaining indexes (and their pollfd slots) aligned.
			i = ww_conns.length - 1
			while (i >= 0):
				if ((pollfd_at(fds, 1 + i).revents != 0) && (ww_done() == 0)):
					if (ww_conn_ready(s, ww_conns[i]) == 0):
						ww_conn_close(ww_conns[i])
						ww_conns.remove(i)
				i = i - 1
			if (pollfd_at(fds, 0).revents != 0):
				ww_accept(s)
		free(cast(char*, fds))
		i = ww_conns.length - 1
		while (i >= 0):
			if (now - ww_conns[i].last_ms > ww_idle_ms()):
				ww_conn_close(ww_conns[i])
				ww_conns.remove(i)
			i = i - 1


# ---- startup ---------------------------------------------------------------------

void ww_usage():
	println2(c"usage: wdbg_web [--port N] [--bind IP] [--http] [--cert F --key F] [--code C]")
	println2(c"                [--no-break-start] [--wdbg P] [--wcore P] [--static D]")
	println2(c"                <file.w> [-- args...]")
	println2(c"   or: wdbg_web [options] --core <core> [--binary <exe>]")


# Ignore SIGPIPE: a write to a dead wdbg's stdin must fail, not kill us.
void ww_ignore_sigpipe():
	int* act = malloc(5 * __word_size__)
	act[0] = 1
	act[1] = 0
	act[2] = 0
	act[3] = 0
	act[4] = 0
	rt_sigaction(13, act, 0)
	free(cast(char*, act))


char* ww_absolute(char* p):
	if (p[0] == '/'):
		return strclone(p)
	char* cwd = malloc(4096)
	if (getcwd(cwd, 4096) <= 0):
		free(cwd)
		return strclone(p)
	char* full = path_join(cwd, p)
	free(cwd)
	return full


char* ww_arg(int argv, int i):
	char** slot = argv + i * __word_size__
	return *slot


int main(int argc, int argv):
	ww_bind_ip = c"127.0.0.1"
	ww_port = 0
	ww_use_tls = 1
	ww_break_start = 1
	ww_program_args = new list[char*]
	ww_files = new list[char*]
	ww_conns = new list[ww_conn*]
	ww_out = string_new()
	int i = 1
	while (i < argc):
		char* a = ww_arg(argv, i)
		int has_next = i + 1 < argc
		if (strcmp(a, c"--") == 0):
			i = i + 1
			while (i < argc):
				ww_program_args.push(ww_arg(argv, i))
				i = i + 1
		else if (strcmp(a, c"--http") == 0):
			ww_use_tls = 0
		else if (strcmp(a, c"--no-break-start") == 0):
			ww_break_start = 0
		else if (has_next && (strcmp(a, c"--port") == 0)):
			i = i + 1
			ww_port = atoi(ww_arg(argv, i))
		else if (has_next && (strcmp(a, c"--bind") == 0)):
			i = i + 1
			ww_bind_ip = ww_arg(argv, i)
		else if (has_next && (strcmp(a, c"--cert") == 0)):
			i = i + 1
			ww_cert_path = ww_arg(argv, i)
		else if (has_next && (strcmp(a, c"--key") == 0)):
			i = i + 1
			ww_key_path = ww_arg(argv, i)
		else if (has_next && (strcmp(a, c"--code") == 0)):
			i = i + 1
			ww_code = ww_arg(argv, i)
		else if (has_next && (strcmp(a, c"--wdbg") == 0)):
			i = i + 1
			ww_wdbg_path = ww_arg(argv, i)
		else if (has_next && (strcmp(a, c"--wcore") == 0)):
			i = i + 1
			ww_wcore_path = ww_arg(argv, i)
		else if (has_next && (strcmp(a, c"--ui") == 0)):
			i = i + 1
			ww_ui_wasm_path = ww_arg(argv, i)
		else if (has_next && (strcmp(a, c"--static") == 0)):
			i = i + 1
			ww_static_dir = ww_arg(argv, i)
		else if (has_next && (strcmp(a, c"--core") == 0)):
			i = i + 1
			ww_core_path = ww_arg(argv, i)
		else if (has_next && (strcmp(a, c"--binary") == 0)):
			i = i + 1
			ww_binary_path = ww_arg(argv, i)
		else if (has_next && (strcmp(a, c"--max-requests") == 0)):
			i = i + 1
			ww_max_requests = atoi(ww_arg(argv, i))
		else if ((a[0] != '-') && (ww_program == 0)):
			ww_program = ww_absolute(a)
		else:
			ww_usage()
			return 2
		i = i + 1
	if ((ww_program == 0) && (ww_core_path == 0)):
		ww_usage()
		return 2
	if ((ww_cert_path == 0) != (ww_key_path == 0)):
		println2(c"wdbg_web: --cert and --key go together")
		return 2

	char* self_dir = ww_dirname_of_self()
	if (ww_wdbg_path == 0):
		ww_wdbg_path = path_join(self_dir, c"wdbg")
	if (ww_wcore_path == 0):
		ww_wcore_path = path_join(self_dir, c"wcore")
	if (ww_static_dir == 0):
		ww_static_dir = path_join(self_dir, c"../tools/wdbg_web")
	if (ww_web_dir == 0):
		ww_web_dir = path_join(ww_static_dir, c"../web")
	if (ww_ui_wasm_path == 0):
		ww_ui_wasm_path = path_join(self_dir, c"wdbg_ui.wasm")
	if (path_exists(ww_ui_wasm_path) == 0):
		print2(c"wdbg_web: warning: UI module not found: ")
		println2(ww_ui_wasm_path)
		println2(c"(build it with ./wbuild wdbg_web, or pass --ui <path>)")
	if (path_exists(ww_static_dir) == 0):
		print2(c"wdbg_web: UI directory not found: ")
		println2(ww_static_dir)
		println2(c"(pass --static <dir>)")
		return 1
	if ((ww_program != 0) && (path_exists(ww_wdbg_path) == 0)):
		print2(c"wdbg_web: debugger not found: ")
		println2(ww_wdbg_path)
		println2(c"(build it with ./wbuild wdbg, or pass --wdbg <path>)")
		return 1

	if (ww_code == 0):
		char* raw = malloc(16)
		random_bytes(raw, 16)
		ww_code = hex_encode(raw, 16)
		free(raw)
	ww_ignore_sigpipe()

	ServerContext* s = server_context_new(ww_bind_ip, ww_port, 0, 0)
	if (ww_use_tls):
		server_context_set_tls(s, ww_cert_path, ww_key_path)
	if (server_context_bind(s) == 0):
		print2(c"wdbg_web: cannot listen on ")
		print2(ww_bind_ip)
		print2(c":")
		println2(itoa(ww_port))
		return 1
	char* host = ww_bind_ip
	if (strcmp(host, c"0.0.0.0") == 0):
		host = c"127.0.0.1"
	if (ww_use_tls && (ww_cert_path == 0)):
		char* cert_pem = 0
		char* key_pem = 0
		if (selfsigned_p256_generate(c"wdbg_web", c"localhost", ip4_from_string(host), &cert_pem, &key_pem) == 0):
			println2(c"wdbg_web: could not generate a TLS certificate")
			return 1
		s.tls_cfg.test_cert_pem = cert_pem
		s.tls_cfg.test_cert_pem_len = strlen(cert_pem)
		s.tls_cfg.test_key_pem = key_pem
		s.tls_cfg.test_key_pem_len = strlen(key_pem)

	if (ww_core_path != 0):
		ww_run_core()
	if (ww_program != 0):
		if (ww_session_start() == 0):
			print2(c"wdbg_web: could not start ")
			println2(ww_wdbg_path)
			return 1

	string_builder* url = string_new()
	if (ww_use_tls):
		string_append(url, c"https://")
	else:
		string_append(url, c"http://")
	string_append(url, host)
	string_append(url, c":")
	string_append_int(url, server_context_port(s))
	string_append(url, c"/?code=")
	string_append(url, ww_code)
	println(url.data)
	print2(c"wdbg_web: serving ")
	if (ww_program != 0):
		print2(ww_program)
	else:
		print2(ww_core_path)
	print2(c" -- open ")
	println2(url.data)
	if (ww_use_tls && (ww_cert_path == 0)):
		println2(c"wdbg_web: the certificate is self-signed, so the browser will warn once; accept it to continue")
	string_free(url)

	ww_serve_forever(s)
	ww_session_kill()
	server_context_free(s)
	return 0
