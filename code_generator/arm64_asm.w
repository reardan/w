/*
AArch64 runtime stubs, the twin of code_generator/x64_asm.w. These are the
handful of routines the compiler emits into every arm64 executable. They
are leaf routines reached with blr (so x30 holds the return address) and
return with `ret` (br x30); unlike ordinary W functions they do not push a
return-address slot onto the W stack, so their argument offsets have no
return slot to skip (blr pushed nothing).

Argument layout at entry, top of the W stack (x28) first: the last declared
argument sits at [x28+0], earlier ones above it, and the callee's own
address is deepest. syscall(nr, a1, a2, a3) therefore finds a3 at [x28+0],
a2 at [x28+8], a1 at [x28+16] and nr at [x28+24].
*/
import code_generator.code_emitter
import code_generator.asm_text


void sym_define_declare_global_function(char* name); /* defined in symbol_table */
void sym_stub_alias(char* name); /* defined in symbol_table */
void sym_define_declare_global_function_arity(char* name, int num_args); /* defined in symbol_table */


# "str xI,[x9,#I*8]": get_context/store_context save register I into
# slot I of the context struct x9 points at.
char* arm64_context_store(int i):
	char* offset = c"]"
	if (i > 0): offset = strjoin(c",#", strjoin(itoa(i * 8), c"]"))
	return strjoin(c"str x", strjoin(itoa(i), strjoin(c",[x9", offset)))


# Darwin (XNU) syscall convention: BSD number in x16, svc #0x80, errors
# reported by the carry flag with a positive errno in x0. The b.cc skips
# the neg on success, so callers see the same -errno contract as Linux.
void arm64_darwin_svc():
	a64_asm(c"svc #0x80")
	a64_asm(c"b.cc .+8")   # carry clear: success
	a64_asm(c"neg x0,x0")   # error: return -errno


void define_asm_functions_arm64():
	# syscall(nr, arg1, arg2, arg3): Linux AArch64 passes the number in x8
	# and arguments in x0..x2; svc #0 traps. The result (or -errno) is in
	# x0. Darwin (target_os == 1) wants the number in x16 and svc #0x80,
	# and its carry-flag error convention is converted to -errno.
	# The stub reads exactly nr + 3 fixed stack slots, so record its arity:
	# a call with any other argument count would read garbage slots.
	sym_define_declare_global_function_arity(c"syscall", 4)
	if (target_os == 1): a64_asm(c"ldr x16,[x28,#24]")   # nr
	else: a64_asm(c"ldr x8,[x28,#24]")   # nr
	a64_asm(c"ldr x0,[x28,#16]")   # arg1
	a64_asm(c"ldr x1,[x28,#8]")   # arg2
	a64_asm(c"ldr x2,[x28]")   # arg3
	if (target_os == 1): arm64_darwin_svc()
	else: a64_asm(c"svc #0")
	a64_asm(c"ret")

	# syscall7(nr, a1..a6): arguments in x0..x5.
	sym_define_declare_global_function_arity(c"syscall7", 7)
	if (target_os == 1): a64_asm(c"ldr x16,[x28,#48]")   # nr
	else: a64_asm(c"ldr x8,[x28,#48]")   # nr
	a64_asm(c"ldr x0,[x28,#40]")   # a1
	a64_asm(c"ldr x1,[x28,#32]")   # a2
	a64_asm(c"ldr x2,[x28,#24]")   # a3
	a64_asm(c"ldr x3,[x28,#16]")   # a4
	a64_asm(c"ldr x4,[x28,#8]")   # a5
	a64_asm(c"ldr x5,[x28]")   # a6
	if (target_os == 1): arm64_darwin_svc()
	else: a64_asm(c"svc #0")
	a64_asm(c"ret")

	# Darwin-only helper stubs for the two BSD calls whose return
	# convention cannot be expressed through the generic stub: fork
	# reports parent/child in x1 and pipe returns both fds in x0/x1.
	# Emitted after the shared stubs so the Linux arm64 image stays
	# byte-identical.
	if (target_os == 1):
		# syscall_fork(): fork (2). On success x1 is 0 in the parent and
		# 1 in the child; fold to the child-sees-0 contract.
		sym_define_declare_global_function(c"syscall_fork")
		a64_asm(c"movz x16,#2; svc #0x80")
		a64_asm(c"b.cc .+12")   # success
		a64_asm(c"neg x0,x0")   # error: return -errno
		a64_asm(c"ret")
		a64_asm(c"cbz x1,.+8")   # parent: return the pid
		a64_asm(c"movz x0,#0")   # child: return 0
		a64_asm(c"ret")

		# syscall_pipe(fds): pipe (42) returns the read end in x0 and the
		# write end in x1; store them as two 32-bit fds like the other
		# targets and return 0 (or -errno).
		sym_define_declare_global_function(c"syscall_pipe")
		a64_asm(c"ldr x9,[x28]")   # fds
		a64_asm(c"movz x16,#42; svc #0x80")
		a64_asm(c"b.cc .+12")   # success
		a64_asm(c"neg x0,x0")   # error: return -errno
		a64_asm(c"ret; stp w0,w1,[x9]; movz x0,#0; ret")

		# signal_trampoline: the sa_tramp of every W signal handler
		# (rt_sigaction, lib/__arch__/arm64_darwin/syscalls.w). XNU
		# enters it, not the handler, with x0 = the handler, x1 =
		# infostyle, x2 = sig, x3 = siginfo, x4 = ucontext, x5 = token.
		# It calls handler(sig, ucontext) with the W convention on the
		# interrupted code's W stack (x28), then sigreturn(ucontext,
		# infostyle, token) resumes the interrupted context. The three
		# sigreturn arguments wait on the C stack, which W code never
		# touches. Never returns; brk if sigreturn fails.
		sym_define_declare_global_function(c"signal_trampoline")
		a64_asm(c"stp x1,x4,[sp,#-32]!; str x5,[sp,#16]")
		a64_asm(c"str x0,[x28,#-8]!")   # callee slot
		a64_asm(c"str x2,[x28,#-8]!")   # sig
		a64_asm(c"str x4,[x28,#-8]!")   # ucontext
		if (arm64_pac == 2): a64_asm(c"blraaz x0")
		else: a64_asm(c"blr x0")
		a64_asm(c"add x28,x28,#24")
		a64_asm(c"ldr x0,[sp,#8]")   # ucontext
		a64_asm(c"ldr x1,[sp]")   # infostyle
		a64_asm(c"ldr x2,[sp,#16]")   # token
		a64_asm(c"add sp,sp,#32")
		a64_asm(c"movz x16,#184")   # sigreturn
		a64_asm(c"svc #0x80; brk #1")

	# get_context(ctx): store x0..x30 into the 31-slot context struct.
	# x9 (loaded first) holds the pointer; it is scratch anyway.
	sym_define_declare_global_function(c"get_context")
	a64_asm(c"ldr x9,[x28]")   # ctx
	int i = 0
	while (i <= 30):
		a64_asm(arm64_context_store(i))   # str xi,[x9,#i*8]
		i = i + 1
	a64_asm(c"ret")

	# store_context(ctx): identical capture (the x86 variant preserves the
	# accumulator; the debugger does not depend on that distinction here).
	sym_define_declare_global_function(c"store_context")
	a64_asm(c"ldr x9,[x28]")   # ctx
	i = 0
	while (i <= 30):
		a64_asm(arm64_context_store(i))   # str xi,[x9,#i*8]
		i = i + 1
	a64_asm(c"ret")

	# repl_setjmp(buf): save the return address, W stack pointer and frame
	# pointer into a 3-word buffer and return 0. repl_longjmp resumes here.
	# pac=full: the resume address rests in the buffer signed with the
	# buffer address as discriminator (arm64.md D6), so a scribbled or
	# replayed buffer fails authentication in repl_longjmp.
	sym_define_declare_global_function(c"repl_setjmp")
	# Public C-style name for the same stub (lib/setjmp.w, issue #435)
	sym_stub_alias(c"setjmp")
	a64_asm(c"ldr x9,[x28]")   # buf
	if (arm64_pac == 2):
		# Sign a copy: x30 itself must stay plain for the ret below.
		a64_asm(c"mov x10,x30; pacia x10,x9; str x10,[x9]")
	else: a64_asm(c"str x30,[x9]")
	a64_asm(c"str x28,[x9,#8]; str x29,[x9,#16]; movz x0,#0; ret")

	# repl_longjmp(buf, val): restore the saved state and branch back to the
	# repl_setjmp call site with val in x0.
	sym_define_declare_global_function(c"repl_longjmp")
	# Public C-style name for the same stub (lib/setjmp.w, issue #435)
	sym_stub_alias(c"longjmp")
	a64_asm(c"ldr x0,[x28]")   # val
	a64_asm(c"ldr x9,[x28,#8]")   # buf
	a64_asm(c"ldr x30,[x9]")
	if (arm64_pac == 2): a64_asm(c"autia x30,x9")
	a64_asm(c"ldr x28,[x9,#8]; ldr x29,[x9,#16]; ret")

	# gen_switch(int* save_wsp_here, int restore_wsp): the generator context
	# switch (docs/projects/iteration.md), AArch64 flavor. W keeps no live
	# values in callee-saved registers across calls, so only the resume
	# address (x30), the frame pointer (x29: every framed function's
	# return unwinds through it) and the W stack pointer (x28) must be
	# preserved. Push the resume address and x29 on the current stack,
	# store x28 through arg1, load arg2 into x28, pop the x29 and resume
	# address saved there and return on it. lib/generator.w seeds a fresh
	# generator stack with a zero x29 (__w_gen_switch_regs), so the
	# body's frame chain ends there.
	# pac=full: the pushed resume address is signed with ZERO discriminator
	# (paciza/autiza), not the stack address — __w_gen_create seeds a fresh
	# generator stack with the body's entry address exactly as it received
	# it, i.e. already zero-disc signed by materialization, so first resume
	# and every later suspend/resume authenticate under one convention and
	# lib/generator.w needs no target-specific code.
	sym_define_declare_global_function(c"gen_switch")
	a64_asm(c"ldr x9,[x28,#8]")   # save_wsp_here
	a64_asm(c"ldr x10,[x28]")   # restore_wsp
	if (arm64_pac == 2): a64_asm(c"paciza x30")
	a64_asm(c"str x30,[x28,#-8]!")   # push resume address
	a64_asm(c"str x29,[x28,#-8]!")   # push frame pointer
	a64_asm(c"str x28,[x9]")   # *save_wsp_here = x28
	a64_asm(c"mov x28,x10")   # switch stacks
	a64_asm(c"ldr x29,[x28],#8")   # pop frame pointer
	a64_asm(c"ldr x30,[x28],#8")   # pop resume address
	if (arm64_pac == 2): a64_asm(c"autiza x30")
	a64_asm(c"ret")
