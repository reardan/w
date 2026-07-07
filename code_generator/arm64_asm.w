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


void sym_define_declare_global_function(char* name); /* defined in symbol_table */
void a64(int w);                                     /* defined in arm64.w */


# Darwin (XNU) syscall convention: BSD number in x16, svc #0x80, errors
# reported by the carry flag with a positive errno in x0. The b.cc skips
# the neg on success, so callers see the same -errno contract as Linux.
void arm64_darwin_svc():
	a64(op(0xd4, 0x001001))   # svc #0x80
	a64(op(0x54, 0x000043))   # b.cc .+8  (carry clear: success)
	a64(op(0xcb, 0x0003e0))   # neg x0,x0 (error: return -errno)


void define_asm_functions_arm64():
	# syscall(nr, arg1, arg2, arg3): Linux AArch64 passes the number in x8
	# and arguments in x0..x2; svc #0 traps. The result (or -errno) is in
	# x0. Darwin (target_os == 1) wants the number in x16 and svc #0x80,
	# and its carry-flag error convention is converted to -errno.
	sym_define_declare_global_function(c"syscall")
	if (target_os == 1):
		a64(op(0xf9, 0x400f90))   # ldr x16,[x28,#24] (nr)
	else:
		a64(op(0xf9, 0x400f88))   # ldr x8,[x28,#24]  (nr)
	a64(op(0xf9, 0x400b80))   # ldr x0,[x28,#16]  (arg1)
	a64(op(0xf9, 0x400781))   # ldr x1,[x28,#8]   (arg2)
	a64(op(0xf9, 0x400382))   # ldr x2,[x28,#0]   (arg3)
	if (target_os == 1):
		arm64_darwin_svc()
	else:
		a64(op(0xd4, 0x000001))   # svc #0
	a64(op(0xd6, 0x5f03c0))   # ret

	# syscall7(nr, a1..a6): arguments in x0..x5.
	sym_define_declare_global_function(c"syscall7")
	if (target_os == 1):
		a64(op(0xf9, 0x401b90))   # ldr x16,[x28,#48] (nr)
	else:
		a64(op(0xf9, 0x401b88))   # ldr x8,[x28,#48]  (nr)
	a64(op(0xf9, 0x401780))   # ldr x0,[x28,#40]  (a1)
	a64(op(0xf9, 0x401381))   # ldr x1,[x28,#32]  (a2)
	a64(op(0xf9, 0x400f82))   # ldr x2,[x28,#24]  (a3)
	a64(op(0xf9, 0x400b83))   # ldr x3,[x28,#16]  (a4)
	a64(op(0xf9, 0x400784))   # ldr x4,[x28,#8]   (a5)
	a64(op(0xf9, 0x400385))   # ldr x5,[x28,#0]   (a6)
	if (target_os == 1):
		arm64_darwin_svc()
	else:
		a64(op(0xd4, 0x000001))   # svc #0
	a64(op(0xd6, 0x5f03c0))   # ret

	# Darwin-only helper stubs for the two BSD calls whose return
	# convention cannot be expressed through the generic stub: fork
	# reports parent/child in x1 and pipe returns both fds in x0/x1.
	# Emitted after the shared stubs so the Linux arm64 image stays
	# byte-identical.
	if (target_os == 1):
		# syscall_fork(): fork (2). On success x1 is 0 in the parent and
		# 1 in the child; fold to the child-sees-0 contract.
		sym_define_declare_global_function(c"syscall_fork")
		a64(op(0xd2, 0x800050))   # movz x16,#2
		a64(op(0xd4, 0x001001))   # svc #0x80
		a64(op(0x54, 0x000063))   # b.cc .+12 (success)
		a64(op(0xcb, 0x0003e0))   # neg x0,x0 (error: return -errno)
		a64(op(0xd6, 0x5f03c0))   # ret
		a64(op(0xb4, 0x000041))   # cbz x1,.+8 (parent: return the pid)
		a64(op(0xd2, 0x800000))   # movz x0,#0 (child: return 0)
		a64(op(0xd6, 0x5f03c0))   # ret

		# syscall_pipe(fds): pipe (42) returns the read end in x0 and the
		# write end in x1; store them as two 32-bit fds like the other
		# targets and return 0 (or -errno).
		sym_define_declare_global_function(c"syscall_pipe")
		a64(op(0xf9, 0x400389))   # ldr x9,[x28,#0]  (fds)
		a64(op(0xd2, 0x800550))   # movz x16,#42
		a64(op(0xd4, 0x001001))   # svc #0x80
		a64(op(0x54, 0x000063))   # b.cc .+12 (success)
		a64(op(0xcb, 0x0003e0))   # neg x0,x0 (error: return -errno)
		a64(op(0xd6, 0x5f03c0))   # ret
		a64(op(0x29, 0x000520))   # stp w0,w1,[x9]
		a64(op(0xd2, 0x800000))   # movz x0,#0
		a64(op(0xd6, 0x5f03c0))   # ret

	# get_context(ctx): store x0..x30 into the 31-slot context struct.
	# x9 (loaded first) holds the pointer; it is scratch anyway.
	sym_define_declare_global_function(c"get_context")
	a64(op(0xf9, 0x400389))   # ldr x9,[x28]  (ctx)
	int i = 0
	while (i <= 30):
		a64(op(0xf9, 0x000120) | i | (i << 10))   # str xi,[x9,#i*8]
		i = i + 1
	a64(op(0xd6, 0x5f03c0))   # ret

	# store_context(ctx): identical capture (the x86 variant preserves the
	# accumulator; the debugger does not depend on that distinction here).
	sym_define_declare_global_function(c"store_context")
	a64(op(0xf9, 0x400389))   # ldr x9,[x28]  (ctx)
	i = 0
	while (i <= 30):
		a64(op(0xf9, 0x000120) | i | (i << 10))   # str xi,[x9,#i*8]
		i = i + 1
	a64(op(0xd6, 0x5f03c0))   # ret

	# repl_setjmp(buf): save the return address, W stack pointer and frame
	# pointer into a 3-word buffer and return 0. repl_longjmp resumes here.
	sym_define_declare_global_function(c"repl_setjmp")
	a64(op(0xf9, 0x400389))   # ldr x9,[x28]  (buf)
	a64(op(0xf9, 0x00013e))   # str x30,[x9,#0]
	a64(op(0xf9, 0x00053c))   # str x28,[x9,#8]
	a64(op(0xf9, 0x00093d))   # str x29,[x9,#16]
	a64(op(0xd2, 0x800000))   # movz x0,#0
	a64(op(0xd6, 0x5f03c0))   # ret

	# repl_longjmp(buf, val): restore the saved state and branch back to the
	# repl_setjmp call site with val in x0.
	sym_define_declare_global_function(c"repl_longjmp")
	a64(op(0xf9, 0x400380))   # ldr x0,[x28,#0]  (val)
	a64(op(0xf9, 0x400789))   # ldr x9,[x28,#8]  (buf)
	a64(op(0xf9, 0x40013e))   # ldr x30,[x9,#0]
	a64(op(0xf9, 0x40053c))   # ldr x28,[x9,#8]
	a64(op(0xf9, 0x40093d))   # ldr x29,[x9,#16]
	a64(op(0xd6, 0x5f03c0))   # ret

	# gen_switch(int* save_wsp_here, int restore_wsp): the generator context
	# switch (docs/projects/iteration.md), AArch64 flavor. W keeps no live
	# values in callee-saved registers across calls, so only the resume
	# address (x30) and the W stack pointer (x28) must be preserved. Push the
	# resume address on the current stack, store x28 through arg1, load arg2
	# into x28, pop the resume address saved there and return on it.
	sym_define_declare_global_function(c"gen_switch")
	a64(op(0xf9, 0x400789))   # ldr x9,[x28,#8]   (save_wsp_here)
	a64(op(0xf9, 0x40038a))   # ldr x10,[x28,#0]  (restore_wsp)
	a64(op(0xf8, 0x1f8f9e))   # str x30,[x28,#-8]!  (push resume address)
	a64(op(0xf9, 0x00013c))   # str x28,[x9]        (*save_wsp_here = x28)
	a64(op(0xaa, 0x0a03fc))   # mov x28,x10         (switch stacks)
	a64(op(0xf8, 0x40879e))   # ldr x30,[x28],#8    (pop resume address)
	a64(op(0xd6, 0x5f03c0))   # ret
