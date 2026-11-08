/*
The script profile (docs/projects/scripting.md §5.2, Phase P2): API
gating for in-process addon code. '--profile=script' on the command
line, or an embedding engine setting script_profile_mode = 1 before it
compiles an addon, rejects in the profiled sources:

  asm function blocks and raw_asm(...)      script profile: asm blocks are not allowed
                                            script profile: raw_asm is not allowed
  the compiler's asm runtime built-ins     script profile: built-in '<name>' is not allowed
  (syscall*, thread_create, ...)
  extern declarations, c_lib, c_import      script profile: extern declarations are not allowed
                                            script profile: c_lib is not allowed
                                            script profile: c_import is not allowed
  unsafe: blocks                            script profile: unsafe blocks are not allowed
  cast(T*, x), cast(fn-pointer, x)          script profile: cast to a pointer type is not allowed
  an import not found in an import root     script profile: import '<module>' is not in an import root
  a runtime system-layer name (open, write,  script profile: runtime function '<name>' is not visible to addon code
  unlink, kill, exit, mmap, ...)
  debugger                                  script profile: debugger statements are not allowed
  a module outside the addon's allowlist    script profile: '<name>' is declared in a module outside this addon's import roots

Scope: a source is profiled while script_profile_mode is set unless it
was opened as an import. Command-line inputs and REPL/engine entries
are profiled; every module compiled through an import (the
auto-imported runtime, lib/lib.w and the engine's preloaded modules,
the on-demand runtimes, and the curated modules an addon imports from
an import root) is trusted, wherever it resolved. The trust follows
the file path, so a generic or inline body replayed from a trusted
module stays trusted inside a profiled file, and a profiled file's own
generics are checked when instantiated. An import statement in a
profiled source must resolve inside an import root
(compile_relative_path): the roots are the allowlist (Phase P1,
tools/script_modules.txt).

The checks sit at shared choke points, so the AST and the streaming
front ends enforce them alike: program items and statements are parsed
by the same rules (grammar/program.w, grammar/statement.w,
grammar/asm_function.w, grammar/string_literal.w), every cast() of
either front end ends in coerce_explicit (grammar/promote.w), and both
identifier paths report a committed use through
script_profile_identifier (grammar/identifier.w,
grammar/ast_expression.w).

script_profile_mode is read at every check, so an engine may toggle it
between compiles; link_impl resets it for every command-line compile.
*/


# 1 = reject the profile's constructs in profiled sources. Set by
# --profile=script (link_impl's flag pre-scan) or by an embedding engine
# around the compile of an addon.
int script_profile_mode
# Paths opened as imports: never profiled (see above).
map[char*, int] script_profile_trusted
# >0 while compile_save compiles an import, so compile_attempt can tell
# an import from a root.
int script_profile_import_depth
# Set by import_statement for an import written in a profiled source;
# compile_relative_path consumes it.
int script_profile_import_gate


# Per-addon import allowlist (an embedding engine; scripting.md §5.2).
# While script_profile_roots_active is set, a profiled compile resolves
# its imports in these roots instead of the session-wide --import-root
# list: a gated import (written in a profiled source) searches only
# them, and a trusted module's own imports search them first, then the
# session roots and the upward search as usual. Cleaned absolute paths.
int script_profile_roots_active
list[char*] script_profile_roots
# Set by script_profile_seal once the engine's base session (the runtime
# and its preloaded modules) is compiled: every module opened after that
# (by an addon's imports, or by the host's own entries) is visible to an
# addon with its own allowlist only when it lies in one of its roots.
int script_profile_sealed
map[char*, int] script_profile_late


void script_profile_roots_end();


void script_profile_reset():
	script_profile_mode = 0
	script_profile_roots_end()
	if (script_profile_trusted != 0): script_profile_trusted.free()
	script_profile_trusted = 0
	if (script_profile_late != 0): script_profile_late.free()
	script_profile_late = 0
	script_profile_sealed = 0
	script_profile_import_depth = 0
	script_profile_import_gate = 0


# compile_attempt: the file at path opened; remember it when it is an import.
void script_profile_note_open(char* path):
	if (script_profile_import_depth == 0): return
	if (script_profile_trusted == 0): script_profile_trusted = new map[char*, int]
	if (path in script_profile_trusted): return
	char* copy = strclone(path)
	script_profile_trusted[copy] = 1
	if (script_profile_sealed):
		if (script_profile_late == 0): script_profile_late = new map[char*, int]
		script_profile_late[copy] = 1


# The engine's base session is complete (see script_profile_late).
void script_profile_seal():
	script_profile_sealed = 1


# 1 when the construct at the current token must be checked.
int script_profile_applies():
	if (script_profile_mode == 0): return 0
	if (filename == 0): return 0
	if (script_profile_trusted == 0): return 1
	return (filename in script_profile_trusted) == 0


void script_profile_reject(char* message):
	if (script_profile_applies()): error(message)


# Allowlist setup for the next profiled compiles: begin (an empty list:
# no new imports at all), add each root, end (back to the session's
# import roots, as on the command line).
void script_profile_roots_begin():
	script_profile_roots_end()
	script_profile_roots_active = 1


void script_profile_roots_add(char* root):
	if (script_profile_roots == 0): script_profile_roots = new list[char*]
	script_profile_roots.push(strclone(root))


void script_profile_roots_end():
	script_profile_roots_active = 0
	if (script_profile_roots == 0): return;
	for r in script_profile_roots: free(r)
	script_profile_roots.clear()


# 1 while a profiled compile has its own allowlist.
int script_profile_roots_on():
	return (script_profile_mode != 0) && (script_profile_roots_active != 0)


# path lies inside directory root (both absolute, '/'-separated).
int script_profile_under(char* path, char* root):
	if (starts_with(path, root) == 0): return 0
	return path[strlen(root)] == '/'


int script_profile_under_any(char* path, list[char*] roots):
	if (roots == 0): return 0
	for r in roots:
		if (script_profile_under(path, r)): return 1
	return 0


# path is the runtime file rel ('lib/linux.w'), wherever it resolved.
int script_profile_is_file(char* path, char* rel):
	if (strcmp(path, rel) == 0): return 1
	int n = strlen(path)
	int m = strlen(rel)
	if (n <= m): return 0
	return (path[n - m - 1] == '/') && (strcmp(path + n - m, rel) == 0)


# path is inside the runtime directory dir ('lib/__arch__/').
int script_profile_in_dir(char* path, char* dir):
	if (starts_with(path, dir)): return 1
	int i = 0
	while (path[i] != 0):
		if ((path[i] == '/') && starts_with(path + i + 1, dir)): return 1
		i = i + 1
	return 0


int script_profile_name_in(char* name, char** names):
	int i = 0
	while (names[i] != 0):
		if (strcmp(name, names[i]) == 0): return 1
		i = i + 1
	return 0


char** script_profile_lib_hidden


# The runtime's system layer (P2b): the session compiles lib/lib.w and the
# container runtime into every addon's namespace, and their ordinary W
# functions wrap system calls (open, write, unlink, mmap, kill, exit,
# ...). A profiled source may not name what these files declare: the
# Linux syscall wrapper modules and the per-architecture ones, the
# Windows stubs, the allocator's internals (only malloc, free and
# realloc stay), stack walking, valgrind requests, and lib/lib.w's
# file-descriptor I/O, startup and exit paths. Everything else in the
# runtime (strings, printing to stdout/stderr, lists, maps, f-strings,
# json) stays visible.
int script_profile_system_symbol(char* path, char* name):
	if (script_profile_in_dir(path, c"lib/__arch__/") || script_profile_in_dir(path, c"lib/arm64/") || script_profile_in_dir(path, c"lib/darwin/")): return 1
	if (script_profile_is_file(path, c"lib/linux.w") || script_profile_is_file(path, c"lib/syscalls_linux_x86.w") || script_profile_is_file(path, c"lib/win32_stubs.w")): return 1
	if (script_profile_is_file(path, c"lib/not_android.w") || script_profile_is_file(path, c"lib/context_x86_64.w") || script_profile_is_file(path, c"lib/stack_trace.w")): return 1
	if (script_profile_is_file(path, c"lib/memory_freelist.w") || script_profile_is_file(path, c"lib/memory_debug.w") || script_profile_is_file(path, c"lib/memory_provenance.w")): return 1
	if (script_profile_is_file(path, c"lib/valgrind.w")): return 1
	if (script_profile_is_file(path, c"lib/memory.w")):
		return (strcmp(name, c"malloc") != 0) && (strcmp(name, c"free") != 0) && (strcmp(name, c"realloc") != 0)
	if (script_profile_is_file(path, c"lib/lib.w")):
		if (script_profile_lib_hidden == 0):
			char** h = cast(char**, malloc(24 * __word_size__))
			h[0] = c"_main"
			h[1] = c"main"
			h[2] = c"exit"
			h[3] = c"environ_ptr"
			h[4] = c"open_or_create"
			h[5] = c"file_size"
			h[6] = c"write_string"
			h[7] = c"getchar_reset"
			h[8] = c"getchar_seek"
			h[9] = c"getchar_unbuffered"
			h[10] = c"getchar"
			h[11] = c"getchar_unbuffered_checked"
			h[12] = c"getchar_checked"
			h[13] = c"print_write_using"
			h[14] = c"print_write_checked"
			h[15] = c"print_write"
			h[16] = c"putc"
			h[17] = c"translate_syscall_failure"
			h[18] = c"print_last_error"
			h[19] = c"print_clear_error"
			h[20] = 0
			script_profile_lib_hidden = h
		return script_profile_name_in(name, script_profile_lib_hidden)
	return 0


# A module compiled after the base session (another addon's import, a
# host entry's) outside this addon's own roots, while it has an allowlist.
int script_profile_foreign_module(char* path):
	if ((script_profile_roots_on() == 0) || (script_profile_late == 0)): return 0
	if ((path in script_profile_late) == 0): return 0
	return script_profile_under_any(path, script_profile_roots) == 0


# A committed identifier use (both front ends, and alias.member): the
# compiler's asm runtime stubs are raw entry points (system calls, thread
# and stack creation, context switches, sockets, setjmp/longjmp); only
# the pure byte-swap helpers stay available. A name the runtime's system
# layer declares is not visible either (script_profile_system_symbol),
# nor one from a module outside this addon's own import roots.
void script_profile_identifier(char* name):
	if (script_profile_mode == 0): return
	int t = sym_lookup(name)
	if (t < 0): return
	int file_index = sym_decl_file_index(t)
	if (file_index < 0):
		if (sym_is_asm_stub(t) == 0): return
		if ((strcmp(name, c"swap_endian") == 0) || (strcmp(name, c"swap_endian16") == 0)): return
		if (script_profile_applies() == 0): return
		diag_part(c"script profile: built-in '")
		diag_part(name)
		error(c"' is not allowed")
		return
	char* path = debug_file_name(file_index)
	if ((path == 0) || (path[0] == 0)): return
	# Names an addon declares itself (or the host's own entries) are its own.
	if ((script_profile_trusted == 0) || ((path in script_profile_trusted) == 0)): return
	if (script_profile_system_symbol(path, name)):
		if (script_profile_applies() == 0): return
		diag_part(c"script profile: runtime function '")
		diag_part(name)
		error(c"' is not visible to addon code")
		return
	if (script_profile_foreign_module(path) && (starts_with(name, c"__w_") == 0)):
		if (script_profile_applies() == 0): return
		diag_part(c"script profile: '")
		diag_part(name)
		error(c"' is declared in a module outside this addon's import roots")


# coerce_explicit (every cast() of either front end): a pointer or
# function-pointer target is rejected whatever the operand. From an
# integer it forges an address; from another pointer it reinterprets
# memory, and from a function address it yields writable bytes inside
# the engine's RWX code buffer.
void script_profile_cast(int want):
	if (script_profile_mode == 0): return
	int real = type_unqualified(want)
	if ((type_get_pointer_level(real) == 0) && (real != 4)): return
	script_profile_reject(c"script profile: cast to a pointer type is not allowed")


# import_statement: arm the root-only rule for this import when the
# importing source is profiled.
void script_profile_gate_import():
	script_profile_import_gate = script_profile_applies()


# compile_relative_path, after every import root missed: a gated import
# may not fall back to the upward search.
void script_profile_import_outside_roots(char* spelling):
	diag_part(c"script profile: import '")
	diag_part(spelling)
	error(c"' is not in an import root")
