/*
AArch64 support for the in-process engine (docs/projects/scripting.md
Phase A1, Linux; Phase A2, macOS, prepared but untested). repl/core.w
calls into this module only where __target_isa__ is 1; the x86 family
keeps its own buffer, thunks and handlers in core.w. Everything here is
plain runtime code, so the module compiles (unused) for every target.

Code buffer. The compiler's symbol table and backpatch chains store
addresses in 32-bit fields, and an arm64 address slot (adrp+add) must
round-trip a chain link below 2^31, so JIT code and its inline globals
must live in the low 2 GB, as x64 gets with MAP_32BIT. AArch64 has no
MAP_32BIT: repl_a64_map_code asks for the buffer at a series of fixed
hints below 2 GB with MAP_FIXED_NOREPLACE (lib/__arch__/arm64/jit_host.w)
and keeps the first that lands exactly there. On macOS the 4 GB
__PAGEZERO of every arm64 Mach-O image covers the whole low range, so
the probe fails there with a diagnostic (A2's remaining work).

Instruction cache. AArch64 does not keep the instruction cache coherent
with data writes: every byte the compiler writes into the buffer must be
cleaned to the point of unification (dc cvau) and the stale instruction
lines invalidated (ic ivau), then dsb ish / isb, before it runs. That
includes code written into *older* parts of the buffer: late-binding
repatches (#114), prototype backpatch chains a later definition
resolves, rollback reusing offsets. repl_jit_commit therefore flushes the
whole used range [buffer, buffer + codepos) after every compile and every
repatch, which is linear in the session's code size (tens of
microseconds per megabyte on current cores, and nothing under qemu,
which tracks self-modifying code itself). It is the one helper every
path goes through, so a narrower dirty range can replace it later
without auditing call sites. On Linux the sequence runs from a small
user-mode stub (repl_a64_flush; SCTLR_EL1.UCI/UCT let EL0 issue it and
read CTR_EL0 for the line sizes, and CTR_EL0.IDC/DIC skip the halves the
hardware does not need); on macOS it is libSystem's
sys_icache_invalidate.

Faults. Linux delivers an rt signal with sig in x0, the siginfo in x1
and the ucontext in x2, x30 pointing at the SA_RESTORER trampoline,
and sp on the signal stack. W code never uses sp: the W stack is x28,
and the entry stub grows it down from the initial sp, so a signal frame
built below sp would land on live W frames. Every handler therefore
runs on an alternate signal stack (SA_ONSTACK, repl_a64_altstack). A
per-handler thunk on the stub page saves x30, reserves a 128 KB W-stack
region on that alternate stack below the kernel's frame (sp moves past
it, so a nested signal cannot land on it), points x28 there and calls
handler(sig, &uc_mcontext) with the W convention. The handler returns
through the restorer, whose rt_sigreturn resumes the context.

Recovery does not long-jump out of the handler, as the x86 handlers do:
that would leave sp inside the alternate stack, and the kernel would
treat the next fault as nested on it. repl_a64_fault_resume instead
rewrites the context -- pc to a function that long-jumps to the fault
window's checkpoint, x28 to the W stack pointer saved by that
checkpoint's repl_setjmp -- and the handler returns: rt_sigreturn
restores sp, the signal mask and every other register, and the resumed
code abandons the faulting frames exactly like a long jump would. The
saved x28 is a valid stack even when the fault was a W stack overflow.

macOS (untested: needs a Mac run). XNU enters sa_tramp, not the
handler: x0 = the handler, x1 = infostyle, x2 = sig, x3 = siginfo, x4 =
ucontext, x5 = token, sp on the signal stack. The Darwin trampoline
below does the same stack switch, calls handler(sig, uc->uc_mcontext)
and ends with sigreturn(ucontext, infostyle, token), which honours the
rewritten pc/x28 the same way (debugger/sigcontext.w reads the Darwin
mcontext layout once sigcontext_darwin is set).

Stub bytes are hand-encoded A64 words (the in-tree text assembler has no
system instructions); each carries its mnemonic, and the sequences were
cross-checked with llvm-mc. The stub page is written read-write, then
switched to read-execute (lib/signal.w's W^X rule); Linux synchronizes
the instruction cache for the page on that mprotect.
*/
import lib.lib
import lib.__arch__.jit_host
import code_generator.code_emitter
import debugger.sigcontext


# Lowest and highest fixed hints repl_a64_map_code tries, and the step.
# The range is the one MAP_32BIT uses on x86-64 (1-2 GB): above the
# image and its brk heap, below the 2^31 limit of the address fields.
const int repl_a64_hint_first = 0x40000000
const int repl_a64_hint_step = 0x04000000
const int repl_a64_low_limit = 0x7fff0000

# Alternate signal stack, and the W-stack region each handler thunk
# reserves at its top (the rest holds the kernel's signal frame, which
# grows with SVE/SME register state).
const int repl_a64_altstack_size = 524288
const int repl_a64_page_size = 16384

int repl_a64_page
int repl_a64_pos
int repl_a64_restorer
int repl_a64_flush_stub
int repl_a64_darwin_tramp
int repl_a64_altstack
int* repl_a64_act
# Handler thunks already emitted: (handler, thunk) pairs.
int[8] repl_a64_thunk_handlers
int[8] repl_a64_thunk_addresses
int repl_a64_thunk_count


type __repl_a64_flush_callback = fn(int, int) -> void


# Make the in-process compiler emit AArch64 code for this OS: the A64
# instruction emitter, and on macOS the Darwin syscall stubs and the
# Mach-O-era runtime conventions (target_os 1). data_split stays 0:
# globals stay inline in the executable buffer, as on x86/x64.
void repl_a64_configure():
	target_isa = 1
	target_os = 0
	if (jit_host_darwin()):
		target_os = 1
		target_apple_platform = 1
		sigcontext_darwin = 1


# Map the executable code buffer below 2 GB (see the header). Returns
# its address; a session that cannot get one stops here with a reason.
int repl_a64_map_code(int size):
	int hint = repl_a64_hint_first
	while (hint + size <= repl_a64_low_limit):
		int got = jit_host_map(hint, size)
		if (got == hint): return got
		# Taken (-EEXIST), or a kernel without MAP_FIXED_NOREPLACE put it
		# elsewhere: release a misplaced mapping and try the next hint.
		if ((got > 0) || (got < -4095)): munmap(got, size)
		hint = hint + repl_a64_hint_step
	if (jit_host_darwin()):
		println2(c"error: the in-process engine needs its code buffer below 2 GB, which the 4 GB __PAGEZERO of an arm64 macOS image does not allow (docs/projects/scripting.md, Phase A2)")
	else: println2(c"error: could not map the in-process code buffer below 2 GB")
	exit(1)
	return 0


# The A64 back end emits string descriptors into the data segment even
# with data_split 0 (grammar/string_literal.w), so the session needs one:
# the top eighth of the code mapping becomes a fixed data arena (data ==
# data_offset: in process, a vaddr is its own host address), and the
# rest stays code. Returns the code part's size. ensure_data stops the
# session when the arena is full (code_emitter.w's data_fixed_exhausted).
int repl_a64_data_init(int buffer, int size):
	data_size = size >> 3
	data_offset = buffer + size - data_size
	data = cast(char*, data_offset)
	datapos = 0
	return size - data_size


# Word-align the next inline global: AArch64 atomics (ldar/stlr/ldxr)
# fault on a misaligned address, and the code stream is only 4-byte
# aligned. grammar/program.w and code_generator/global_ast.w do the same
# for module globals compiled in process.
void repl_a64_align_global():
	if (target_isa == 1):
		while ((codepos & 7) != 0): emit_int8(0)


void repl_a64_word(int word):
	save_int32(cast(char*, repl_a64_page + repl_a64_pos), word)
	repl_a64_pos = repl_a64_pos + 4


void repl_a64_page_writable(int writable):
	int prot = 5 /* R+X */
	if (writable): prot = 3 /* R+W */
	asserts(c"mprotect of the arm64 stub page failed", mprotect(repl_a64_page, repl_a64_page_size, prot) == 0)


# The stub page: the Linux rt_sigreturn restorer, the cache-maintenance
# stub, the Darwin signal trampoline, then handler thunks as they are
# installed.
void repl_a64_stubs_init():
	if (repl_a64_page != 0): return;
	repl_a64_page = mmap(0, repl_a64_page_size, 3, 34) /* RW, PRIVATE|ANONYMOUS */
	asserts(c"mmap of the arm64 stub page failed", (repl_a64_page > 0) | (repl_a64_page < -4095))

	repl_a64_restorer = repl_a64_page + repl_a64_pos
	repl_a64_word(op(0xd2, 0x801168))   # mov x8, #139  (rt_sigreturn)
	repl_a64_word(op(0xd4, 0x000001))   # svc #0

	# flush(start, end): W leaf stub (args on the W stack, end at [x28]).
	repl_a64_flush_stub = repl_a64_page + repl_a64_pos
	repl_a64_word(op(0xf9, 0x400780))   # ldr x0, [x28, #8]   start
	repl_a64_word(op(0xf9, 0x400381))   # ldr x1, [x28]       end
	repl_a64_word(op(0xd5, 0x3b0023))   # mrs x3, ctr_el0
	repl_a64_word(op(0x37, 0xe00143))   # tbnz w3, #28, 1f    IDC: no clean needed
	repl_a64_word(op(0xd3, 0x504c64))   # ubfx x4, x3, #16, #4  DminLine (log2 words)
	repl_a64_word(op(0xd2, 0x800085))   # mov x5, #4
	repl_a64_word(op(0x9a, 0xc420a5))   # lsl x5, x5, x4      data line bytes
	repl_a64_word(op(0xd1, 0x0004a6))   # sub x6, x5, #1
	repl_a64_word(op(0x8a, 0x260007))   # bic x7, x0, x6      line-aligned start
	repl_a64_word(op(0xd5, 0x0b7b27))   # 2: dc cvau, x7
	repl_a64_word(op(0x8b, 0x0500e7))   # add x7, x7, x5
	repl_a64_word(op(0xeb, 0x0100ff))   # cmp x7, x1
	repl_a64_word(op(0x54, 0xffffa3))   # b.lo 2b
	repl_a64_word(op(0xd5, 0x033b9f))   # 1: dsb ish
	repl_a64_word(op(0x37, 0xe80163))   # tbnz w3, #29, 3f    DIC: no invalidate needed
	repl_a64_word(op(0x92, 0x400c64))   # and x4, x3, #0xf    IminLine (log2 words)
	repl_a64_word(op(0xd2, 0x800085))   # mov x5, #4
	repl_a64_word(op(0x9a, 0xc420a5))   # lsl x5, x5, x4      instruction line bytes
	repl_a64_word(op(0xd1, 0x0004a6))   # sub x6, x5, #1
	repl_a64_word(op(0x8a, 0x260007))   # bic x7, x0, x6
	repl_a64_word(op(0xd5, 0x0b7527))   # 4: ic ivau, x7
	repl_a64_word(op(0x8b, 0x0500e7))   # add x7, x7, x5
	repl_a64_word(op(0xeb, 0x0100ff))   # cmp x7, x1
	repl_a64_word(op(0x54, 0xffffa3))   # b.lo 4b
	repl_a64_word(op(0xd5, 0x033b9f))   # dsb ish
	repl_a64_word(op(0xd5, 0x033fdf))   # 3: isb
	repl_a64_word(op(0xd6, 0x5f03c0))   # ret

	# Darwin sa_tramp (untested: needs a Mac run). See the header.
	repl_a64_darwin_tramp = repl_a64_page + repl_a64_pos
	repl_a64_word(op(0xa9, 0xbe13e1))   # stp x1, x4, [sp, #-32]!   infostyle, ucontext
	repl_a64_word(op(0xf9, 0x000be5))   # str x5, [sp, #16]         token
	repl_a64_word(op(0x91, 0x0003e9))   # mov x9, sp
	repl_a64_word(op(0xd1, 0x4083ff))   # sub sp, sp, #32, lsl #12  128 KB W stack
	repl_a64_word(op(0xaa, 0x0903fc))   # mov x28, x9
	repl_a64_word(op(0xf8, 0x1f8f80))   # str x0, [x28, #-8]!       callee slot
	repl_a64_word(op(0xf8, 0x1f8f82))   # str x2, [x28, #-8]!       sig
	repl_a64_word(op(0xf9, 0x40188b))   # ldr x11, [x4, #48]        uc->uc_mcontext
	repl_a64_word(op(0xf8, 0x1f8f8b))   # str x11, [x28, #-8]!
	repl_a64_word(op(0xd6, 0x3f0000))   # blr x0
	repl_a64_word(op(0x91, 0x4083ff))   # add sp, sp, #32, lsl #12
	repl_a64_word(op(0xf9, 0x4007e0))   # ldr x0, [sp, #8]          ucontext
	repl_a64_word(op(0xf9, 0x4003e1))   # ldr x1, [sp]              infostyle
	repl_a64_word(op(0xf9, 0x400be2))   # ldr x2, [sp, #16]         token
	repl_a64_word(op(0x91, 0x0083ff))   # add sp, sp, #32
	repl_a64_word(op(0xd2, 0x801710))   # mov x16, #184             sigreturn
	repl_a64_word(op(0xd4, 0x001001))   # svc #0x80
	repl_a64_word(op(0xd4, 0x200020))   # brk #1
	repl_a64_page_writable(0)


# A Linux handler thunk calling handler(sig, &uc_mcontext); see the
# header. The literal holding the handler address is 8-byte aligned.
int repl_a64_handler_thunk(int handler):
	for i in range(repl_a64_thunk_count):
		if (repl_a64_thunk_handlers[i] == handler): return repl_a64_thunk_addresses[i]
	asserts(c"too many arm64 signal handler thunks", repl_a64_thunk_count < 8)
	repl_a64_page_writable(1)
	while ((repl_a64_pos & 7) != 0): repl_a64_word(op(0xd5, 0x03201f))   # nop
	int thunk = repl_a64_page + repl_a64_pos
	repl_a64_word(op(0xa9, 0xbf7bfd))   # stp x29, x30, [sp, #-16]!  x30: the restorer
	repl_a64_word(op(0x91, 0x0003e9))   # mov x9, sp
	repl_a64_word(op(0xd1, 0x4083ff))   # sub sp, sp, #32, lsl #12   128 KB W stack
	repl_a64_word(op(0xaa, 0x0903fc))   # mov x28, x9
	repl_a64_word(op(0x58, 0x00014a))   # ldr x10, lit
	repl_a64_word(op(0xf8, 0x1f8f8a))   # str x10, [x28, #-8]!       callee slot
	repl_a64_word(op(0xf8, 0x1f8f80))   # str x0, [x28, #-8]!        sig
	repl_a64_word(op(0x91, 0x02c04b))   # add x11, x2, #176          &uc->uc_mcontext
	repl_a64_word(op(0xf8, 0x1f8f8b))   # str x11, [x28, #-8]!
	repl_a64_word(op(0xd6, 0x3f0140))   # blr x10
	repl_a64_word(op(0x91, 0x4083ff))   # add sp, sp, #32, lsl #12
	repl_a64_word(op(0xa8, 0xc17bfd))   # ldp x29, x30, [sp], #16
	repl_a64_word(op(0xd6, 0x5f03c0))   # ret                        into the restorer
	repl_a64_word(op(0xd5, 0x03201f))   # nop                        (aligns lit)
	save_i(cast(char*, repl_a64_page + repl_a64_pos), handler, 8)   # lit
	repl_a64_pos = repl_a64_pos + 8
	repl_a64_page_writable(0)
	repl_a64_thunk_handlers[repl_a64_thunk_count] = handler
	repl_a64_thunk_addresses[repl_a64_thunk_count] = thunk
	repl_a64_thunk_count = repl_a64_thunk_count + 1
	return thunk


# The main thread's alternate signal stack. Linux stack_t is {ss_sp,
# ss_flags, ss_size}, Darwin's {ss_sp, ss_size, ss_flags}, one word each.
void repl_a64_altstack_init():
	if (repl_a64_altstack != 0): return;
	int base = mmap(0, repl_a64_altstack_size, 3, 34) /* RW, PRIVATE|ANONYMOUS */
	asserts(c"mmap of the arm64 signal stack failed", (base > 0) | (base < -4095))
	int[3] ss
	ss[0] = base
	ss[1] = 0
	ss[2] = repl_a64_altstack_size
	if (jit_host_darwin()):
		ss[1] = repl_a64_altstack_size
		ss[2] = 0
	asserts(c"sigaltstack failed", sys_sigaltstack(cast(int, &ss[0]), 0) == 0)
	repl_a64_altstack = base


# Install handler(sig, context) for signum. flags carries the caller's
# SA_* bits; SA_ONSTACK (0x08000000) is always added, and on Linux
# SA_SIGINFO (4) | SA_RESTORER (0x04000000) with the thunk and restorer.
# lib/darwin/syscalls.w's rt_sigaction translates the same Linux-style
# struct for XNU, with act[2] as sa_tramp.
void repl_a64_install(int signum, int handler, int flags):
	repl_a64_stubs_init()
	repl_a64_altstack_init()
	if (repl_a64_act == 0): repl_a64_act = cast(int*, malloc(5 * __word_size__))
	int* act = repl_a64_act
	act[3] = 0
	act[4] = 0
	if (jit_host_darwin()):
		act[0] = handler
		act[1] = flags | 0x08000000
		act[2] = repl_a64_darwin_tramp
	else:
		act[0] = repl_a64_handler_thunk(handler)
		act[1] = flags | 0x08000000 | 4 | 0x04000000
		act[2] = repl_a64_restorer
	asserts(c"rt_sigaction failed", rt_sigaction(signum, act, 0) == 0)


# Recover from a fault by returning from the handler into resume_pc with
# the W stack pointer stack (see the header).
void repl_a64_fault_resume(int context, int resume_pc, int stack):
	save_word(cast(char*, context + sigcontext_eip()), resume_pc)
	save_word(cast(char*, context + sigcontext_esp()), stack)


# Clean and invalidate [start, end) for instruction fetch.
void repl_a64_flush(int start, int end):
	if (end <= start): return;
	if (jit_host_icache_invalidate(start, end - start)): return;
	repl_a64_stubs_init()
	__repl_a64_flush_callback* flush = cast(__repl_a64_flush_callback*, repl_a64_flush_stub)
	flush(start, end)


# The compiler is about to write into the code buffer. On macOS this
# thread's MAP_JIT pages become writable (and not executable); on Linux
# the buffer is RWX and nothing happens.
void repl_jit_open():
	if (__target_isa__ != 1): return;
	if (jit_host_darwin()): jit_host_write_protect(0)


# The compiler finished writing into the code buffer and its code may
# run: make every written byte visible to instruction fetch, and on
# macOS switch the MAP_JIT pages back to executable. A no-op on the x86
# family, whose instruction cache is coherent.
void repl_jit_commit():
	if (__target_isa__ != 1): return;
	repl_a64_flush(code_offset, code_offset + codepos)
	# The descriptors the A64 back end records for an image's PIE rebase
	# walk mean nothing in process; drop them instead of letting the
	# table grow for the whole session.
	rebase_count = 0
	if (jit_host_darwin()): jit_host_write_protect(1)


# ---------------------------------------------------------------------------
# The per-target hooks repl/core.w calls on every architecture
# (repl/__arch__/<arch>/jit.w binds this file on the arm64 targets and
# x86-family versions elsewhere). Each returns what core.w needs, so
# core.w has no AArch64 branches of its own.

# Configure the in-process compiler for this target.
void repl_jit_configure():
	repl_a64_configure()


# Map the code buffer of size bytes (flags: core.w's x86 mmap flags,
# unused here: arm64 maps at fixed low hints).
int repl_jit_map_code(int size, int flags):
	return repl_a64_map_code(size)


# Carve the session's data arena out of the mapping; returns the code
# part's size.
int repl_jit_data_init(int buffer, int size):
	return repl_a64_data_init(buffer, size)


# Align the next inline session global for atomics.
void repl_jit_align_global():
	repl_a64_align_global()


# Install a fault handler; 1: handled here (core.w's x86 path is skipped).
int repl_jit_install(int signum, int handler, int flags):
	repl_a64_install(signum, handler, flags)
	return 1


# Resume a recovered fault by returning from the handler; 1: done (no
# long jump).
int repl_jit_fault_resume(int context, int resume_pc, int stack):
	repl_a64_fault_resume(context, resume_pc, stack)
	return 1
