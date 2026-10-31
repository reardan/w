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
#       naming the addon), valid until the next compile. A name that is
#       already loaded is a bad request.
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
	repl_result r = repl_eval(u.text)
	engine_diag_end(repl_staged_path, u.name)
	u.table_end = table_pos
	res.status = r.status
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


engine_result engine_load(char* addon, char* text):
	engine_result res
	res.status = engine_bad_request
	res.diagnostics = c""
	res.errors = 0
	res.warnings = 0
	res.ms = 0
	if ((engine_ready == 0) || (addon == 0) || (text == 0)): return res
	if (engine_unit_index(addon) >= 0): return res
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
	if ((engine_units == 0) || (t < 0)): return 0
	for i in range(engine_units.length):
		engine_unit* u = engine_units[i]
		if ((u.bind_address == 0) && (t >= u.checkpoint.table_pos) && (t < u.table_end)): return u.name
	return 0
