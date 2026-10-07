/*
Non-local jumps, C's setjmp/longjmp (issue #435), for code translated
from C (Lua's error handling, SQLite's recovery paths) and for W code
that wants to unwind several frames at once.

	import lib.setjmp

	jmp_buf env
	if (setjmp(&env) == 0): work()            # somewhere below: longjmp(&env, 2)
	else: recover()

setjmp and longjmp are not defined here: they are the compiler's own
runtime stubs (repl_setjmp/repl_longjmp in code_generator/*_asm.w,
which the REPL and lib/stack_trace.w already use) under their C names,
available in every native program with or without this import. They
cannot be ordinary W functions: setjmp must record its CALLER's frame,
and a wrapper would record its own frame, which is gone by the time
longjmp returns into it. This file supplies the buffer type and the
contract.

Contract, as in C, with the W-specific differences marked:
- setjmp(&env) returns 0 when called directly; after longjmp(&env, v)
  it returns again, from the same call site, with v. W difference:
  v is passed through unchanged -- longjmp(&env, 0) makes setjmp return
  0 again rather than 1, so always pass a nonzero value.
- The function that called setjmp must still be running when longjmp
  is called (jumping into a frame that has returned is undefined).
- A function that calls setjmp keeps every local in memory (the
  compiler's register promotion, docs/projects/register_allocation_pgo.md
  §2.2, skips any body that names setjmp/longjmp), so a local of THAT
  function changed between setjmp and longjmp keeps its latest value; C
  only guarantees that for volatile locals. Other functions may hold
  locals in callee-saved registers (x86 esi/edi, x64 r12-r15): setjmp
  saves that set and longjmp restores it, so a frame unwound by longjmp
  cannot leak a register value into the setjmp caller's callers. The
  same contract binds hand-written asm: an asm body or stub must
  preserve ebx/esi/edi (x86), rbx/r12-r15 (x64) and x19-x28 (arm64).
- longjmp skips 'defer' statements of the frames it unwinds, and the
  suspended generators of for-in loops in them are not freed.
- Not available on wasm (no way to unwind the host stack; the stubs
  there are placeholders) nor in gpu code. On arm64 with --pac=full the
  saved resume address is signed with the buffer address, so a
  corrupted or copied jmp_buf faults instead of jumping.
*/


# The words the stubs save (jmp_buf_words in lib/lib.w): resume address,
# stack pointer and frame pointer (on arm64 the x28 W stack pointer and
# x29), then the callee-saved registers register promotion may use
# (x86: ebx esi edi in r0..r2; x64: rbx r12 r13 r14 r15 in r0..r4;
# arm64 saves nothing there yet, since it promotes nothing).
struct jmp_buf:
	int pc
	int sp
	int fp
	int r0
	int r1
	int r2
	int r3
	int r4
