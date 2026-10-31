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
