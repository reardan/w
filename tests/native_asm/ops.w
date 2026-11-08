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
