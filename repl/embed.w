# The addon engine API (docs/projects/scripting.md, Phase E): a W host
# program embeds the in-process compiler of repl/core.w and loads W source
# addons into it at run time. The REPL and wdbg keep using repl/core.w
# directly; this module is the small, documented surface for hosts.
#
#   int engine_init(char* roots, int flags)
#       Start the engine once per process. roots: 0, or a ':'-separated
#       list of import roots searched before the working directory, so a
#       host can ship lib/ and structures/ beside itself (--import-root,
#       docs/projects/compilation_model.md §7). flags: engine_checked keeps
#       the session allocator's provenance tracking on (needed by checked
#       addons crossing attested boundaries; off by default, it costs ~5x
#       on allocation-heavy code). Returns 1, or 0 when a root is not a
#       directory. engine_init_sized(roots, flags, bytes) picks the JIT
#       buffer size (default engine_default_buffer: 64 MB, reserved with
#       MAP_NORESERVE in the low 2 GB, so only touched pages cost memory).
#       Faults in addon code run their handler on an alternate signal
#       stack, so a stack overflow is recovered like a segfault.
#   int engine_bind(char* name, char* signature, int address)
#       Expose a host function to addons: declares name in the session as
#       a pointer of the W function type signature ("fn(char*) -> void")
#       and stores address in it, so addon code calls name(...) natively.
#       1 on success. Bind before loading the addons that call it.
#   int engine_symbol(char* name)
#       Address of the newest session definition of name (a function's
#       entry point, a global's storage), or 0.
#   engine_result engine_load(char* addon, char* text)
#       Compile addon source text as one entry and run its top-level
#       statements. Diagnostics are captured, not printed: result.status
#       is engine_ok, engine_error (nothing changed) or engine_faulted (its
#       top-level code faulted and was rolled back), result.diagnostics
#       the compiler's NDJSON records (`w check --json` shape, "file"
#       naming the addon), valid until the next compile. Loading a name
#       that is already loaded reloads it (engine_reload).
#   int engine_call0(int address, int* ok) ... engine_call3(address, a, b, c, ok)
#       Call a session function with 0-3 word arguments inside the fault
#       window: a SIGSEGV/SIGFPE/SIGILL/SIGBUS or a stack overflow in the
#       callee returns 0 with *ok = 0 instead of killing the host, and
#       engine_fault_text names the addon and the faulting function
#       ("SIGSEGV in addon 'a' function on_crash (pc ..., address 0x0)").
#       Calls nest (addon -> host -> engine_call). A host may also call an
#       addon function pointer directly, with no window, on hot paths.
#       Addon calls must run on the thread that called engine_init.
#   engine_result engine_reload(char* addon, char* text)
#       Replace an addon with new source (text 0: reload its current
#       source, which resets its state). The new text is compile-checked
#       first: a compile error rejects the reload with the diagnostics and
#       leaves the running version and its state untouched. Otherwise the
#       session rolls back to the addon's checkpoint and compiles it and
#       every unit loaded after it again, in order (WoW's /reload): the
#       replaced code is released, not shadowed, so reloads do not fill
#       the buffer. Reload resets state: functions repatch, data does not
#       migrate (globals start over; keep what must survive in saved
#       variables, lib/saved_vars.w). Addresses from engine_symbol for the
#       reloaded units and everything after them are stale afterwards:
#       look them up again.
#   engine_generation* engine_checkpoint() / engine_rollback(g) /
#   engine_generation_free(g)
#       Capture the session between compiles; rolling back releases every
#       addon and bind loaded since (LIFO), and g can be rolled back to
#       again.
#   int engine_addon_symbol(char* addon, char* name)
#       Like engine_symbol, but only among the addon's own definitions.
#   void engine_shutdown()
#       Remove the engine's staged sources (call once, at exit).
import repl.core
import lib.signal
import lib.str
import lib.time


# engine_init flags
const int engine_checked = 1
# Reserved for the script profile (docs/projects/scripting.md P2).
const int engine_script = 2

const int engine_default_buffer = 67108864
const int engine_altstack_size = 262144

int engine_ready
int engine_flags
int engine_init_ms
# The host thread engine_init ran on: addon calls run there.
int engine_tid
# Set from engine_script by engine_init: the hook point for the
# compiler-side --profile=script switch (see engine_init).
int engine_script_profile_requested


# Add each ':'-separated root as an --import-root. 0 when one is not a
# directory (import_root_add would exit the process).
int engine_add_roots(char* roots):
	if (roots == 0): return 1
	list[char*] parts = split(roots, ':')
	int ok = 1
	for part in parts:
		if ((ok != 0) && (strlen(part) > 0)):
			char* absolute = strclone(part)
			if (path_is_absolute(absolute) == 0):
				char* cwd = cast(char*, malloc(4096))
				getcwd(cwd, 4096)
				char* prefix = strjoin(cwd, c"/")
				free(absolute)
				absolute = strjoin(prefix, part)
				free(prefix)
				free(cwd)
			if (import_root_is_dir(absolute)): import_root_add(absolute)
			else: ok = 0
			free(absolute)
	return ok


# Map the alternate signal stack the fault handlers run on (per thread:
# the host's main thread, where addon calls run). 1 on success.
int engine_altstack_arm():
	int alt = mmap(0, engine_altstack_size, 3, 34) /* RW, PRIVATE|ANONYMOUS */
	if ((alt < 0) && (alt > -4096)): return 0
	return signal_altstack_install(alt, engine_altstack_size) == 0


void engine_fault_record(int sig, int context);


int engine_init_sized(char* roots, int flags, int buffer_bytes):
	if (engine_ready): return 1
	int t0 = time_monotonic_ms()
	if (engine_add_roots(roots) == 0): return 0
	engine_flags = flags
	if (buffer_bytes <= 0): buffer_bytes = engine_default_buffer
	repl_buffer_size = buffer_bytes
	repl_provenance_off = (flags & engine_checked) == 0
	if (engine_altstack_arm()): repl_fault_flags = signal_sa_onstack
	# TODO(--profile=script, scripting.md P2): when the compiler-side
	# switch lands, enable it here for every addon compile, e.g.
	#   if (engine_script_profile_requested): <compiler global> = 1
	engine_script_profile_requested = (flags & engine_script) != 0
	# The AST front end with retained emission, as the REPL defaults to
	# (repl_ast_options without flags).
	ast_expressions_mode = 2
	ast_retain_mode = 1
	ast_emit_retained_mode = 1
	retained_semantic_mode = 1
	repl_semantic_mode = 1
	repl_init()
	# Faults are reported through engine_fault_text, not printed.
	repl_fault_hook = cast(int, engine_fault_record)
	engine_tid = repl_gettid()
	engine_ready = 1
	engine_init_ms = time_monotonic_ms() - t0
	return 1


int engine_init(char* roots, int flags):
	return engine_init_sized(roots, flags, 0)


# 1 when the session allocator tracks allocation provenance.
int engine_provenance_enabled():
	int at = sym_address(c"malloc_provenance_enabled")
	if (at == 0): return 0
	return load_word(cast(char*, at)) != 0


void engine_shutdown():
	if (engine_ready == 0): return;
	repl_session_end()
	repl_cleanup()


# ---------------------------------------------------------------------------
# E2: the host API. engine_bind declares a typed function-pointer global in
# the session and stores the host function's address in it, so addon code
# calls host_log(c"hi") natively through the pointer.

# 1 for a name that can be declared as a W identifier.
int engine_identifier(char* name):
	if ((name == 0) || (name[0] == 0)): return 0
	int i = 0
	while (name[i] != 0):
		int c = name[i]
		int alpha = ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || (c == '_')
		int digit = (c >= '0') && (c <= '9')
		if ((alpha == 0) && ((digit == 0) || (i == 0))): return 0
		i = i + 1
	return 1


# The session entry that declares a bound name: a function type and a
# pointer global of that type.
char* engine_bind_text(char* name, char* signature):
	return cstr(f"type __engine_fn_{name} = {signature}\n__engine_fn_{name}* {name}\n")


# Store a host address in the bound global's storage (session globals
# live in the JIT buffer at their symbol address).
int engine_bind_store(char* name, int address):
	int slot = sym_address(name)
	if (slot == 0): return 0
	save_word(cast(char*, slot), address)
	return 1


# Address of the newest defined session symbol called name (a function's
# entry point, a global's storage), or 0.
int engine_symbol(char* name):
	return sym_defined_address(name)


# ---------------------------------------------------------------------------
# E3: loading addons. Every compile the engine performs is a unit: an addon
# (source text compiled as one entry) or a bind. A unit remembers the
# checkpoint taken before it compiled and the range of symbol-table records
# it defined, so engine_reload can roll back to it (E5) and a fault report
# can name the addon a faulting function belongs to (E4).

struct engine_unit:
	char* name
	char* text
	# nonzero for a bind unit: the host address stored after it compiles
	int bind_address
	repl_state* checkpoint
	# repl_staged_count before it compiled (its staged files start here)
	int staged
	# its symbols are the records in [checkpoint.table_pos, table_end)
	int table_end


list[engine_unit*] engine_units
# The unit engine_compile is compiling and running, until it is kept or
# freed: a fault in its top-level code is attributed to it.
engine_unit* engine_loading


# The outcome of engine_load/engine_reload. status: engine_ok, engine_error
# (a compile error: nothing changed), engine_faulted (the addon's top-level
# code faulted and was rolled back; engine_fault_text says where) or
# engine_bad_request. diagnostics: the compiler's NDJSON records (one
# object per line, the `w check --json` shape, "file" naming the addon),
# owned by the engine and valid until the next compile.
struct engine_result:
	int status
	char* diagnostics
	int errors
	int warnings
	int ms


const int engine_ok = 1
const int engine_error = 0
const int engine_faulted = 2
const int engine_bad_request = -1


# Captured diagnostics of the compile in progress.
char* engine_diag_text
int engine_diag_length
int engine_diag_capacity
int engine_diag_errors
int engine_diag_warnings


# 1 when bytes[0..n) contains needle.
int engine_bytes_contain(char* bytes, int n, char* needle):
	int m = strlen(needle)
	int i = 0
	while (i + m <= n):
		int k = 0
		while ((k < m) && (bytes[i + k] == needle[k])): k = k + 1
		if (k == m): return 1
		i = i + 1
	return 0


# The compiler's diagnostic sink (compiler/diagnostics.w diag_sink): one
# complete NDJSON record per call.
void engine_diag_sink(char* bytes, int n):
	if (engine_diag_length + n + 1 > engine_diag_capacity):
		int capacity = (engine_diag_length + n + 1) * 2
		if (capacity < 1024): capacity = 1024
		engine_diag_text = realloc(engine_diag_text, engine_diag_capacity, capacity)
		engine_diag_capacity = capacity
	for i in range(n): engine_diag_text[engine_diag_length + i] = bytes[i]
	engine_diag_length = engine_diag_length + n
	engine_diag_text[engine_diag_length] = 0
	if (engine_bytes_contain(bytes, n, c"\"severity\": \"error\"")): engine_diag_errors = engine_diag_errors + 1
	else: engine_diag_warnings = engine_diag_warnings + 1


void engine_diag_begin():
	engine_diag_length = 0
	engine_diag_errors = 0
	engine_diag_warnings = 0
	if (engine_diag_text != 0): engine_diag_text[0] = 0
	diag_json = 1
	diag_word_size = word_size
	diag_sink = cast(int, engine_diag_sink)


# JSON string literal for text (quotes included).
char* engine_json_quote(char* text):
	char* escaped = replace(text, c"\\", c"\\\\")
	char* quoted = replace(escaped, c"\"", c"\\\"")
	free(escaped)
	char* result = cstr(f"\"{quoted}\"")
	free(quoted)
	return result


# Stop capturing; records that name the staged entry file name the addon.
void engine_diag_end(char* staged_path, char* addon):
	diag_sink = 0
	diag_json = 0
	if ((engine_diag_length == 0) || (staged_path == 0)): return;
	char* from = engine_json_quote(staged_path)
	char* to = engine_json_quote(addon)
	char* renamed = replace(engine_diag_text, from, to)
	free(from)
	free(to)
	free(engine_diag_text)
	engine_diag_text = renamed
	engine_diag_length = strlen(renamed)
	engine_diag_capacity = engine_diag_length + 1


# Remove the staged entry files from index first on: entries that rolled
# back. Indices are never reused, so a path stays unique.
void engine_unstage(int first):
	for i in range(first, repl_staged_count):
		char* path = repl_entry_path(repl_staging_dir, i)
		unlink(path)
		free(path)


engine_unit* engine_unit_new(char* name, char* text, int bind_address):
	engine_unit* u = new engine_unit
	u.name = strclone(name)
	u.text = strclone(text)
	u.bind_address = bind_address
	u.checkpoint = 0
	u.staged = 0
	u.table_end = 0
	return u


void engine_unit_free(engine_unit* u):
	free(u.name)
	free(u.text)
	if (u.checkpoint != 0): free(cast(char*, u.checkpoint))
	free(cast(char*, u))


void engine_fault_scope(int scan_top);
void engine_fault_describe();


# Compile and run one unit at the end of the session, capturing its
# diagnostics. On success the unit is appended to engine_units; otherwise
# repl_eval already rolled it back and the unit is freed.
engine_result engine_compile(engine_unit* u):
	engine_result res
	res.status = engine_bad_request
	res.diagnostics = 0
	res.errors = 0
	res.warnings = 0
	int t0 = time_monotonic_ms()
	if (repl_staging_dir == 0): repl_stage_init()
	u.checkpoint = new repl_state
	repl_state_capture(u.checkpoint)
	u.staged = repl_staged_count
	engine_diag_begin()
	engine_fault_scope(cast(int, &u))
	engine_loading = u
	repl_result r = repl_eval(u.text)
	engine_fault_scope(0)
	engine_diag_end(repl_staged_path, u.name)
	u.table_end = table_pos
	res.status = r.status
	# The rolled-back records are still intact here: name them now.
	if (r.status == engine_faulted): engine_fault_describe()
	engine_loading = 0
	if ((r.status == engine_ok) && (u.bind_address != 0)):
		if (engine_bind_store(u.name, u.bind_address) == 0): res.status = engine_error
	res.diagnostics = engine_diag_text
	if (res.diagnostics == 0): res.diagnostics = c""
	res.errors = engine_diag_errors
	res.warnings = engine_diag_warnings
	res.ms = time_monotonic_ms() - t0
	if (res.status == engine_ok):
		if (engine_units == 0): engine_units = new list[engine_unit*]
		engine_units.push(u)
	else:
		engine_unstage(u.staged)
		engine_unit_free(u)
	return res


# Index of the loaded unit called name in engine_units, or -1.
int engine_unit_index(char* name):
	if (engine_units == 0): return -1
	for i in range(engine_units.length):
		if ((engine_units[i].bind_address == 0) && (strcmp(engine_units[i].name, name) == 0)): return i
	return -1


# A bind is a unit too, so engine_reload replays it in order.
int engine_bind(char* name, char* signature, int address):
	if ((engine_ready == 0) || (address == 0)): return 0
	if ((engine_identifier(name) == 0) || (signature == 0) || (starts_with(signature, c"fn(") == 0)): return 0
	char* text = engine_bind_text(name, signature)
	engine_result r = engine_compile(engine_unit_new(name, text, address))
	free(text)
	return r.status == engine_ok


engine_result engine_reload(char* addon, char* text);


engine_result engine_load(char* addon, char* text):
	engine_result res
	res.status = engine_bad_request
	res.diagnostics = c""
	res.errors = 0
	res.warnings = 0
	res.ms = 0
	if ((engine_ready == 0) || (addon == 0) || (text == 0)): return res
	if (engine_unit_index(addon) >= 0): return engine_reload(addon, text)
	return engine_compile(engine_unit_new(addon, text, 0))


# Session address of the function or global called name that the addon
# defined itself (the newest one in its symbol range), or 0. Unlike
# engine_symbol this sees an addon's own on_event even when a later addon
# defines one too.
int engine_addon_symbol(char* addon, char* name):
	int i = engine_unit_index(addon)
	if (i < 0): return 0
	engine_unit* u = engine_units[i]
	int found = 0
	int t = u.checkpoint.table_pos
	while (t < u.table_end):
		int end = t + strlen(table + t)
		if ((strcmp(table + t, name) == 0) && (table[end + 1] == 'D')): found = load_int(table + end + 2)
		t = next_token(end)
	return found


# Name of the addon whose symbol range holds the record at name offset t,
# or 0.
char* engine_addon_of(int t):
	if (t < 0): return 0
	if ((engine_loading != 0) && (engine_loading.bind_address == 0) && (t >= engine_loading.checkpoint.table_pos)): return engine_loading.name
	if (engine_units == 0): return 0
	for i in range(engine_units.length):
		engine_unit* u = engine_units[i]
		if ((u.bind_address == 0) && (t >= u.checkpoint.table_pos) && (t < u.table_end)): return u.name
	return 0

# ---------------------------------------------------------------------------
# E4: calling into addons inside the fault window. A SIGSEGV, SIGFPE,
# SIGILL or SIGBUS (or a stack overflow) in the called code long-jumps back
# into the engine_call that armed the window, which reports it instead of
# letting the host die; the call returns 0 with *ok = 0, and
# engine_fault_text describes the fault:
#   SIGSEGV in addon 'tracker' function on_crash (pc 0x..., address 0x0)

# The last fault, recorded by engine_fault_record inside the handler.
int engine_fault_signal
int engine_fault_pc
int engine_fault_address
# Name offsets of the innermost session function at the fault and of the
# innermost frame that belongs to an addon, or -1.
int engine_fault_function
int engine_fault_frame
# Upper bound for the handler's stack scan: an address in the frame of the
# engine call that armed the window.
int engine_scan_top
char* engine_fault_text


# Name offset of the innermost session function whose code holds addr, or
# -1. Allocates nothing (the fault handler calls it).
int engine_function_at(int addr):
	int offset = addr - code_offset
	if ((offset < 0) || (offset >= codepos)): return -1
	int t = 0
	int best = -1
	int best_size = 0
	while (t < table_pos):
		int name_at = t
		while (table[t] != 0): t = t + 1
		if ((table[t + 1] == 'D') && (load_int(table + t + 10) == 2)):
			int start = load_int(table + t + 2)
			int size = load_int(table + t + 14)
			if ((size > 0) && (addr >= start) && (addr < start + size) && ((best < 0) || (size < best_size))):
				best = name_at
				best_size = size
		t = next_token(t)
	return best


# 1 when the record at name offset t lies in an addon's symbol range.
int engine_in_addon(int t):
	if (t < 0): return 0
	if ((engine_loading != 0) && (engine_loading.bind_address == 0) && (t >= engine_loading.checkpoint.table_pos)): return 1
	if (engine_units == 0): return 0
	for i in range(engine_units.length):
		engine_unit* u = engine_units[i]
		if ((u.bind_address == 0) && (t >= u.checkpoint.table_pos) && (t < u.table_end)): return 1
	return 0


# repl_fault_hook: record the fault and the functions it happened in, for
# engine_fault_describe after the long jump. Runs in the signal handler, on
# the alternate stack: no allocation. When the faulting pc is not in an
# addon function (a library routine the addon called, say), the stack from
# the fault's stack pointer up to the arming frame is scanned for return
# addresses into addon code.
void engine_fault_record(int sig, int context):
	engine_fault_signal = sig
	engine_fault_pc = ctx_eip(context)
	engine_fault_address = 0
	if ((sig == 11) || (sig == 7)): engine_fault_address = ctx_reg(context, sigcontext_cr2())
	engine_fault_function = engine_function_at(engine_fault_pc)
	engine_fault_frame = -1
	if (engine_in_addon(engine_fault_function)): engine_fault_frame = engine_fault_function
	int sp = ctx_esp(context)
	# Unsigned-safe: i386 stack addresses are negative as ints.
	int span = engine_scan_top - sp
	if ((engine_scan_top == 0) || (sp == 0) || (span <= 0) || (span > 67108864)): return;
	int at = sp
	int words = 0
	while ((words < span / __word_size__) && (words < 65536) && ((engine_fault_function < 0) || (engine_fault_frame < 0))):
		int f = engine_function_at(load_word(cast(char*, at)))
		if (f >= 0):
			if (engine_fault_function < 0): engine_fault_function = f
			if ((engine_fault_frame < 0) && engine_in_addon(f)): engine_fault_frame = f
		at = at + __word_size__
		words = words + 1


char* engine_signal_name(int sig):
	if (sig == 11): return c"SIGSEGV"
	if (sig == 4): return c"SIGILL"
	if (sig == 7): return c"SIGBUS"
	if (sig == 8): return c"SIGFPE"
	return c"signal"


# Display name of a session function: an addon's top-level code compiles
# into an anonymous __repl_N entry function.
char* engine_function_name(int t):
	if (t < 0): return c"?"
	if (starts_with(table + t, c"__repl_")): return c"<top level>"
	return table + t


# Build engine_fault_text from the recorded fault (outside the handler).
void engine_fault_describe():
	if (engine_fault_text != 0): free(engine_fault_text)
	char* sig = engine_signal_name(engine_fault_signal)
	char* pc = hex_word(engine_fault_pc)
	char* address = hex_word(engine_fault_address)
	char* where = c"outside addon code"
	char* owned = 0
	if (engine_fault_frame >= 0):
		char* addon = engine_addon_of(engine_fault_frame)
		char* fname = engine_function_name(engine_fault_frame)
		if ((engine_fault_function >= 0) && (engine_fault_function != engine_fault_frame)):
			owned = cstr(f"in addon '{addon}' function {fname} (in {engine_function_name(engine_fault_function)})")
		else: owned = cstr(f"in addon '{addon}' function {fname}")
		where = owned
	else if (engine_fault_function >= 0):
		owned = cstr(f"in session function {engine_function_name(engine_fault_function)}")
		where = owned
	engine_fault_text = cstr(f"{sig} {where} (pc {pc}, address {address})")
	if (owned != 0): free(owned)
	free(pc)
	free(address)


type engine_fn0 = fn() -> int


type engine_fn1 = fn(int) -> int


type engine_fn2 = fn(int, int) -> int


type engine_fn3 = fn(int, int, int) -> int


# Arm the fault window for one engine call. A call made while another is
# in flight (addon -> host -> engine_call) saves the outer window, which
# engine_window_leave puts back. Returns the saved state, or 0.
char* engine_window_enter(int scan_top):
	char* outer = 0
	if (repl_fault_active):
		outer = cast(char*, malloc((jmp_buf_words + 2) * __word_size__))
		for i in range(jmp_buf_words): save_word(outer + i * __word_size__, load_word(cast(char*, repl_fault_jump_buffer) + i * __word_size__))
		save_word(outer + jmp_buf_words * __word_size__, engine_scan_top)
		save_word(outer + (jmp_buf_words + 1) * __word_size__, repl_fault_tid)
	repl_fault_tid = engine_tid
	engine_scan_top = scan_top
	repl_fault_active = 1
	return outer


void engine_window_leave(char* outer):
	if (outer == 0):
		repl_fault_active = 0
		engine_scan_top = 0
		return;
	for i in range(jmp_buf_words): save_word(cast(char*, repl_fault_jump_buffer) + i * __word_size__, load_word(outer + i * __word_size__))
	engine_scan_top = load_word(outer + jmp_buf_words * __word_size__)
	repl_fault_tid = load_word(outer + (jmp_buf_words + 1) * __word_size__)
	repl_fault_active = 1
	free(outer)


# Set the stack-scan bound for a compile's fault window (repl_eval arms
# the window itself).
void engine_fault_scope(int scan_top):
	engine_scan_top = scan_top


# After the long jump: report and close the window.
int engine_window_fault(char* outer, int* ok):
	repl_keep_code = 0
	engine_window_leave(outer)
	engine_fault_describe()
	if (ok != 0): *ok = 0
	return 0


# Call the session function at address with 0-3 word arguments inside the
# fault window. *ok (when ok is not 0) is 1 when it returned and 0 when it
# faulted. A void function's result is meaningless.
int engine_call0(int address, int* ok):
	char* outer = engine_window_enter(cast(int, &address))
	if (repl_setjmp(repl_fault_jump_buffer)): return engine_window_fault(outer, ok)
	int result = (cast(engine_fn0*, address))()
	engine_window_leave(outer)
	if (ok != 0): *ok = 1
	return result


int engine_call1(int address, int a, int* ok):
	char* outer = engine_window_enter(cast(int, &address))
	if (repl_setjmp(repl_fault_jump_buffer)): return engine_window_fault(outer, ok)
	int result = (cast(engine_fn1*, address))(a)
	engine_window_leave(outer)
	if (ok != 0): *ok = 1
	return result


int engine_call2(int address, int a, int b, int* ok):
	char* outer = engine_window_enter(cast(int, &address))
	if (repl_setjmp(repl_fault_jump_buffer)): return engine_window_fault(outer, ok)
	int result = (cast(engine_fn2*, address))(a, b)
	engine_window_leave(outer)
	if (ok != 0): *ok = 1
	return result


int engine_call3(int address, int a, int b, int c, int* ok):
	char* outer = engine_window_enter(cast(int, &address))
	if (repl_setjmp(repl_fault_jump_buffer)): return engine_window_fault(outer, ok)
	int result = (cast(engine_fn3*, address))(a, b, c)
	engine_window_leave(outer)
	if (ok != 0): *ok = 1
	return result

# ---------------------------------------------------------------------------
# E5: generations. A checkpoint captures the session between compiles;
# rolling back to it releases everything compiled since (code, globals,
# symbols, types, imports, late-bind sites, staged files), LIFO. Reload is
# built on it: roll back to the addon's own checkpoint and compile it and
# every unit after it again, in order (WoW's /reload), so replaced code
# never accumulates in the buffer.

struct engine_generation:
	repl_state* state
	int units
	int staged


# Late-bind sites below a rollback point that a later definition had
# repatched into the released code are pointed back at the newest
# surviving definition of their name (or left alone when none survives).
void engine_sites_rebind(int released_from):
	int boundary = code_offset + released_from
	for k in range(repl_sites_count):
		char* site = repl_sites + k * 3 * __word_size__
		char* name = cast(char*, load_word(site))
		int slot = load_word(site + __word_size__)
		int direct = load_word(site + 2 * __word_size__)
		int target = 0
		if (direct == 0): target = be_addr_slot_read(slot)
		else: target = code_offset + slot + 4 + load_int32(code + slot)
		if ((target >= boundary) && (target < code_offset + code_size)):
			int t = sym_lookup(name)
			if ((t >= 0) && (table[t + 1] == 'D') && (load_int(table + t + 10) == 2)):
				int address = load_int(table + t + 2)
				if (direct == 0): be_addr_slot_write(slot, address)
				else: save_int(code + slot, address - (code_offset + slot + 4))


# Roll the session back to st (captured between compiles), as :reset does
# for its genesis snapshot, then drop the staged files from staged on.
void engine_restore(repl_state* st, int staged):
	repl_state_restore(st)
	current_function_symbol = st.function_symbol
	repl_discard_late_bind()
	repl_sites_truncate(st.sites_count)
	repl_state_clear_context()
	engine_sites_rebind(st.codepos)
	engine_unstage(staged)


# Free the units from index first on (they were rolled back).
void engine_units_truncate(int first):
	if (engine_units == 0): return;
	while (engine_units.length > first): engine_unit_free(engine_units.pop())


engine_generation* engine_checkpoint():
	engine_generation* g = new engine_generation
	g.state = new repl_state
	repl_state_capture(g.state)
	g.units = 0
	if (engine_units != 0): g.units = engine_units.length
	g.staged = repl_staged_count
	return g


# Roll back to g: every addon and bind loaded after it is gone. g stays
# valid for another rollback; engine_generation_free releases it.
void engine_rollback(engine_generation* g):
	engine_restore(g.state, g.staged)
	engine_units_truncate(g.units)


void engine_generation_free(engine_generation* g):
	free(cast(char*, g.state))
	free(cast(char*, g))


# Append b's diagnostics to a's (both engine-owned text).
char* engine_join_text(char* a, char* b):
	if ((a == 0) || (a[0] == 0)): return strclone(b)
	if ((b == 0) || (b[0] == 0)): return strclone(a)
	return strjoin(a, b)


char* engine_reload_text


# Reload an addon from new source (text 0: its current source, which
# resets its state). The new text is first compiled at the end of the
# session without running; a compile error there rejects the reload with
# the diagnostics and leaves the running version, and its state,
# untouched. Otherwise the session rolls back to the addon's checkpoint,
# compiles the new text, then every unit loaded after it, in order. If the
# new text faults in its top-level code the previous text is loaded again
# (status engine_faulted). A later unit that no longer compiles is dropped
# and its diagnostics are appended.
engine_result engine_reload(char* addon, char* text):
	engine_result res
	res.status = engine_bad_request
	res.diagnostics = c""
	res.errors = 0
	res.warnings = 0
	res.ms = 0
	int index = engine_unit_index(addon)
	if ((engine_ready == 0) || (index < 0)): return res
	int t0 = time_monotonic_ms()
	engine_unit* old = engine_units[index]
	char* source = text
	if (source == 0): source = old.text
	# 1. compile check at the end of the session, nothing runs
	engine_generation* probe = engine_checkpoint()
	repl_no_run = 1
	engine_diag_begin()
	repl_result checked = repl_eval(source)
	engine_diag_end(repl_staged_path, addon)
	repl_no_run = 0
	engine_rollback(probe)
	engine_generation_free(probe)
	if (checked.status != engine_ok):
		res.status = engine_error
		res.diagnostics = engine_diag_text
		res.errors = engine_diag_errors
		res.warnings = engine_diag_warnings
		res.ms = time_monotonic_ms() - t0
		return res
	# 2. roll back to the addon's checkpoint, keeping the units to replay
	list[engine_unit*] replay = new list[engine_unit*]
	for i in range(index + 1, engine_units.length): replay.push(engine_units[i])
	repl_state* st = old.checkpoint
	engine_restore(st, old.staged)
	while (engine_units.length > index): engine_units.pop()
	# 3. the addon itself, falling back to its previous text
	char* previous = strclone(old.text)
	res = engine_compile(engine_unit_new(addon, source, 0))
	char* log = strclone(res.diagnostics)
	if (res.status != engine_ok):
		engine_result back = engine_compile(engine_unit_new(addon, previous, 0))
		char* joined = engine_join_text(log, back.diagnostics)
		free(log)
		log = joined
	free(previous)
	engine_unit_free(old)
	# 4. everything after it
	int errors = res.errors
	int warnings = res.warnings
	for i in range(replay.length):
		engine_unit* u = replay[i]
		engine_result r = engine_compile(engine_unit_new(u.name, u.text, u.bind_address))
		if (r.status != engine_ok):
			char* joined = engine_join_text(log, r.diagnostics)
			free(log)
			log = joined
			errors = errors + r.errors
		engine_unit_free(u)
	if (engine_reload_text != 0): free(engine_reload_text)
	engine_reload_text = log
	res.diagnostics = log
	res.errors = errors
	res.warnings = warnings
	res.ms = time_monotonic_ms() - t0
	return res
