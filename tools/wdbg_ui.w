# wbuild: binary=wdbg_ui arch=wasm out=bin/wdbg_ui.wasm
# wbuild: target=wdbg_ui_test tag=tests dep=wdbg_ui dep=wdbg_web dep=wdbg dep=wrun input=tools/wdbg_web/ input=tools/web/webgl_env.mjs input=tools/web/wasi_lite.mjs input=tests/debug_fixture.w
# wbuild: step="bin/wrun node tools/wdbg_web/run_ui_test.mjs" expect_stdout="wdbg_ui test OK"
/*
wdbg_ui: the web debugger's front end, written in W (issue #98).

Compiled to wasm against graphics/ui and drawn with WebGL on a
full-window canvas; tools/wdbg_web.w serves it (as /wdbg_ui.wasm) next
to the JSON API it talks to, and tools/wdbg_web/index.html is only the
host glue (canvas, input queue, and the "wdbg" import module below that
turns HTTP requests into polled handles, since a wasm module cannot
block on the network).

	./wbuild wdbg_web
	./bin/wdbg_web prog.w     # prints https://127.0.0.1:PORT/?code=...

The layout follows OllyDbg 1.x:

  toolbar     Restart / Run F9 / Step into F7 / Step over F8 /
              Till return Ctrl+F9, then the view letters
              L (log) C (CPU) K (call stack) B (breakpoints) S (source)
  caption     the MDI child title bar of the current view
  CPU view    four panes: disassembly (address, hex bytes, instruction,
              comment; the EIP row inverted) top-left, registers with
              EFLAGS bits plus locals and arguments top-right (changed
              values in red), the hex/ASCII memory dump bottom-left and
              the stack bottom-right (ESP/EBP marked)
  command     the command-line bar: any wdbg command, plus OllyDbg's
              "D <addr>" to move the dump
  status bar  the last event on the left, the yellow "Paused" box on
              the right

Keys: Alt+L/C/K/B/S switch views (typed letters go to the command
line), F2 toggles a breakpoint on the selected source line, F7/F8/F9 and
Ctrl+F9 run, Ctrl+F2 restarts, Up/Down/PgUp/PgDn move the selection in
the focused pane, Enter runs the command line (or, in the call stack,
selects the frame), Delete removes the selected breakpoint in B.
Double-clicking a stack or register value follows it in the dump.

All wdbg output arrives as text (the server fronts wdbg's command loop
unchanged); this file parses it. Text in the panes is drawn in fixed
cells, so columns line up the way OllyDbg's monospace font does, even
though the bundled face (Liberation Sans) is proportional.
*/
import lib.lib
import lib.str
import lib.container
import structures.string
import graphics.gl
import graphics.window
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets


# ---- host imports: HTTP as polled handles --------------------------------------

c_lib "wdbg"

# Start a request to this page's origin (the access code is added by the
# host). Returns a handle.
extern int wdbg_http_start(char* method, char* path, char* body)
# 0 while pending, the HTTP status when done, -1 on a network error.
extern int wdbg_http_status(int id)
extern int wdbg_http_length(int id)
# Copy up to max body bytes to dst; returns the count.
extern int wdbg_http_read(int id, char* dst, int max)
extern void wdbg_http_free(int id)


# ---- small text helpers --------------------------------------------------------

list[char*] od_split_lines(char* text):
	list[char*] out = new list[char*]
	int start = 0
	int i = 0
	while (text[i] != 0):
		if (text[i] == 10):
			out.push(substring(text, start, i))
			start = i + 1
		i = i + 1
	if (i > start):
		out.push(substring(text, start, i))
	return out


void od_free_lines(list[char*] lines):
	for char* s in lines:
		free(s)
	list_free[char*](lines)


char* od_hex8(int v):
	char* s = malloc(9)
	int i = 7
	while (i >= 0):
		int d = v & 15
		if (d < 10):
			s[i] = '0' + d
		else:
			s[i] = 'A' + d - 10
		v = v >> 4
		i = i - 1
	s[8] = 0
	return s


char* od_hex2(int v):
	char* s = malloc(3)
	char* digits = c"0123456789ABCDEF"
	s[0] = digits[(v >> 4) & 15]
	s[1] = digits[v & 15]
	s[2] = 0
	return s


# Parse the first "0x..." hex number in s (0 when there is none).
int od_parse_hex_at(char* s, int* found):
	int i = index_of(s, c"0x")
	if (i < 0):
		*found = 0
		return 0
	*found = 1
	int v = 0
	i = i + 2
	int more = 1
	while (more):
		int c = s[i]
		if ((c >= '0') && (c <= '9')):
			v = (v << 4) | (c - '0')
		else if ((c >= 'a') && (c <= 'f')):
			v = (v << 4) | (c - 'a' + 10)
		else if ((c >= 'A') && (c <= 'F')):
			v = (v << 4) | (c - 'A' + 10)
		else:
			more = 0
		i = i + 1
	return v


char* od_trim(char* s):
	int a = 0
	while ((s[a] == ' ') || (s[a] == 9)):
		a = a + 1
	int b = strlen(s)
	while ((b > a) && ((s[b - 1] == ' ') || (s[b - 1] == 9) || (s[b - 1] == 13))):
		b = b - 1
	return substring(s, a, b)


# Tabs to spaces (4-column stops), for fixed-cell drawing.
char* od_expand_tabs(char* s):
	string_builder* b = string_new()
	int col = 0
	int i = 0
	while (s[i] != 0):
		if (s[i] == 9):
			string_append_char(b, ' ')
			col = col + 1
			while ((col % 4) != 0):
				string_append_char(b, ' ')
				col = col + 1
		else:
			string_append_char(b, s[i])
			col = col + 1
		i = i + 1
	char* out = strclone(b.data)
	string_free(b)
	return out


int od_hex_digit_value(int c):
	if ((c >= '0') && (c <= '9')):
		return c - '0'
	if ((c >= 'a') && (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')):
		return c - 'A' + 10
	return 0


# The string value of "key" in a flat JSON object, unescaped and
# malloc'd ("" when absent). Enough JSON for the server's replies.
char* od_json_get(char* json, char* key):
	string_builder* pat = string_from(c"\"")
	string_append(pat, key)
	string_append(pat, c"\": \"")
	int at = index_of(json, pat.data)
	int plen = pat.length
	string_free(pat)
	if (at < 0):
		return strclone(c"")
	char* p = json + at + plen
	string_builder* out = string_new()
	int i = 0
	while ((p[i] != 0) && (p[i] != '"')):
		if ((p[i] == 92) && (p[i + 1] != 0)):
			i = i + 1
			int c = p[i]
			if (c == 'n'):
				string_append_char(out, 10)
			else if (c == 't'):
				string_append_char(out, 9)
			else if (c == 'r'):
				string_append_char(out, 13)
			else if (c == 'u'):
				int v = 0
				int k = 1
				while ((k <= 4) && (p[i + k] != 0)):
					v = (v << 4) | od_hex_digit_value(p[i + k])
					k = k + 1
				i = i + 4
				if ((v >= 32) && (v < 127)):
					string_append_char(out, v)
				else if ((v == 9) || (v == 10)):
					string_append_char(out, v)
				else:
					string_append_char(out, '?')
			else:
				string_append_char(out, c)
		else:
			string_append_char(out, p[i])
		i = i + 1
	char* text = strclone(out.data)
	string_free(out)
	return text


# 1 when "key": true appears in json.
int od_json_true(char* json, char* key):
	string_builder* pat = string_from(c"\"")
	string_append(pat, key)
	string_append(pat, c"\": true")
	int at = index_of(json, pat.data)
	string_free(pat)
	return at >= 0


# The strings of a flat JSON array value ("key": ["a", "b"]).
list[char*] od_json_strings(char* json, char* key):
	list[char*] out = new list[char*]
	string_builder* pat = string_from(c"\"")
	string_append(pat, key)
	string_append(pat, c"\": [")
	int at = index_of(json, pat.data)
	int plen = pat.length
	string_free(pat)
	if (at < 0):
		return out
	char* p = json + at + plen
	int i = 0
	while ((p[i] != 0) && (p[i] != ']')):
		if (p[i] == '"'):
			int start = i + 1
			i = start
			while ((p[i] != 0) && (p[i] != '"')):
				i = i + 1
			out.push(substring(p, start, i))
		i = i + 1
	return out


# The file-name part of a path (a pointer into it, not a copy).
char* od_path_tail(char* p):
	int i = strlen(p)
	while ((i > 0) && (p[i - 1] != '/')):
		i = i - 1
	return p + i


# ---- debugger model ------------------------------------------------------------

struct od_insn:
	int addr
	char* text        # "mov eax,3"
	int current       # the "=>" row
	int is_label      # "main:" header row
	char* label


struct od_bp:
	int n
	char* file
	int line
	char* text


struct od_source:
	char* path
	list[char*] lines


char* od_state          # "stopped" / "running" / "exited" / "none"
char* od_program
char* od_src_file      # the file the source view shows
list[char*] od_files
int od_has_core

# where
char* od_where_func
char* od_where_file
int od_where_line
char* od_where_text     # the "-> 8  x = x + 4" line

int[10] od_regs
int[10] od_prev_regs
int od_regs_valid
list[char*] od_locals
list[char*] od_args
list[char*] od_backtrace
list[od_bp*] od_bps
list[od_insn*] od_disas
list[char*] od_stack    # raw "0xADDR: 0xVAL" lines
list[char*] od_log
list[od_source*] od_sources

# code bytes for the disassembly pane
int od_code_base
char* od_code_bytes
int od_code_len

# the memory dump
int od_dump_addr
char* od_dump_bytes
int od_dump_len
int od_dump_valid


char* od_reg_name(int i):
	if (i == 0):
		return c"EAX"
	if (i == 1):
		return c"ECX"
	if (i == 2):
		return c"EDX"
	if (i == 3):
		return c"EBX"
	if (i == 4):
		return c"ESP"
	if (i == 5):
		return c"EBP"
	if (i == 6):
		return c"ESI"
	if (i == 7):
		return c"EDI"
	if (i == 8):
		return c"EIP"
	return c"EFL"


void od_log_add(char* text):
	list[char*] lines = od_split_lines(text)
	for char* ln in lines:
		od_log.push(od_expand_tabs(ln))
		free(ln)
	list_free[char*](lines)
	while (od_log.length > 4000):
		free(od_log[0])
		od_log.remove(0)


void od_set_str(char** slot, char* value):
	if (*slot != 0):
		free(*slot)
	*slot = value


void od_parse_where(char* text):
	od_set_str(&od_where_func, strclone(c""))
	od_set_str(&od_where_file, strclone(c""))
	od_set_str(&od_where_text, strclone(c""))
	od_where_line = 0
	list[char*] lines = od_split_lines(text)
	for char* ln in lines:
		int open = index_of(ln, c" (/")
		if ((open > 0) && ends_with(ln, c")") && (od_where_line == 0)):
			int colon = strlen(ln) - 2
			while ((colon > open) && (ln[colon] != ':')):
				colon = colon - 1
			od_set_str(&od_where_func, substring(ln, 0, open))
			od_set_str(&od_where_file, substring(ln, open + 2, colon))
			char* num = substring(ln, colon + 1, strlen(ln) - 1)
			od_where_line = atoi(num)
			free(num)
		else if (starts_with(ln, c"->")):
			od_set_str(&od_where_text, od_expand_tabs(ln))
		free(ln)
	list_free[char*](lines)


void od_parse_registers(char* text):
	int i = 0
	while (i < 10):
		od_prev_regs[i] = od_regs[i]
		i = i + 1
	list[char*] lines = od_split_lines(text)
	char* names = c"eax ecx edx ebx esp ebp esi edi eip eflags"
	list[char*] want = split(names, ' ')
	for char* ln in lines:
		int k = 0
		while (k < 10):
			string_builder* pfx = string_from(want[k])
			string_append(pfx, c":")
			if (starts_with(ln, pfx.data)):
				int found = 0
				od_regs[k] = od_parse_hex_at(ln, &found)
			string_free(pfx)
			k = k + 1
		free(ln)
	list_free[char*](lines)
	od_free_lines(want)
	if (od_regs_valid == 0):
		i = 0
		while (i < 10):
			od_prev_regs[i] = od_regs[i]
			i = i + 1
	od_regs_valid = 1


void od_parse_breakpoints(char* text):
	for od_bp* b in od_bps:
		free(b.file)
		free(b.text)
		free(cast(char*, b))
	list_free[od_bp*](od_bps)
	od_bps = new list[od_bp*]
	list[char*] lines = od_split_lines(text)
	for char* ln in lines:
		if (starts_with(ln, c"breakpoint ")):
			int open = index_of(ln, c" (/")
			int close = index_of(ln, c")")
			if ((open > 0) && (close > open)):
				int colon = close - 1
				while ((colon > open) && (ln[colon] != ':')):
					colon = colon - 1
				od_bp* b = new od_bp()
				char* num = substring(ln, 11, index_of(ln, c" at "))
				b.n = atoi(num)
				free(num)
				b.file = substring(ln, open + 2, colon)
				char* lnum = substring(ln, colon + 1, close)
				b.line = atoi(lnum)
				free(lnum)
				b.text = strclone(ln)
				od_bps.push(b)
		free(ln)
	list_free[char*](lines)


void od_parse_disas(char* text):
	for od_insn* d in od_disas:
		free(d.text)
		if (d.label != 0):
			free(d.label)
		free(cast(char*, d))
	list_free[od_insn*](od_disas)
	od_disas = new list[od_insn*]
	list[char*] lines = od_split_lines(text)
	for char* ln in lines:
		od_insn* d = new od_insn()
		d.label = 0
		d.is_label = 0
		d.addr = 0
		d.current = starts_with(ln, c"=>")
		int found = 0
		if (ends_with(ln, c":") && (starts_with(ln, c" ") == 0) && (d.current == 0)):
			d.is_label = 1
			d.label = substring(ln, 0, strlen(ln) - 1)
			d.text = strclone(c"")
			od_disas.push(d)
		else:
			d.addr = od_parse_hex_at(ln, &found)
			if (found):
				int at = index_of(ln, c"0x")
				int sp = at
				while ((ln[sp] != 0) && (ln[sp] != ' ')):
					sp = sp + 1
				char* rest = substring(ln, sp, strlen(ln))
				d.text = od_trim(rest)
				free(rest)
				od_disas.push(d)
			else:
				free(cast(char*, d))
		free(ln)
	list_free[char*](lines)


# "0xADDR: 0xWORD" lines -> little-endian bytes starting at the first
# address. Returns the malloc'd bytes (count in *out_len) and the base.
char* od_parse_words(char* text, int* out_base, int* out_len):
	list[char*] lines = od_split_lines(text)
	char* bytes = malloc(lines.length * 4 + 4)
	int n = 0
	int base = 0
	int have_base = 0
	for char* ln in lines:
		int colon = index_of(ln, c": 0x")
		if ((colon > 0) && starts_with(ln, c"0x")):
			int found = 0
			int addr = od_parse_hex_at(ln, &found)
			int word = od_parse_hex_at(ln + colon + 2, &found)
			if (have_base == 0):
				base = addr
				have_base = 1
			if (addr == base + n):
				bytes[n] = word & 255
				bytes[n + 1] = (word >> 8) & 255
				bytes[n + 2] = (word >> 16) & 255
				bytes[n + 3] = (word >> 24) & 255
				n = n + 4
		free(ln)
	list_free[char*](lines)
	*out_base = base
	*out_len = n
	return bytes


void od_set_lines(list[char*]* slot, char* text):
	if (*slot != 0):
		od_free_lines(*slot)
	list[char*] lines = od_split_lines(text)
	list[char*] out = new list[char*]
	for char* ln in lines:
		char* t = od_trim(ln)
		if (strlen(t) > 0):
			out.push(od_expand_tabs(t))
		free(t)
		free(ln)
	list_free[char*](lines)
	*slot = out


od_source* od_find_source(char* path):
	for od_source* s in od_sources:
		if (strcmp(s.path, path) == 0):
			return s
	return 0


# ---- requests ------------------------------------------------------------------

int od_req_state():
	return 1
int od_req_cmd():
	return 2
int od_req_inspect():
	return 3
int od_req_poll():
	return 4
int od_req_source():
	return 5
int od_req_code():
	return 6
int od_req_dump():
	return 7
int od_req_restart():
	return 8
int od_req_core():
	return 9


struct od_req:
	int kind
	char* method
	char* path
	char* body
	char* arg


list[od_req*] od_queue
int od_inflight          # host handle, 0 when idle
od_req* od_inflight_req
int od_busy_cmd          # a run command is outstanding


void od_enqueue(int kind, char* method, char* path, char* body, char* arg):
	od_req* r = new od_req()
	r.kind = kind
	r.method = method
	r.path = strclone(path)
	r.body = strclone(body)
	r.arg = 0
	if (arg != 0):
		r.arg = strclone(arg)
	od_queue.push(r)


void od_req_free(od_req* r):
	free(r.path)
	free(r.body)
	if (r.arg != 0):
		free(r.arg)
	free(cast(char*, r))


char* od_status_msg


void od_status(char* msg):
	od_set_str(&od_status_msg, strclone(msg))


void od_request_inspect():
	od_enqueue(od_req_inspect(), c"GET", c"/api/inspect", c"", 0)


void od_request_dump():
	string_builder* cmd = string_from(c"x ")
	char* h = hex(od_dump_addr)
	string_append(cmd, h)
	free(h)
	string_append(cmd, c" 64")
	od_enqueue(od_req_dump(), c"POST", c"/api/query", cmd.data, 0)
	string_free(cmd)


void od_run_command(char* cmd):
	if (strcmp(od_state, c"stopped") != 0):
		od_status(c"the debuggee is not paused")
		return
	if (od_busy_cmd):
		return
	string_builder* echo = string_from(c"wdbg> ")
	string_append(echo, cmd)
	od_log_add(echo.data)
	string_free(echo)
	od_busy_cmd = 1
	od_enqueue(od_req_cmd(), c"POST", c"/api/cmd", cmd, 0)


void od_after_state(char* state, char* output):
	int was_stopped = strcmp(od_state, c"stopped") == 0
	od_set_str(&od_state, strclone(state))
	if (strlen(output) > 0):
		od_log_add(output)
	if (strcmp(state, c"stopped") == 0):
		od_request_inspect()
	else if (strcmp(state, c"exited") == 0):
		od_status(c"Process terminated")
		print(c"wdbg_ui: exited\n")
	else if (strcmp(state, c"running") == 0):
		if (was_stopped):
			od_status(c"Running")


# The disassembly and dump panes need raw bytes: fetch them once the
# instruction list for this stop is known.
void od_request_code():
	int first = 0
	int last = 0
	int have = 0
	for od_insn* d in od_disas:
		if (d.is_label == 0):
			if (have == 0):
				first = d.addr
				have = 1
			last = d.addr
	if (have == 0):
		return
	int words = (last - first + 16) / 4
	if (words > 512):
		words = 512
	string_builder* cmd = string_from(c"x ")
	char* h = hex(first)
	string_append(cmd, h)
	free(h)
	string_append(cmd, c" ")
	string_append_int(cmd, words)
	od_enqueue(od_req_code(), c"POST", c"/api/query", cmd.data, 0)
	string_free(cmd)


void od_request_source(char* path):
	if (od_find_source(path) != 0):
		return
	string_builder* p = string_from(c"/api/source?file=")
	string_append(p, path)
	od_enqueue(od_req_source(), c"GET", p.data, c"", path)
	string_free(p)


int od_view_source_line     # forward: set by the source view on stops
void od_source_follow();
void od_disas_follow();


void od_handle_reply(od_req* r, int status, char* body):
	if (r.kind == od_req_cmd()):
		od_busy_cmd = 0
	if (status != 200):
		if (r.kind == od_req_source()):
			return
		char* err = od_json_get(body, c"error")
		if (strlen(err) > 0):
			od_status(err)
			od_log_add(err)
		free(err)
		return
	if (r.kind == od_req_state()):
		char* st = od_json_get(body, c"state")
		od_set_str(&od_program, od_json_get(body, c"program"))
		od_free_lines(od_files)
		od_files = od_json_strings(body, c"files")
		od_has_core = od_json_true(body, c"has_core")
		if (strlen(od_program) > 0):
			od_request_source(od_program)
		if (od_has_core):
			od_enqueue(od_req_core(), c"GET", c"/api/core", c"", 0)
		# The poll reply (od_after_state) brings the program's output
		# so far and asks for the panes when it is stopped.
		od_enqueue(od_req_poll(), c"GET", c"/api/poll", c"", 0)
		free(st)
		return
	if ((r.kind == od_req_cmd()) || (r.kind == od_req_poll()) || (r.kind == od_req_restart())):
		char* st = od_json_get(body, c"state")
		char* out = od_json_get(body, c"output")
		if (r.kind == od_req_restart()):
			od_regs_valid = 0
			od_dump_addr = 0
		od_after_state(st, out)
		free(st)
		free(out)
		return
	if (r.kind == od_req_inspect()):
		char* where = od_json_get(body, c"where")
		od_parse_where(where)
		free(where)
		char* regs = od_json_get(body, c"registers")
		od_parse_registers(regs)
		free(regs)
		char* t = od_json_get(body, c"locals")
		od_set_lines(&od_locals, t)
		free(t)
		t = od_json_get(body, c"args")
		od_set_lines(&od_args, t)
		free(t)
		t = od_json_get(body, c"backtrace")
		od_set_lines(&od_backtrace, t)
		free(t)
		t = od_json_get(body, c"breakpoints")
		od_parse_breakpoints(t)
		free(t)
		t = od_json_get(body, c"stack")
		od_set_lines(&od_stack, t)
		free(t)
		t = od_json_get(body, c"disas")
		od_parse_disas(t)
		free(t)
		od_disas_follow()
		od_request_code()
		if (od_dump_addr == 0):
			od_dump_addr = od_regs[4]
		od_request_dump()
		string_builder* msg = string_new()
		if (od_where_line > 0):
			string_append(msg, c"Paused at ")
			string_append(msg, od_where_func)
			string_append(msg, c" (")
			string_append(msg, od_path_tail(od_where_file))
			string_append(msg, c":")
			string_append_int(msg, od_where_line)
			string_append(msg, c")")
			od_request_source(od_where_file)
		else:
			string_append(msg, c"Paused outside the program (before main or after it returned)")
			# Show the program's own file until there is a line to follow.
			if ((od_src_file == 0) && (strlen(od_program) > 0)):
				od_set_str(&od_src_file, strclone(od_program))
				od_request_source(od_program)
		od_status(msg.data)
		print(c"wdbg_ui: ")
		println(msg.data)
		string_free(msg)
		od_source_follow()
		return
	if (r.kind == od_req_source()):
		od_source* s = new od_source()
		s.path = strclone(r.arg)
		s.lines = new list[char*]
		list[char*] lines = od_split_lines(body)
		for char* ln in lines:
			s.lines.push(od_expand_tabs(ln))
			free(ln)
		list_free[char*](lines)
		od_sources.push(s)
		od_source_follow()
		return
	if ((r.kind == od_req_code()) || (r.kind == od_req_dump())):
		char* out = od_json_get(body, c"output")
		int base = 0
		int len = 0
		char* bytes = od_parse_words(out, &base, &len)
		free(out)
		if (r.kind == od_req_code()):
			if (od_code_bytes != 0):
				free(od_code_bytes)
			od_code_bytes = bytes
			od_code_base = base
			od_code_len = len
		else:
			if (od_dump_bytes != 0):
				free(od_dump_bytes)
			od_dump_bytes = bytes
			od_dump_len = len
			od_dump_valid = len > 0
		return
	if (r.kind == od_req_core()):
		od_log_add(c"core dump report (wcore --json):")
		char* sig = od_json_get(body, c"signal_name")
		string_builder* ln = string_from(c"  signal ")
		string_append(ln, sig)
		od_log_add(ln.data)
		string_free(ln)
		free(sig)
		# Frames: every "function":"..." in order, with file:line.
		char* p = body
		int at = index_of(p, c"\"function\":\"")
		int k = 0
		while (at >= 0):
			p = p + at + 12
			int e = index_of(p, c"\"")
			string_builder* fr = string_from(c"  #")
			string_append_int(fr, k)
			string_append(fr, c"  ")
			char* fn = substring(p, 0, e)
			string_append(fr, fn)
			free(fn)
			od_log_add(fr.data)
			string_free(fr)
			k = k + 1
			at = index_of(p, c"\"function\":\"")
		od_status(c"Core dump loaded (see the log, L)")


# Start the next queued request, or collect the finished one.
void od_net_step():
	if (od_inflight != 0):
		int st = wdbg_http_status(od_inflight)
		if (st == 0):
			return
		int len = wdbg_http_length(od_inflight)
		char* body = malloc(len + 1)
		int got = wdbg_http_read(od_inflight, body, len)
		body[got] = 0
		wdbg_http_free(od_inflight)
		od_inflight = 0
		od_req* r = od_inflight_req
		od_inflight_req = 0
		if (st < 0):
			od_status(c"lost the connection to wdbg_web")
			if (r.kind == od_req_cmd()):
				od_busy_cmd = 0
		else:
			od_handle_reply(r, st, body)
		free(body)
		od_req_free(r)
	if (od_queue.length == 0):
		return
	od_req* next = od_queue[0]
	od_queue.remove(0)
	od_inflight_req = next
	od_inflight = wdbg_http_start(next.method, next.path, next.body)


# ---- drawing primitives --------------------------------------------------------

gfx_window* od_win
ui_renderer* od_rndr
ui_context* od_ctx
ui_theme od_theme
int od_font          # regular strike for pane text
int od_font_bold
int od_cw            # fixed cell width
int od_lh            # row height
int od_ascent_pad


ui_color od_rgb(float32 r, float32 g, float32 b):
	return ui_color_new(r, g, b, 1.0)


ui_color od_c_face():
	return od_rgb(0.831, 0.816, 0.784)
ui_color od_c_light():
	return od_rgb(1.0, 1.0, 1.0)
ui_color od_c_shadow():
	return od_rgb(0.502, 0.502, 0.502)
ui_color od_c_dark():
	return od_rgb(0.25, 0.25, 0.25)
ui_color od_c_text():
	return od_rgb(0.0, 0.0, 0.0)
ui_color od_c_muted():
	return od_rgb(0.4, 0.4, 0.4)
ui_color od_c_select():
	return od_rgb(0.753, 0.753, 0.753)
ui_color od_c_red():
	return od_rgb(1.0, 0.0, 0.0)
ui_color od_c_navy():
	return od_rgb(0.0, 0.0, 0.502)
ui_color od_c_caption():
	return od_rgb(0.039, 0.141, 0.416)
ui_color od_c_yellow():
	return od_rgb(1.0, 1.0, 0.0)


void od_fill(int x, int y, int w, int h, ui_color c):
	if ((w <= 0) || (h <= 0)):
		return
	ui_render_rect(od_rndr, ui_rect_new(cast(float32, x), cast(float32, y), cast(float32, w), cast(float32, h)), c)


# Windows-classic 3D edge: raised (light top-left) or sunken.
void od_bevel(int x, int y, int w, int h, int raised):
	ui_color tl = od_c_light()
	ui_color br = od_c_shadow()
	if (raised == 0):
		tl = od_c_shadow()
		br = od_c_light()
	od_fill(x, y, w, 1, tl)
	od_fill(x, y, 1, h, tl)
	od_fill(x, y + h - 1, w, 1, br)
	od_fill(x + w - 1, y, 1, h, br)


# Fixed-cell text: every byte gets one od_cw cell, the glyph centered in
# it, so columns align like a monospace font. Draws at most max_cells
# (max_cells < 0: all). Returns the cells used.
int od_cells_n(int x, int y, char* s, int max_cells, ui_color c, int strike):
	int i = 0
	while ((s[i] != 0) && ((max_cells < 0) || (i < max_cells))):
		int ch = s[i] & 255
		if (ch > 32):
			ui_glyph g = ui_font_glyph(strike, ch)
			int ox = (od_cw - g.advance) / 2
			if (ox < 0):
				ox = 0
			ui_render_glyph_strike(od_rndr, cast(float32, x + i * od_cw + ox), cast(float32, y + od_ascent_pad), ch, strike, 0.0, c)
		i = i + 1
	return i


void od_cells(int x, int y, char* s, ui_color c):
	od_cells_n(x, y, s, 0 - 1, c, od_font)


# Proportional text (toolbar and captions).
void od_ptext(int x, int y, char* s, ui_color c, int strike):
	ui_draw_text_strike(od_rndr, cast(float32, x), cast(float32, y + od_ascent_pad), s, strike, 0, c)


int od_ptext_width(char* s, int strike):
	return ui_text_width_strike(s, strike)


void od_clip(int x, int y, int w, int h):
	ui_clip_push(od_rndr, ui_rect_new(cast(float32, x), cast(float32, y), cast(float32, w), cast(float32, h)))


void od_unclip():
	ui_clip_pop(od_rndr)


# ---- input ---------------------------------------------------------------------

int od_frame
int od_mouse_x
int od_mouse_y
int od_clicked          # a button-1 press landed this frame
int od_click_x
int od_click_y
int od_dbl              # ... and it was a double click
int od_last_click_frame
int od_last_click_x
int od_last_click_y
int od_wheel
int od_wheel_x
int od_wheel_y

# keys pressed this frame (raw keycodes + mods), from KEY_DOWN events
int[16] od_keys
int[16] od_key_mods
int od_key_count


int od_in(int x, int y, int w, int h, int px, int py):
	return (px >= x) && (px < x + w) && (py >= y) && (py < y + h)


int od_clicked_in(int x, int y, int w, int h):
	return od_clicked && od_in(x, y, w, h, od_click_x, od_click_y)


void od_poll_input():
	od_clicked = 0
	od_dbl = 0
	od_wheel = 0
	od_key_count = 0
	gfx_event e
	while (gfx_window_next_event(od_win, &e)):
		ui_feed_event(od_ctx, &e)
		if ((e.kind == GFX_EVENT_MOUSE_DOWN) && (e.code == 1)):
			od_clicked = 1
			od_click_x = e.x
			od_click_y = e.y
			int dx = e.x - od_last_click_x
			int dy = e.y - od_last_click_y
			if ((od_frame - od_last_click_frame < 24) && (dx < 4) && (dx > -4) && (dy < 4) && (dy > -4)):
				od_dbl = 1
				od_last_click_frame = -100
			else:
				od_last_click_frame = od_frame
			od_last_click_x = e.x
			od_last_click_y = e.y
		else if (e.kind == GFX_EVENT_SCROLL):
			od_wheel = od_wheel + e.code
			od_wheel_x = e.x
			od_wheel_y = e.y
		else if (e.kind == GFX_EVENT_KEY_DOWN):
			if (od_key_count < 16):
				od_keys[od_key_count] = e.code
				od_key_mods[od_key_count] = e.mods
				od_key_count = od_key_count + 1
	od_mouse_x = od_win.mouse_x
	od_mouse_y = od_win.mouse_y


# ---- panes ---------------------------------------------------------------------

struct od_pane:
	int x
	int y
	int w
	int h
	int body_y       # first row's y
	int scroll       # first visible row
	int sel          # selected row, -1 = none
	int rows         # row count this frame
	int follow       # scroll to follow_row on the next draw
	int follow_row


int od_p_disas():
	return 0
int od_p_regs():
	return 1
int od_p_dump():
	return 2
int od_p_stack():
	return 3
int od_p_source():
	return 4
int od_p_files():
	return 5
int od_p_log():
	return 6
int od_p_calls():
	return 7
int od_p_bps():
	return 8


od_pane[9] od_panes
int od_focus
int od_view            # 'C', 'S', 'L', 'K', 'B'


int od_pane_visible(od_pane* p):
	int v = (p.y + p.h - p.body_y) / od_lh
	if (v < 1):
		return 1
	return v


void od_pane_clamp(od_pane* p):
	int vis = od_pane_visible(p)
	int max_scroll = p.rows - vis
	if (max_scroll < 0):
		max_scroll = 0
	if (p.scroll > max_scroll):
		p.scroll = max_scroll
	if (p.scroll < 0):
		p.scroll = 0


void od_pane_show_row(od_pane* p, int row, int center):
	int vis = od_pane_visible(p)
	if ((row >= p.scroll) && (row < p.scroll + vis)):
		od_pane_clamp(p)
		return
	if (center):
		p.scroll = row - vis / 2
	else if (row < p.scroll):
		p.scroll = row
	else if (row >= p.scroll + vis):
		p.scroll = row - vis + 1
	od_pane_clamp(p)


# Frame, header strip and the shared mouse behavior of a list pane.
# Returns the row the mouse clicked this frame (-1 = none).
int od_pane_begin(int idx, int x, int y, int w, int h, char* header, int rows):
	od_pane* p = &od_panes[idx]
	p.x = x
	p.y = y
	p.w = w
	p.h = h
	p.rows = rows
	od_fill(x, y, w, h, od_c_light())
	od_bevel(x, y, w, h, 0)
	int hh = od_lh + 2
	p.body_y = y + hh + 1
	# The column-header strip, raised like a Win32 list-view header.
	od_fill(x + 1, y + 1, w - 2, hh, od_c_face())
	od_bevel(x + 1, y + 1, w - 2, hh, 1)
	od_clip(x + 1, y + 1, w - 2, hh)
	od_cells(x + 4, y + 2, header, od_c_text())
	od_unclip()
	if (od_focus == idx):
		od_fill(x + 1, y + hh + 1, w - 2, 1, od_c_navy())
	if (p.follow):
		od_pane_show_row(p, p.follow_row, 1)
		p.follow = 0
	int clicked_row = -1
	if (od_wheel != 0):
		if (od_in(x, y, w, h, od_wheel_x, od_wheel_y)):
			p.scroll = p.scroll - od_wheel * 3
	od_pane_clamp(p)
	if (od_clicked_in(x, y, w, h)):
		od_focus = idx
		if (od_click_y >= p.body_y):
			int row = p.scroll + (od_click_y - p.body_y) / od_lh
			if (row < rows):
				p.sel = row
				clicked_row = row
	od_clip(x + 1, p.body_y, w - 2, y + h - p.body_y - 1)
	return clicked_row


void od_pane_end():
	od_unclip()


# y of a row, or -1 when it is scrolled out of view.
int od_row_y(od_pane* p, int row):
	int vis = od_pane_visible(p)
	if ((row < p.scroll) || (row >= p.scroll + vis + 1)):
		return -1
	return p.body_y + (row - p.scroll) * od_lh


# The selection bar under a row.
void od_row_bg(od_pane* p, int row, int ry):
	if (row == p.sel):
		od_fill(p.x + 1, ry, p.w - 2, od_lh, od_c_select())


# ---- CPU view ------------------------------------------------------------------

# Hex bytes of the instruction at addr, up to the next one (8 max).
char* od_insn_bytes(int addr, int next):
	string_builder* b = string_new()
	if ((od_code_bytes != 0) && (next > addr)):
		int n = next - addr
		if (n > 8):
			n = 8
		int i = 0
		while (i < n):
			int off = addr - od_code_base + i
			if ((off >= 0) && (off < od_code_len)):
				char* h = od_hex2(od_code_bytes[off] & 255)
				string_append(b, h)
				free(h)
			i = i + 1
	char* out = strclone(b.data)
	string_free(b)
	return out


ui_color od_mnemonic_color(char* text):
	if (starts_with(text, c"call")):
		return od_rgb(0.0, 0.0, 0.8)
	if (starts_with(text, c"j")):
		return od_rgb(0.65, 0.0, 0.0)
	if (starts_with(text, c"ret") || starts_with(text, c"leave")):
		return od_rgb(0.0, 0.45, 0.0)
	if (starts_with(text, c"int3")):
		return od_c_red()
	if (starts_with(text, c".byte")):
		return od_c_muted()
	return od_c_text()


void od_draw_disas(int x, int y, int w, int h):
	int c_addr = x + 4
	int c_hex = c_addr + od_cw * 10
	int c_dis = c_hex + od_cw * 18
	int c_com = c_dis + od_cw * 34
	int clicked = od_pane_begin(od_p_disas(), x, y, w, h, c"Address   Hex dump          Disassembly                       Comment", od_disas.length)
	od_pane* p = &od_panes[od_p_disas()]
	int i = p.scroll
	while (i < od_disas.length):
		int ry = od_row_y(p, i)
		if (ry < 0):
			i = od_disas.length
		else:
			od_insn* d = od_disas[i]
			od_row_bg(p, i, ry)
			if (d.is_label):
				string_builder* lb = string_from(c"<")
				string_append(lb, d.label)
				string_append(lb, c">")
				od_cells_n(c_dis, ry, lb.data, -1, od_c_navy(), od_font_bold)
				string_free(lb)
			else:
				char* ah = od_hex8(d.addr)
				if (d.current):
					od_fill(c_addr - 2, ry, od_cw * 8 + 4, od_lh, od_c_text())
					od_cells(c_addr, ry, ah, od_c_light())
				else:
					od_cells(c_addr, ry, ah, od_c_text())
				free(ah)
				int next = 0
				int j = i + 1
				while ((next == 0) && (j < od_disas.length)):
					if (od_disas[j].is_label == 0):
						next = od_disas[j].addr
					j = j + 1
				char* hb = od_insn_bytes(d.addr, next)
				od_cells(c_hex, ry, hb, od_c_text())
				free(hb)
				od_cells_n(c_dis, ry, d.text, 34, od_mnemonic_color(d.text), od_font)
				if (d.current && (strlen(od_where_text) > 0)):
					string_builder* cm = string_from(od_path_tail(od_where_file))
					string_append(cm, c":")
					string_append_int(cm, od_where_line)
					string_append(cm, c"  ")
					char* src = od_trim(od_where_text + 2)
					# drop the leading line number wdbg prints after "->"
					int k = 0
					while ((src[k] >= '0') && (src[k] <= '9')):
						k = k + 1
					char* rest = od_trim(src + k)
					string_append(cm, rest)
					free(rest)
					free(src)
					od_cells(c_com, ry, cm.data, od_c_navy())
					string_free(cm)
			i = i + 1
	od_pane_end()
	if (clicked >= 0):
		od_focus = od_p_disas()


void od_follow_in_dump(int addr):
	od_dump_addr = addr
	od_request_dump()
	string_builder* m = string_from(c"Dump follows ")
	char* h = od_hex8(addr)
	string_append(m, h)
	free(h)
	od_status(m.data)
	string_free(m)


int od_flag_bit(int i):
	# C P A Z S T D O
	if (i == 0):
		return 0
	if (i == 1):
		return 2
	if (i == 2):
		return 4
	if (i == 3):
		return 6
	if (i == 4):
		return 7
	if (i == 5):
		return 8
	if (i == 6):
		return 10
	return 11


void od_draw_regs(int x, int y, int w, int h):
	# rows: 8 GPRs, blank, EIP, blank, 8 flags, blank, EFL, blank,
	# "Locals", locals..., "Arguments", args...
	int nrows = 21 + 1 + od_locals.length + 1 + od_args.length
	int clicked = od_pane_begin(od_p_regs(), x, y, w, h, c"Registers (x86)", nrows)
	od_pane* p = &od_panes[od_p_regs()]
	int cx = x + 6
	int row = 0
	while (row < nrows):
		int ry = od_row_y(p, row)
		if (ry >= 0):
			od_row_bg(p, row, ry)
			if (od_regs_valid && ((row < 8) || (row == 9))):
				int ri = row
				if (row == 9):
					ri = 8
				ui_color c = od_c_text()
				if (od_regs[ri] != od_prev_regs[ri]):
					c = od_c_red()
				od_cells(cx, ry, od_reg_name(ri), od_c_text())
				char* hv = od_hex8(od_regs[ri])
				od_cells(cx + od_cw * 4, ry, hv, c)
				free(hv)
				if (ri == 8):
					od_cells(cx + od_cw * 13, ry, od_where_func, od_c_navy())
			else if (od_regs_valid && (row >= 11) && (row < 19)):
				int fi = row - 11
				char* fl = c"CPAZSTDO"
				int bit = (od_regs[9] >> od_flag_bit(fi)) & 1
				int pbit = (od_prev_regs[9] >> od_flag_bit(fi)) & 1
				char* one = substring(fl, fi, fi + 1)
				od_cells(cx, ry, one, od_c_text())
				free(one)
				ui_color c = od_c_text()
				if (bit != pbit):
					c = od_c_red()
				char* v = c"0"
				if (bit):
					v = c"1"
				od_cells(cx + od_cw * 2, ry, v, c)
			else if (od_regs_valid && (row == 20)):
				od_cells(cx, ry, c"EFL", od_c_text())
				char* hv = od_hex8(od_regs[9])
				ui_color c = od_c_text()
				if (od_regs[9] != od_prev_regs[9]):
					c = od_c_red()
				od_cells(cx + od_cw * 4, ry, hv, c)
				free(hv)
			else if (row == 21):
				od_cells(cx, ry, c"Locals", od_c_muted())
			else if ((row > 21) && (row <= 21 + od_locals.length)):
				od_cells(cx + od_cw * 2, ry, od_locals[row - 22], od_c_text())
			else if (row == 22 + od_locals.length):
				od_cells(cx, ry, c"Arguments", od_c_muted())
			else if (row > 22 + od_locals.length):
				od_cells(cx + od_cw * 2, ry, od_args[row - 23 - od_locals.length], od_c_text())
		row = row + 1
	od_pane_end()
	if ((clicked >= 0) && od_dbl && od_regs_valid):
		if (clicked < 8):
			od_follow_in_dump(od_regs[clicked])
		else if (clicked == 9):
			od_follow_in_dump(od_regs[8])


void od_draw_dump(int x, int y, int w, int h):
	int rows = od_dump_len / 16
	od_pane_begin(od_p_dump(), x, y, w, h, c"Address   Hex dump                                         ASCII", rows)
	od_pane* p = &od_panes[od_p_dump()]
	int c_addr = x + 4
	int c_hex = c_addr + od_cw * 10
	int c_asc = c_hex + od_cw * 49
	int r = p.scroll
	while (r < rows):
		int ry = od_row_y(p, r)
		if (ry < 0):
			r = rows
		else:
			od_row_bg(p, r, ry)
			char* ah = od_hex8(od_dump_addr + r * 16)
			od_cells(c_addr, ry, ah, od_c_text())
			free(ah)
			char* asc = malloc(17)
			int k = 0
			while (k < 16):
				int v = od_dump_bytes[r * 16 + k] & 255
				char* hb = od_hex2(v)
				od_cells(c_hex + od_cw * (k * 3), ry, hb, od_c_text())
				free(hb)
				if ((v >= 32) && (v < 127)):
					asc[k] = v
				else:
					asc[k] = '.'
				k = k + 1
			asc[16] = 0
			od_cells(c_asc, ry, asc, od_c_text())
			free(asc)
			r = r + 1
	if (od_dump_valid == 0):
		od_cells(c_addr, p.body_y, c"(no readable memory at this address)", od_c_muted())
	od_pane_end()


void od_draw_stack(int x, int y, int w, int h):
	int clicked = od_pane_begin(od_p_stack(), x, y, w, h, c"Address   Value     Comment", od_stack.length)
	od_pane* p = &od_panes[od_p_stack()]
	int c_addr = x + 4
	int c_val = c_addr + od_cw * 10
	int c_com = c_val + od_cw * 10
	int r = p.scroll
	while (r < od_stack.length):
		int ry = od_row_y(p, r)
		if (ry < 0):
			r = od_stack.length
		else:
			od_row_bg(p, r, ry)
			char* ln = od_stack[r]
			int found = 0
			int addr = od_parse_hex_at(ln, &found)
			int colon = index_of(ln, c": ")
			int val = 0
			if (colon > 0):
				val = od_parse_hex_at(ln + colon, &found)
			char* ah = od_hex8(addr)
			if (od_regs_valid && (addr == od_regs[4])):
				od_fill(c_addr - 2, ry, od_cw * 8 + 4, od_lh, od_c_text())
				od_cells(c_addr, ry, ah, od_c_light())
			else:
				od_cells(c_addr, ry, ah, od_c_text())
			free(ah)
			char* vh = od_hex8(val)
			od_cells(c_val, ry, vh, od_c_text())
			free(vh)
			if (od_regs_valid && (addr == od_regs[5])):
				od_cells(c_com, ry, c"<- EBP (saved frame)", od_c_navy())
			else if (od_regs_valid && (val == od_regs[5] + 0) && (val != 0)):
				od_cells(c_com, ry, c"pointer to EBP frame", od_c_muted())
			r = r + 1
	od_pane_end()
	if ((clicked >= 0) && od_dbl):
		char* ln = od_stack[clicked]
		int colon = index_of(ln, c": ")
		if (colon > 0):
			int found = 0
			od_follow_in_dump(od_parse_hex_at(ln + colon, &found))


# ---- source / log / call stack / breakpoints views --------------------------

od_bp* od_bp_at(char* file, int line):
	for od_bp* b in od_bps:
		if ((b.line == line) && (strcmp(b.file, file) == 0)):
			return b
	return 0


# Keep the source view on the stop location once that file is loaded.
void od_source_follow():
	if (od_where_line <= 0):
		return
	if (od_find_source(od_where_file) == 0):
		return
	if ((od_src_file == 0) || (strcmp(od_src_file, od_where_file) != 0)):
		od_set_str(&od_src_file, strclone(od_where_file))
	od_pane* p = &od_panes[od_p_source()]
	p.sel = od_where_line - 1
	p.follow = 1
	p.follow_row = od_where_line - 1


# Scroll the disassembly so the EIP row is in view.
void od_disas_follow():
	int i = 0
	while (i < od_disas.length):
		if (od_disas[i].current):
			od_pane* p = &od_panes[od_p_disas()]
			p.follow = 1
			p.follow_row = i
			return
		i = i + 1


void od_open_source(char* path, int line):
	od_set_str(&od_src_file, strclone(path))
	od_request_source(path)
	od_pane* p = &od_panes[od_p_source()]
	if (line > 0):
		p.sel = line - 1
		p.follow = 1
		p.follow_row = line - 1
	else:
		p.scroll = 0
		p.sel = -1


void od_toggle_breakpoint():
	if (od_src_file == 0):
		return
	od_pane* p = &od_panes[od_p_source()]
	if (p.sel < 0):
		od_status(c"select a source line first")
		return
	int line = p.sel + 1
	od_bp* b = od_bp_at(od_src_file, line)
	string_builder* cmd = string_new()
	if (b != 0):
		string_append(cmd, c"d ")
		string_append_int(cmd, b.n)
	else:
		string_append(cmd, c"b ")
		string_append(cmd, od_src_file)
		string_append(cmd, c":")
		string_append_int(cmd, line)
	od_run_command(cmd.data)
	string_free(cmd)


void od_draw_source(int x, int y, int w, int h):
	od_source* src = 0
	if (od_src_file != 0):
		src = od_find_source(od_src_file)
	int rows = 0
	if (src != 0):
		rows = src.lines.length
	char* hdr = c"Line   Source"
	int clicked = od_pane_begin(od_p_source(), x, y, w, h, hdr, rows)
	od_pane* p = &od_panes[od_p_source()]
	int c_num = x + 4
	int c_src = c_num + od_cw * 7
	int r = p.scroll
	while (r < rows):
		int ry = od_row_y(p, r)
		if (ry < 0):
			r = rows
		else:
			int is_cur = (od_where_line == r + 1) && (strcmp(od_where_file, od_src_file) == 0)
			if (is_cur):
				od_fill(p.x + 1, ry, p.w - 2, od_lh, od_rgb(1.0, 1.0, 0.75))
				if (r == p.sel):
					od_fill(p.x + 1, ry, p.w - 2, 1, od_c_select())
					od_fill(p.x + 1, ry + od_lh - 1, p.w - 2, 1, od_c_select())
			else:
				od_row_bg(p, r, ry)
			string_builder* num = string_new()
			string_append_int(num, r + 1)
			if (od_bp_at(od_src_file, r + 1) != 0):
				od_fill(c_num - 2, ry, od_cw * 4 + 4, od_lh, od_c_red())
				od_cells(c_num, ry, num.data, od_c_light())
			else:
				od_cells(c_num, ry, num.data, od_c_muted())
			string_free(num)
			if (is_cur):
				od_cells(c_num + od_cw * 5, ry, c">", od_c_text())
			od_cells(c_src, ry, src.lines[r], od_c_text())
			r = r + 1
	if (src == 0):
		od_cells(c_num, p.body_y, c"(no source loaded)", od_c_muted())
	od_pane_end()
	if ((clicked >= 0) && od_dbl):
		od_toggle_breakpoint()


void od_draw_files(int x, int y, int w, int h):
	int clicked = od_pane_begin(od_p_files(), x, y, w, h, c"Source files", od_files.length)
	od_pane* p = &od_panes[od_p_files()]
	int r = p.scroll
	while (r < od_files.length):
		int ry = od_row_y(p, r)
		if (ry < 0):
			r = od_files.length
		else:
			char* f = od_files[r]
			ui_color c = od_c_text()
			if ((od_src_file != 0) && (strcmp(f, od_src_file) == 0)):
				od_fill(p.x + 1, ry, p.w - 2, od_lh, od_c_navy())
				c = od_c_light()
			else:
				od_row_bg(p, r, ry)
			od_cells(x + 4, ry, od_path_tail(f), c)
			r = r + 1
	od_pane_end()
	if (clicked >= 0):
		od_open_source(od_files[clicked], 0)


void od_draw_text_list(int idx, int x, int y, int w, int h, char* header, list[char*] lines):
	od_pane_begin(idx, x, y, w, h, header, lines.length)
	od_pane* p = &od_panes[idx]
	int r = p.scroll
	while (r < lines.length):
		int ry = od_row_y(p, r)
		if (ry < 0):
			r = lines.length
		else:
			od_row_bg(p, r, ry)
			ui_color c = od_c_text()
			if (starts_with(lines[r], c"wdbg> ")):
				c = od_c_navy()
			od_cells(x + 4, ry, lines[r], c)
			r = r + 1
	od_pane_end()


int od_log_seen


void od_draw_log(int x, int y, int w, int h):
	od_pane* p = &od_panes[od_p_log()]
	if (od_log.length != od_log_seen):
		p.follow = 1
		p.follow_row = od_log.length
		od_log_seen = od_log.length
	od_draw_text_list(od_p_log(), x, y, w, h, c"Log data", od_log)


void od_select_frame(int row):
	if (row < 0):
		return
	if (row >= od_backtrace.length):
		return
	char* ln = od_backtrace[row]
	if (ln[0] != '#'):
		return
	int k = 1
	while ((ln[k] >= '0') && (ln[k] <= '9')):
		k = k + 1
	char* n = substring(ln, 1, k)
	string_builder* cmd = string_from(c"f ")
	string_append(cmd, n)
	free(n)
	od_run_command(cmd.data)
	string_free(cmd)


void od_draw_calls(int x, int y, int w, int h):
	od_draw_text_list(od_p_calls(), x, y, w, h, c"Call stack of main thread", od_backtrace)
	od_pane* p = &od_panes[od_p_calls()]
	if (od_dbl && od_in(x, p.body_y, w, h, od_click_x, od_click_y)):
		od_select_frame(p.sel)


void od_draw_bps(int x, int y, int w, int h):
	int clicked = od_pane_begin(od_p_bps(), x, y, w, h, c"#     Module / file          Line    Status", od_bps.length)
	od_pane* p = &od_panes[od_p_bps()]
	int r = p.scroll
	while (r < od_bps.length):
		int ry = od_row_y(p, r)
		if (ry < 0):
			r = od_bps.length
		else:
			od_bp* b = od_bps[r]
			od_row_bg(p, r, ry)
			string_builder* n = string_new()
			string_append_int(n, b.n)
			od_cells(x + 4, ry, n.data, od_c_text())
			string_free(n)
			od_cells(x + 4 + od_cw * 6, ry, od_path_tail(b.file), od_c_text())
			string_builder* l = string_new()
			string_append_int(l, b.line)
			od_cells(x + 4 + od_cw * 29, ry, l.data, od_c_text())
			string_free(l)
			int hit = index_of(b.text, c"hits:")
			if (hit > 0):
				od_cells(x + 4 + od_cw * 37, ry, b.text + hit, od_c_text())
			else:
				od_cells(x + 4 + od_cw * 37, ry, c"Active", od_c_text())
			r = r + 1
	od_pane_end()
	if ((clicked >= 0) && od_dbl):
		od_bp* b = od_bps[clicked]
		od_view = 'S'
		od_focus = od_p_source()
		od_open_source(b.file, b.line)


void od_delete_selected_bp():
	od_pane* p = &od_panes[od_p_bps()]
	if ((p.sel < 0) || (p.sel >= od_bps.length)):
		return
	string_builder* cmd = string_from(c"d ")
	string_append_int(cmd, od_bps[p.sel].n)
	od_run_command(cmd.data)
	string_free(cmd)


# ---- chrome: toolbar, caption, command line, status bar ----------------------

char* od_cmd_buf
int od_cmd_len


# A raised Win32 push button; returns 1 when clicked this frame.
int od_button(int x, int y, int w, int h, char* label, int down, int enabled):
	od_fill(x, y, w, h, od_c_face())
	int pressed = down || (od_ctx.input.mouse_down && od_in(x, y, w, h, od_mouse_x, od_mouse_y))
	od_bevel(x, y, w, h, pressed == 0)
	ui_color c = od_c_text()
	if (enabled == 0):
		c = od_c_shadow()
	int tw = od_ptext_width(label, od_font)
	od_ptext(x + (w - tw) / 2, y + (h - od_lh) / 2 + 1, label, c, od_font)
	return enabled && od_clicked_in(x, y, w, h)


void od_restart():
	if (od_busy_cmd):
		return
	od_log_add(c"[restart]")
	od_busy_cmd = 1
	od_status(c"Restarting")
	od_enqueue(od_req_restart(), c"POST", c"/api/restart", c"", 0)


# Switch views; the keyboard follows to the view's main pane.
void od_show_view(int v):
	od_view = v
	if (v == 'C'):
		od_focus = od_p_disas()
	else if (v == 'S'):
		od_focus = od_p_source()
	else if (v == 'L'):
		od_focus = od_p_log()
	else if (v == 'K'):
		od_focus = od_p_calls()
	else if (v == 'B'):
		od_focus = od_p_bps()


int od_toolbar(int width):
	int h = od_lh + 12
	od_fill(0, 0, width, h, od_c_face())
	od_fill(0, h - 1, width, 1, od_c_shadow())
	int stopped = (strcmp(od_state, c"stopped") == 0) && (od_busy_cmd == 0)
	int x = 4
	int bh = h - 6
	if (od_button(x, 3, 70, bh, c"Restart", 0, od_busy_cmd == 0)):
		od_restart()
	x = x + 74
	if (od_button(x, 3, 62, bh, c"Run F9", 0, stopped)):
		od_run_command(c"c")
	x = x + 66
	if (od_button(x, 3, 80, bh, c"Into F7", 0, stopped)):
		od_run_command(c"s")
	x = x + 84
	if (od_button(x, 3, 80, bh, c"Over F8", 0, stopped)):
		od_run_command(c"n")
	x = x + 84
	if (od_button(x, 3, 96, bh, c"Till return", 0, stopped)):
		od_run_command(c"fin")
	x = x + 100
	if (od_button(x, 3, 62, bh, c"Insn", 0, stopped)):
		od_run_command(c"si")
	x = x + 74
	# The view letters, OllyDbg's L E M T W H C / K B R ... S row.
	char* letters = c"LCKBS"
	int i = 0
	while (i < 5):
		int ch = letters[i]
		char* one = substring(letters, i, i + 1)
		if (od_button(x, 3, bh, bh, one, od_view == ch, 1)):
			od_show_view(ch)
		free(one)
		x = x + bh + 2
		i = i + 1
	if (od_program != 0):
		od_ptext(x + 12, 3 + (bh - od_lh) / 2 + 1, od_path_tail(od_program), od_c_muted(), od_font)
	return h


char* od_view_title():
	if (od_view == 'S'):
		return c"S  Source"
	if (od_view == 'L'):
		return c"L  Log data"
	if (od_view == 'K'):
		return c"K  Call stack of main thread"
	if (od_view == 'B'):
		return c"B  Breakpoints"
	return c"C  CPU - main thread"


int od_caption(int y, int width):
	int h = od_lh + 4
	od_fill(0, y, width, h, od_c_caption())
	string_builder* t = string_from(od_view_title())
	if ((od_view == 'C') && (od_program != 0)):
		string_append(t, c", module ")
		string_append(t, od_path_tail(od_program))
	if ((od_view == 'S') && (od_src_file != 0)):
		string_append(t, c" - ")
		string_append(t, od_src_file)
	od_ptext(6, y + 2, t.data, od_c_light(), od_font_bold)
	string_free(t)
	return h


# OllyDbg's command-line bar. "D <addr>" moves the dump; anything else
# goes to wdbg.
void od_submit_command():
	od_cmd_buf[od_cmd_len] = 0
	char* cmd = od_trim(od_cmd_buf)
	od_cmd_len = 0
	od_cmd_buf[0] = 0
	if (strlen(cmd) == 0):
		free(cmd)
		return
	if (starts_with(cmd, c"D ")):
		int found = 0
		int addr = od_parse_hex_at(cmd, &found)
		if (found == 0):
			addr = from_hex(cmd + 2)
		od_follow_in_dump(addr)
	else:
		od_run_command(cmd)
	free(cmd)


void od_command_bar(int y, int width):
	int h = od_lh + 8
	od_fill(0, y, width, h, od_c_face())
	od_ptext(6, y + 4, c"Command:", od_c_text(), od_font)
	int bx = 6 + od_ptext_width(c"Command: ", od_font) + 4
	int bw = width - bx - 6
	od_fill(bx, y + 2, bw, h - 4, od_c_light())
	od_bevel(bx, y + 2, bw, h - 4, 0)
	# Typed characters always land here (F-keys arrive as KEY_DOWN, not
	# CHAR, so they never type).
	int i = 0
	while (i < od_ctx.char_count):
		int c = od_ctx.chars[i]
		if (c == 8):
			if (od_cmd_len > 0):
				od_cmd_len = od_cmd_len - 1
		else if (c == 13):
			if (od_view == 'K'):
				od_select_frame(od_panes[od_p_calls()].sel)
			else:
				od_submit_command()
		else if (c == 27):
			od_cmd_len = 0
		else if ((c >= 32) && (c < 127) && (od_cmd_len < 250)):
			od_cmd_buf[od_cmd_len] = c
			od_cmd_len = od_cmd_len + 1
		i = i + 1
	od_cmd_buf[od_cmd_len] = 0
	od_cells(bx + 4, y + 4, od_cmd_buf, od_c_text())
	if (((od_frame / 30) % 2) == 0):
		od_fill(bx + 4 + od_cmd_len * od_cw, y + 4, 1, od_lh - 2, od_c_text())


void od_status_bar(int y, int width):
	int h = od_lh + 6
	od_fill(0, y, width, h, od_c_face())
	od_fill(0, y, width, 1, od_c_light())
	int bw = 110
	od_fill(2, y + 2, width - bw - 8, h - 4, od_c_face())
	od_bevel(2, y + 2, width - bw - 8, h - 4, 0)
	if (od_status_msg != 0):
		od_clip(4, y + 2, width - bw - 12, h - 4)
		od_ptext(6, y + 3, od_status_msg, od_c_text(), od_font)
		od_unclip()
	int bx = width - bw - 4
	char* label = c"No process"
	ui_color fill = od_c_face()
	ui_color ink = od_c_text()
	if (strcmp(od_state, c"stopped") == 0):
		label = c"Paused"
		fill = od_c_yellow()
	else if (strcmp(od_state, c"running") == 0):
		label = c"Running"
	else if (strcmp(od_state, c"exited") == 0):
		label = c"Terminated"
		ink = od_c_red()
	od_fill(bx, y + 2, bw, h - 4, fill)
	od_bevel(bx, y + 2, bw, h - 4, 0)
	od_ptext(bx + 8, y + 3, label, ink, od_font_bold)


# ---- keys ------------------------------------------------------------------------

void od_move_selection(int delta):
	od_pane* p = &od_panes[od_focus]
	if (od_focus == od_p_dump()):
		if ((delta > 1) || (delta < -1)):
			od_follow_in_dump(od_dump_addr + delta / 16 * 256)
			return
	int s = p.sel + delta
	if (s < 0):
		s = 0
	if (s >= p.rows):
		s = p.rows - 1
	p.sel = s
	od_pane_show_row(p, s, 0)


void od_handle_keys():
	int i = 0
	while (i < od_key_count):
		int k = od_keys[i]
		int ctrl = (od_key_mods[i] & 2) != 0
		int alt = (od_key_mods[i] & 4) != 0
		if (alt && ((k == 'L') || (k == 'C') || (k == 'K') || (k == 'B') || (k == 'S'))):
			od_show_view(k)
		else if ((k == 113) && ctrl):
			od_restart()
		else if (k == 113):
			if (od_view == 'S'):
				od_toggle_breakpoint()
			else:
				od_status(c"F2: breakpoints are set on source lines; open S and select a line")
		else if (k == 118):
			od_run_command(c"s")
		else if (k == 119):
			od_run_command(c"n")
		else if ((k == 120) && ctrl):
			od_run_command(c"fin")
		else if (k == 120):
			od_run_command(c"c")
		i = i + 1
	int n = 0
	while (n < od_ctx.nav_count):
		int nav = od_ctx.navs[n]
		if (nav == GFX_NAV_UP):
			od_move_selection(-1)
		else if (nav == GFX_NAV_DOWN):
			od_move_selection(1)
		else if (nav == GFX_NAV_PAGE_UP):
			od_move_selection(-16)
		else if (nav == GFX_NAV_PAGE_DOWN):
			od_move_selection(16)
		else if (nav == GFX_NAV_DELETE):
			if (od_view == 'B'):
				od_delete_selected_bp()
		n = n + 1


# ---- frame -----------------------------------------------------------------------

void od_draw_view(int x, int y, int w, int h):
	if (od_view == 'C'):
		int lw = w * 62 / 100
		if (w - lw < od_cw * 30):
			lw = w - od_cw * 30
		int th = h * 60 / 100
		od_draw_disas(x, y, lw, th)
		od_draw_regs(x + lw, y, w - lw, th)
		od_draw_dump(x, y + th, lw, h - th)
		od_draw_stack(x + lw, y + th, w - lw, h - th)
	else if (od_view == 'S'):
		int fw = od_cw * 26
		if (fw > w / 3):
			fw = w / 3
		od_draw_files(x, y, fw, h)
		od_draw_source(x + fw, y, w - fw, h)
	else if (od_view == 'L'):
		od_draw_log(x, y, w, h)
	else if (od_view == 'K'):
		od_draw_calls(x, y, w, h)
	else if (od_view == 'B'):
		od_draw_bps(x, y, w, h)


int od_frame_fn():
	if (gfx_window_poll(od_win) == 0):
		return 0
	od_frame = od_frame + 1
	od_net_step()
	# While the program runs, ask for its output (and the next stop).
	if ((strcmp(od_state, c"running") == 0) && (od_inflight == 0) && (od_queue.length == 0) && ((od_frame % 15) == 0)):
		od_enqueue(od_req_poll(), c"GET", c"/api/poll", c"", 0)
	od_poll_input()
	int w = od_win.width
	int h = od_win.height
	glViewport(0, 0, w, h)
	ui_begin(od_ctx, w, h)
	od_handle_keys()
	int y = od_toolbar(w)
	y = y + od_caption(y, w)
	int bottom = h - (od_lh + 8) - (od_lh + 6)
	od_draw_view(0, y, w, bottom - y)
	od_command_bar(bottom, w)
	od_status_bar(bottom + od_lh + 8, w)
	ui_end(od_ctx)
	gfx_window_swap(od_win)
	return 1


int main(int argc, int argv):
	od_win = gfx_window_open(c"wdbg", 1280, 800)
	if (od_win == 0):
		return 1
	od_rndr = new ui_renderer()
	if (ui_render_init(od_rndr) == 0):
		return 1
	ui_theme_light(&od_theme)
	od_theme.background = od_c_face()
	od_ctx = new ui_context()
	ui_context_init(od_ctx, od_rndr, &od_theme)
	od_font = ui_font_strike(UI_FACE_REGULAR, 13)
	od_font_bold = ui_font_strike(UI_FACE_BOLD, 13)
	od_cw = ui_font_glyph(od_font, '0').advance + 1
	od_lh = ui_text_height_strike(od_font) + 2
	od_ascent_pad = 1

	od_state = strclone(c"none")
	od_program = strclone(c"")
	od_where_func = strclone(c"")
	od_where_file = strclone(c"")
	od_where_text = strclone(c"")
	od_files = new list[char*]
	od_locals = new list[char*]
	od_args = new list[char*]
	od_backtrace = new list[char*]
	od_bps = new list[od_bp*]
	od_disas = new list[od_insn*]
	od_stack = new list[char*]
	od_log = new list[char*]
	od_sources = new list[od_source*]
	od_queue = new list[od_req*]
	od_cmd_buf = malloc(256)
	od_cmd_buf[0] = 0
	od_view = 'C'
	od_focus = od_p_disas()
	int i = 0
	while (i < 9):
		od_panes[i].sel = -1
		i = i + 1
	od_status(c"Connecting to wdbg_web")
	od_enqueue(od_req_state(), c"GET", c"/api/state", c"", 0)
	gfx_window_run(od_win, od_frame_fn)
	return 0
