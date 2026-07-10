# Assembly-text source for the AArch64 runtime stubs committed as
# hand-hexed a64(op(...)) words in code_generator/arm64_asm.w (issue
# #170). Same format and role as stubs_x86.asm; see that file's header.
#
# arm64_asm.w emits through a64(op(msb, low)) rather than emit(), and
# some stubs vary by target (target_os == 1 selects Darwin, arm64_pac ==
# 2 adds PAC signing). The drift check compares against every op() word
# in source text order, so this file lists BOTH branches of each
# conditional, in the order they appear in the file, regardless of which
# one a given compile emits.

arch arm64

# Darwin (XNU) syscall convention helper: svc #0x80, carry-flag errors
# folded to the Linux -errno contract.
func arm64_darwin_svc
	svc #0x80
	b.cc .+8	# carry clear: success
	neg x0,x0	# error: return -errno

# syscall(nr, arg1, arg2, arg3): number in x8 (Linux) or x16 (Darwin,
# first variant listed), arguments in x0..x2.
func syscall
	ldr x16,[x28,#24]	# nr (darwin variant)
	ldr x8,[x28,#24]	# nr (linux variant)
	ldr x0,[x28,#16]	# arg1
	ldr x1,[x28,#8]	# arg2
	ldr x2,[x28]	# arg3
	svc #0	# linux variant; darwin calls arm64_darwin_svc
	ret

# syscall7(nr, a1..a6): arguments in x0..x5.
func syscall7
	ldr x16,[x28,#48]	# nr (darwin variant)
	ldr x8,[x28,#48]	# nr (linux variant)
	ldr x0,[x28,#40]	# a1
	ldr x1,[x28,#32]	# a2
	ldr x2,[x28,#24]	# a3
	ldr x3,[x28,#16]	# a4
	ldr x4,[x28,#8]	# a5
	ldr x5,[x28]	# a6
	svc #0	# linux variant; darwin calls arm64_darwin_svc
	ret

# syscall_fork() (darwin only): fork (2); x1 tells parent from child.
func syscall_fork
	movz x16,#2
	svc #0x80
	b.cc .+12	# success
	neg x0,x0	# error: return -errno
	ret
	cbz x1,.+8	# parent: return the pid
	movz x0,#0	# child: return 0
	ret

# syscall_pipe(fds) (darwin only): pipe (42) returns the two fds in
# x0/x1; store them as two 32-bit fds and return 0 (or -errno).
func syscall_pipe
	ldr x9,[x28]	# fds
	movz x16,#42
	svc #0x80
	b.cc .+12	# success
	neg x0,x0	# error: return -errno
	ret
	stp w0,w1,[x9]
	movz x0,#0
	ret

# get_context(ctx): store x0..x30 into the 31-slot context struct. The
# store is a source-level loop `str xi,[x9,#i*8]` for i = 0..30 built by
# OR-ing i into Rt and imm12; the base word listed here is the i=0 form.
func get_context
	ldr x9,[x28]	# ctx
	str x0,[x9]	# loop base: str xi,[x9,#i*8] for i = 0..30
	ret

# store_context(ctx): identical capture.
func store_context
	ldr x9,[x28]	# ctx
	str x0,[x9]	# loop base: str xi,[x9,#i*8] for i = 0..30
	ret

# repl_setjmp(buf): save the return address, W stack pointer and frame
# pointer into a 3-word buffer and return 0. The pacia is emitted only
# under --pac=full.
func repl_setjmp
	ldr x9,[x28]	# buf
	pacia x30,x9	# pac=full only
	str x30,[x9]
	str x28,[x9,#8]
	str x29,[x9,#16]
	movz x0,#0
	ret

# repl_longjmp(buf, val): restore the saved state and branch back to the
# repl_setjmp call site with val in x0.
func repl_longjmp
	ldr x0,[x28]	# val
	ldr x9,[x28,#8]	# buf
	ldr x30,[x9]
	autia x30,x9	# pac=full only
	ldr x28,[x9,#8]
	ldr x29,[x9,#16]
	ret

# gen_switch(int* save_wsp_here, int restore_wsp): the generator context
# switch (docs/projects/iteration.md), AArch64 flavor. paciza/autiza are
# emitted only under --pac=full (zero discriminator; see arm64_asm.w).
func gen_switch
	ldr x9,[x28,#8]	# save_wsp_here
	ldr x10,[x28]	# restore_wsp
	paciza x30	# pac=full only
	str x30,[x28,#-8]!	# push resume address
	str x28,[x9]	# *save_wsp_here = x28
	mov x28,x10	# switch stacks
	ldr x30,[x28],#8	# pop resume address
	autiza x30	# pac=full only
	ret
