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
- Locals live in memory in W (there is no register allocation), so a
  local changed between setjmp and longjmp keeps its latest value; C
  only guarantees that for volatile locals.
- longjmp skips 'defer' statements of the frames it unwinds, and the
  suspended generators of for-in loops in them are not freed.
- Not available on wasm (no way to unwind the host stack; the stubs
  there are placeholders) nor in gpu code. On arm64 with --pac=full the
  saved resume address is signed with the buffer address, so a
  corrupted or copied jmp_buf faults instead of jumping.
*/


# The three words the stubs save: resume address, stack pointer and
# frame pointer (on arm64 the x28 W stack pointer and x29).
struct jmp_buf:
	int pc
	int sp
	int fp
