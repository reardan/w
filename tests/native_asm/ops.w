# Native inline assembly statements (grammar/inline_asm_stmt.w), compiled
# to a freestanding --c-abi object and linked with a gcc C driver that
# checks each against the same operation written in C inline asm
# (tests/native_asm_test.w). CPUID, the timestamp counter, an xchg, a
# lock cmpxchg with a flag output, and a lock xadd.

# CPUID leaf `leaf` (subleaf 0): the four result registers through
# pointers. rax/rcx are both an input (leaf / 0) and an output.
export void w_cpuid(int leaf, int* a, int* b, int* c, int* d):
	asm_native:
		input rax = leaf
		input rcx = 0
		output rax:4 = a
		output rbx:4 = b
		output rcx:4 = c
		output rdx:4 = d
		"cpuid"

# Atomically exchange *p with newv, returning the previous value.
export int w_xchg(int* p, int newv):
	int old = 0
	asm_native:
		input rax = newv
		input rcx = p
		output rdx:4 = &old
		"xchgl %eax, (%rcx)"
		"movl %eax, %edx"
	return old

# lock cmpxchg: if *p == expected, store newv and set *okflag; return the
# value that was in *p (a =@ccz flag output through flagout).
export int w_cmpxchg(int* p, int expected, int newv, int* okflag):
	int prev = 0
	asm_native:
		input rax = expected
		input rcx = newv
		input rdx = p
		output rax:4 = &prev
		flagout z:4 = okflag
		"lock cmpxchgl %ecx, (%rdx)"
	return prev

# lock xadd: atomically add `add` to *p, returning the previous value.
export int w_xadd(int* p, int add):
	int old = 0
	asm_native:
		input rax = add
		input rcx = p
		output rdx:4 = &old
		"lock xaddl %eax, (%rcx)"
		"movl %eax, %edx"
	return old

# The timestamp counter's low 32 bits.
export int w_rdtsc_lo():
	int v = 0
	asm_native:
		output rax:4 = &v
		"rdtsc"
	return v

# inout (width 8): atomically fetch-and-add on *p in place; clobber rdx to
# exercise the clobber directive (W needs no save, it is informational).
export int w_fetch_add64(int* p, int add):
	int old = 0
	asm_native:
		inout rax:8 = p
		input rcx = add
		output rdx:8 = &old
		clobber rdx
		"movq %rax, %rdx"
		"addq %rcx, %rax"
	return old

# Width-1 and width-2 stores/loads: round-trip the low byte/word of v.
export int w_low_byte(int v):
	int out = 1234
	asm_native:
		input rax = v
		output rax:1 = &out
		"nop"
	return out

export int w_low_word(int v):
	int out = 0x5a5a0000
	asm_native:
		input rax = v
		output rax:2 = &out
		"nop"
	return out

# inout width 1: load the low byte of *p, increment it, store it back.
export int w_inc_byte(int* p):
	int seen = 0
	asm_native:
		inout rcx:1 = p
		output rcx:4 = &seen
		"nop"
	return seen

# Local labels: a counted loop with numeric labels (1b / 2f) and a named
# label, every branch in the rel32 form. Returns 1 + 2 + ... + n.
export int w_sum_to(int n):
	int out = 0
	asm_native:
		input rcx = n
		output rax:4 = &out
		"xorl %eax, %eax"
		"1: testl %ecx, %ecx"
		"jz done"
		"addl %ecx, %eax; decl %ecx"
		"jmp 1b"
		"done:"
	return out

# Numeric labels redefined: each `1b` / `1f` names the nearest one. The
# value counts how many of the two forward jumps were taken (both).
export int w_relabel():
	int out = 0
	asm_native:
		output rax:4 = &out
		"xorl %eax, %eax"
		"rep; nop"
		"jmp 1f"
		"addl $100, %eax"
		"1: incl %eax"
		"jmp 1f"
		"addl $100, %eax"
		"1: incl %eax"
	return out

# A call to an external C function from the template (R_X86_64_PLT32),
# on a 16-byte aligned stack, with rbx holding the caller's rsp.
export int w_call_c(int a):
	int out = 0
	asm_native:
		input rdi = a
		output rax:4 = &out
		clobber rbx
		"movq %rsp, %rbx"
		"andq $-16, %rsp"
		"call c_triple@PLT"
		"movq %rbx, %rsp"
	return out

# RIP-relative symbol operands (R_X86_64_PC32): read, then bump, a C
# global; and its address as a sign-extended immediate (R_X86_64_32S).
export int w_bump_counter(int add, int* address_ok):
	int old = 0
	asm_native:
		input rcx = add
		output rax:4 = &old
		output rdx:4 = address_ok
		"movl c_counter(%rip), %eax"
		"addl %ecx, c_counter(%rip)"
		"addl $1, c_counter(%rip)"
		"leaq c_counter(%rip), %rsi"
		"movq $c_counter, %rdx"
		"cmpq %rsi, %rdx"
		"sete %dl"
		"movzbl %dl, %edx"
	return old

# An exception-table record: the load at 1 may fault; the C driver's
# SIGSEGV handler finds the faulting address in the w_extable section
# (through __start_w_extable / __stop_w_extable) and resumes at the
# fixup code at 3, which sets -14 and jumps back to 2. The record is
# `.long 1b - .` / `.long 3b - .`, relocated across sections; w_sites
# holds the load's absolute address (R_X86_64_64), and the leaq gives it
# to the caller too.
export int w_probe(int* p, int* fault_site):
	int v = 0
	asm_native:
		input rcx = p
		output rax:4 = &v
		output rdx:8 = fault_site
		"leaq 1f(%rip), %rdx"
		"1: movl (%rcx), %eax"
		"2:"
		".pushsection .text.w_fixup,\"ax\""
		"3: movl $-14, %eax"
		"jmp 2b"
		".popsection"
		".pushsection \"w_extable\",\"a\""
		".balign 4"
		".long (1b) - ., (3b) - ."
		".popsection"
		".pushsection w_sites,\"a\""
		".balign 8"
		".quad 1b"
		".popsection"
	return v

# Data directives in a section of their own: constant bytes, words and a
# label difference, with alignment padding, plus an absolute 32-bit
# symbol value (R_X86_64_32) and a PC-relative one to a C function.
export void w_misc_marker():
	asm_native:
		".balign 8"
		".p2align 4, 0x90"
		"1: nop"
		"2: nop; nop"
		".pushsection w_misc,\"a\""
		".byte 0x11, 0x22"
		".balign 4"
		".word 0x3344"
		".balign 8, 0xee"
		".quad 2b - (1b - 5)"
		".long c_counter"
		".long c_triple - ."
		".popsection"

# A lone prefix statement (`lock;`), a `#` comment, `.section` /
# `.previous`, `.p2align` and a 64-bit PC-relative value (R_X86_64_PC64).
export int w_lock_add(int* p, int add):
	int old = 0
	asm_native:
		input rax = add
		input rcx = p
		output rax:4 = &old
		"lock; xaddl %eax, (%rcx)   # fetch and add"
		".section w_more,\"a\""
		".p2align 3"
		".quad c_triple - ."
		".previous"
	return old

# A template names the unit's own statics, as head64.c's rip_rel_ptr()
# names next_early_pgt: they bind to the object's local symbols.
static int w_private = 77

static int w_add7(int x):
	return x + 7

export int w_statics(int a):
	int out = 0
	asm_native:
		input rdi = a
		output rax:4 = &out
		clobber rbx
		"movq %rsp, %rbx"
		"andq $-16, %rsp"
		"call w_add7"
		"movq %rbx, %rsp"
		"addl w_private(%rip), %eax"
	return out

# pop to memory (0x8f /0), as the kernel's crash_setup_regs() (kexec.h)
# pops pushed flags into pt_regs (`pushfq; popq %0`).
export int w_pop_mem(int x):
	int64 slot = 0
	asm_native:
		input rax = x
		input rcx = &slot
		"pushq %rax"
		"popq (%rcx)"
		"addq $1, (%rcx)"
	return cast(int, slot)
