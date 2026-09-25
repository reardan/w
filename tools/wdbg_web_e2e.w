# wbuild: target=wdbg_web_test tag=tests dep=wdbg_web dep=wdbg dep=wcore input=tools/wdbg_web_e2e.w input=tools/wdbg_web/ input=tests/debug_fixture.w input=tests/crash_null_deref_fixture.w input=tools/web/
# wbuild: step="bin/wv2 x64 tests/crash_null_deref_fixture.w -o bin/wdbg_web_crash64"
# wbuild: step="bin/wv2 x64 tools/wdbg_web_e2e.w -o bin/wdbg_web_e2e"
# wbuild: step="bin/wdbg_web_e2e" expect_stdout="wdbg_web test OK"
/*
End-to-end test for the web debugger (tools/wdbg_web.w, issue #98).

Starts bin/wdbg_web on a kernel-assigned port against the wdbg debug
fixture, reads the URL it prints, and drives the HTTP API the page
uses: access-code enforcement (query, header, cookie), static files and
path sanitizing, the source whitelist, a breakpoint set / hit / inspect
/ step / continue cycle through /api/cmd and /api/inspect, and restart.
A second instance runs over https with the in-memory self-signed
certificate to cover the TLS path end to end (the client skips chain
verification, since nothing trusts that certificate, but the real
handshake, CertificateVerify signature and Finished MAC all run). A
third serves a W_CRASH_DUMP core through --core and wcore.

Prerequisites, built by the wdbg_web_test target before this runs:
bin/wdbg_web, bin/wdbg, bin/wcore, bin/wdbg_web_crash64.
*/
import lib.lib
import lib.str
import lib.env
import lib.poll
import lib.process
import lib.file
import structures.string
import libs.standard.web.http_client


int we_failures


void we_check(int ok, char* what):
	if (ok == 0):
		print2(c"FAIL: ")
		println2(what)
		we_failures = we_failures + 1


# One running wdbg_web instance.
struct we_server:
	process* p
	char* base      # "http[s]://127.0.0.1:PORT"


# Start bin/wdbg_web with extra args; returns once it printed its URL.
we_server* we_start(list[char*] extra):
	list[char*] args = new list[char*]
	args.push(c"bin/wdbg_web")
	args.push(c"--code")
	args.push(c"e2ecode")
	args.push(c"--port")
	args.push(c"0")
	for char* a in extra:
		args.push(a)
	char** argv = strv_new(args.length + 1)
	int i = 0
	while (i < args.length):
		strv_set(argv, i, args[i])
		i = i + 1
	strv_set(argv, args.length, 0)
	spawn_options* opts = spawn_options_new()
	opts.stdout_mode = process_pipe()
	process* p = process_spawn(c"bin/wdbg_web", argv, opts)
	if (p == 0):
		println2(c"FAIL: cannot spawn bin/wdbg_web")
		exit(1)
	# The first stdout line is the URL. Startup compiles the debuggee
	# (and mints a P-256 certificate for https), so allow a long wait.
	string_builder* line = string_new()
	char* ch = malloc(1)
	int deadline = process_monotonic_ms() + 180000
	int done = 0
	while (done == 0):
		int wait = deadline - process_monotonic_ms()
		if (wait <= 0):
			println2(c"FAIL: wdbg_web printed no URL")
			exit(1)
		if (poll_single(p.stdout_fd, poll_in(), wait) <= 0):
			continue
		if (read(p.stdout_fd, ch, 1) != 1):
			println2(c"FAIL: wdbg_web exited before printing its URL")
			exit(1)
		if (ch[0] == 10):
			done = 1
		else:
			string_append_char(line, ch[0])
	free(ch)
	print(c"url: ")
	println(line.data)
	we_check(contains(line.data, c"/?code=e2ecode"), c"URL carries the access code")
	we_server* s = new we_server()
	s.p = p
	s.base = substring(line.data, 0, index_of(line.data, c"/?code="))
	string_free(line)
	return s


void we_stop(we_server* s):
	process_kill(s.p, sigkill())
	process_wait(s.p)
	process_free(s.p)


# Issue one request. code_mode: 0 none, 1 header, 2 cookie.
http_response* we_request(we_server* s, char* method, char* path, char* body, int code_mode):
	char* url = strjoin(s.base, path)
	http_req* req = http_req_new(method, url)
	req.timeout_ms = 120000
	req.tls_handshake_timeout_ms = 120000
	req.tls_insecure_skip_verify = 1
	if (code_mode == 1):
		http_req_add_header(req, c"X-Wdbg-Code", c"e2ecode")
	if (code_mode == 2):
		http_req_add_header(req, c"Cookie", c"other=1; wdbg_code=e2ecode")
	if (body != 0):
		req.body = body
		req.body_len = strlen(body)
		http_req_add_header(req, c"Content-Type", c"text/plain")
	http_response* resp = http_request(req)
	http_req_free(req)
	free(url)
	if (resp.error != 0):
		print2(c"request error: ")
		print2(method)
		print2(c" ")
		print2(path)
		print2(c": ")
		println2(resp.error_message)
	return resp


# A request that must succeed; returns its body (malloc'd).
char* we_ok(we_server* s, char* method, char* path, char* body):
	http_response* r = we_request(s, method, path, body, 1)
	string_builder* what = string_from(method)
	string_append(what, c" ")
	string_append(what, path)
	string_append(what, c" -> 200")
	we_check(r.status == 200, what.data)
	string_free(what)
	char* text = strclone(r.body)
	http_response_free(r)
	return text


int we_status(we_server* s, char* method, char* path, int code_mode):
	http_response* r = we_request(s, method, path, 0, code_mode)
	int st = r.status
	http_response_free(r)
	return st


char* we_fixture_abs():
	char* cwd = malloc(4096)
	getcwd(cwd, 4096)
	char* full = strjoin(cwd, c"/tests/debug_fixture.w")
	free(cwd)
	return full


void we_plain_http_session():
	list[char*] extra = new list[char*]
	extra.push(c"--http")
	extra.push(c"tests/debug_fixture.w")
	we_server* s = we_start(extra)
	char* fixture = we_fixture_abs()

	# Access code enforcement.
	we_check(we_status(s, c"GET", c"/api/state", 0) == 403, c"no code -> 403")
	we_check(we_status(s, c"GET", c"/api/state?code=wrong", 0) == 403, c"wrong code -> 403")
	we_check(we_status(s, c"GET", c"/api/state?code=e2ecode", 0) == 200, c"query code -> 200")
	we_check(we_status(s, c"GET", c"/api/state", 2) == 200, c"cookie code -> 200")

	# The page, its cookie, and static path sanitizing.
	http_response* page = we_request(s, c"GET", c"/?code=e2ecode", 0, 0)
	we_check(page.status == 200, c"GET / -> 200")
	we_check(contains(page.body, c"<title>wdbg</title>"), c"index.html served")
	we_check(contains(http_response_header(page, c"set-cookie"), c"wdbg_code=e2ecode"), c"page sets the code cookie")
	we_check(contains(http_response_header(page, c"set-cookie"), c"HttpOnly"), c"cookie is HttpOnly")
	http_response_free(page)
	we_check(we_status(s, c"GET", c"/wdbg_bridge.mjs", 1) == 200, c"wdbg_bridge.mjs served")
	we_check(we_status(s, c"GET", c"/web/webgl_env.mjs", 1) == 200, c"shared wasm host glue served")
	we_check(we_status(s, c"GET", c"/wdbg_ui.wasm", 1) == 200, c"the W UI module served")
	we_check(we_status(s, c"GET", c"/..%2f..%2fw.w", 1) == 404, c"encoded parent path -> 404")
	we_check(we_status(s, c"GET", c"/no_such_file.js", 1) == 404, c"missing static file -> 404")
	we_check(we_status(s, c"DELETE", c"/wdbg_bridge.mjs", 1) == 405, c"non-GET static -> 405")

	# Initial state: stopped before main, the program's files listed.
	char* st = we_ok(s, c"GET", c"/api/state", 0)
	we_check(contains(st, c"\"state\": \"stopped\""), c"session starts stopped")
	we_check(contains(st, c"debug_fixture.w"), c"state lists the program")
	we_check(contains(st, c"structures/prelude.w"), c"state lists imported files")
	free(st)

	# Sources: the program's files only.
	string_builder* src_path = string_from(c"/api/source?file=")
	string_append(src_path, fixture)
	char* src = we_ok(s, c"GET", src_path.data, 0)
	we_check(contains(src, c"println(c\"after breakpoint\")"), c"program source served")
	free(src)
	string_free(src_path)
	we_check(we_status(s, c"GET", c"/api/source?file=/etc/passwd", 1) == 403, c"foreign file -> 403")

	# Breakpoint, continue, inspect, step, print.
	string_builder* bcmd = string_from(c"b ")
	string_append(bcmd, fixture)
	string_append(bcmd, c":8")
	char* out = we_ok(s, c"POST", c"/api/cmd", bcmd.data)
	we_check(contains(out, c"breakpoint 1 at main"), c"b file:line sets breakpoint 1")
	free(out)
	string_free(bcmd)
	out = we_ok(s, c"POST", c"/api/cmd", c"c")
	we_check(contains(out, c"hit breakpoint 1"), c"continue hits the breakpoint")
	we_check(contains(out, c"\"state\": \"stopped\""), c"stopped at the breakpoint")
	free(out)
	out = we_ok(s, c"GET", c"/api/inspect", 0)
	we_check(contains(out, c"\"where\": \"main ("), c"inspect where names main")
	we_check(contains(out, c"debug_fixture.w:8"), c"inspect where is line 8")
	we_check(contains(out, c"x = 3"), c"inspect locals shows x = 3")
	we_check(contains(out, c"#0  main"), c"inspect backtrace")
	we_check(contains(out, c"hits: 1"), c"inspect breakpoints shows the hit count")
	free(out)
	out = we_ok(s, c"POST", c"/api/query", c"r")
	we_check(contains(out, c"eip: 0x"), c"query r returns registers")
	free(out)
	we_check(we_status(s, c"POST", c"/api/query", 1) == 400, c"query refuses non-inspection commands")
	out = we_ok(s, c"POST", c"/api/cmd", c"n")
	we_check(contains(out, c"debug_fixture.w:9"), c"next moves to line 9")
	free(out)
	out = we_ok(s, c"POST", c"/api/cmd", c"p x * 2\nq")
	we_check(contains(out, c"= 14"), c"print evaluates an expression")
	we_check(contains(out, c"\"state\": \"stopped\""), c"a second line in the body is not run")
	free(out)
	# Continue through the 'debugger' statement and the --break_end stop
	# until the program exits, collecting everything the page would show.
	string_builder* all = string_new()
	int rounds = 0
	int exited = 0
	while ((exited == 0) && (rounds < 6)):
		out = we_ok(s, c"POST", c"/api/cmd", c"c")
		string_append(all, out)
		exited = contains(out, c"\"state\": \"exited\"")
		free(out)
		rounds = rounds + 1
	out = we_ok(s, c"GET", c"/api/poll", 0)
	string_append(all, out)
	we_check(contains(out, c"\"state\": \"exited\""), c"session exits")
	free(out)
	we_check(contains(all.data, c"after breakpoint"), c"program output reaches the page")
	we_check(contains(all.data, c"debuggee main returned 7"), c"program runs to completion")
	string_free(all)
	we_check(we_status(s, c"POST", c"/api/cmd", 1) == 409, c"command after exit -> 409")

	# Restart brings a fresh stopped session.
	out = we_ok(s, c"POST", c"/api/restart", c"")
	we_check(contains(out, c"\"state\": \"stopped\""), c"restart stops before main again")
	free(out)
	we_check(we_status(s, c"GET", c"/api/nope", 1) == 404, c"unknown endpoint -> 404")
	we_check(we_status(s, c"GET", c"/api/core", 1) == 404, c"no core -> 404")
	we_stop(s)
	free(fixture)


void we_https_session():
	list[char*] extra = new list[char*]
	extra.push(c"tests/debug_fixture.w")
	we_server* s = we_start(extra)
	we_check(starts_with(s.base, c"https://127.0.0.1:"), c"https by default")
	char* st = we_ok(s, c"GET", c"/api/state", 0)
	we_check(contains(st, c"\"state\": \"stopped\""), c"https state")
	free(st)
	we_stop(s)


void we_core_session():
	char* dump = c"bin/wdbg_web_crash.core"
	unlink(dump)
	char** argv = strv_new(2)
	strv_set(argv, 0, c"bin/wdbg_web_crash64")
	strv_set(argv, 1, 0)
	spawn_options* opts = spawn_options_new()
	opts.env = env_copy_with(env_current(), c"W_CRASH_DUMP", dump)
	process_result* r = process_run(c"bin/wdbg_web_crash64", argv, opts, 0, 120000)
	we_check(r.status != 0, c"crash fixture crashes")
	process_result_free(r)

	list[char*] extra = new list[char*]
	extra.push(c"--http")
	extra.push(c"--core")
	extra.push(dump)
	we_server* s = we_start(extra)
	char* st = we_ok(s, c"GET", c"/api/state", 0)
	we_check(contains(st, c"\"has_core\": true"), c"core mode state")
	we_check(contains(st, c"\"state\": \"none\""), c"core mode has no live session")
	we_check(contains(st, c"crash_null_deref_fixture.w"), c"core frames' files are viewable")
	free(st)
	char* core = we_ok(s, c"GET", c"/api/core", 0)
	we_check(contains(core, c"\"signal_name\""), c"core report has the signal")
	we_check(contains(core, c"crash_deep"), c"core report symbolizes the fault")
	free(core)
	we_stop(s)
	unlink(dump)


int main(int argc, int argv):
	we_plain_http_session()
	we_https_session()
	we_core_session()
	if (we_failures > 0):
		print2(itoa(we_failures))
		println2(c" check(s) failed")
		return 1
	println(c"wdbg_web test OK")
	return 0
