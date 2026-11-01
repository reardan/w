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


void script_profile_reset():
	script_profile_mode = 0
	if (script_profile_trusted != 0): script_profile_trusted.free()
	script_profile_trusted = 0
	script_profile_import_depth = 0
	script_profile_import_gate = 0


# compile_attempt: the file at path opened; remember it when it is an import.
void script_profile_note_open(char* path):
	if (script_profile_import_depth == 0): return
	if (script_profile_trusted == 0): script_profile_trusted = new map[char*, int]
	if (path in script_profile_trusted): return
	char* copy = strclone(path)
	script_profile_trusted[copy] = 1


# 1 when the construct at the current token must be checked.
int script_profile_applies():
	if (script_profile_mode == 0): return 0
	if (filename == 0): return 0
	if (script_profile_trusted == 0): return 1
	return (filename in script_profile_trusted) == 0


void script_profile_reject(char* message):
	if (script_profile_applies()): error(message)


# A committed identifier use (both front ends): the compiler's asm
# runtime stubs are raw entry points (system calls, thread and stack
# creation, context switches, sockets, setjmp/longjmp); only the pure
# byte-swap helpers stay available.
void script_profile_identifier(char* name):
	if (script_profile_mode == 0): return
	int t = sym_lookup(name)
	if (t < 0): return
	if ((sym_is_asm_stub(t) == 0) || (sym_decl_file_index(t) >= 0)): return
	if ((strcmp(name, c"swap_endian") == 0) || (strcmp(name, c"swap_endian16") == 0)): return
	if (script_profile_applies() == 0): return
	diag_part(c"script profile: built-in '")
	diag_part(name)
	error(c"' is not allowed")


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
