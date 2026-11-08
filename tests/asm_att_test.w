# AT&T-syntax assembler front end (libs/asm/att.w): each line parses and
# encodes to the exact bytes the GNU assembler produces, over the
# integer/atomic/branch instruction set a freestanding kernel's inline
# asm uses. The expected bytes were produced by `as`.
import lib.lib
import lib.assert
import libs.asm.insn
import libs.asm.att
import libs.asm.x86_encode


int att_hexval(int c):
	if ((c >= '0') && (c <= '9')): return c - '0'
	if ((c >= 'A') && (c <= 'F')): return c - 'A' + 10
	if ((c >= 'a') && (c <= 'f')): return c - 'a' + 10
	return 0 - 1


# Parse "48 89 C8" into bytes; returns the count, bytes into out.
int att_hexbytes(char* s, char* out):
	int i = 0
	int n = 0
	while (s[i] != 0):
		if (s[i] == ' '):
			i = i + 1
		else:
			int hi = att_hexval(s[i])
			int lo = att_hexval(s[i + 1])
			out[n] = (hi << 4) | lo
			n = n + 1
			i = i + 2
	return n


void att_is(char* line, char* want):
	asm_insn insn
	int ok = asm_att_parse(line, ASM_ARCH_X64, &insn)
	asserts(line, ok)
	asm_buffer* b = asm_buffer_new()
	int n = asm_x86_encode(b, &insn)
	asserts(line, n > 0)
	char* expected = cast(char*, malloc(32))
	int en = att_hexbytes(want, expected)
	asserts(line, b.length == en)
	for i in range(en):
		asserts(line, (b.data[i] & 255) == (expected[i] & 255))
	asm_buffer_free(b)


int main():
	# Data movement / ALU with AT&T suffixes and source-first order.
	att_is(c"movq %rcx, %rax", c"48 89 C8")
	att_is(c"movl %ecx, %eax", c"89 C8")
	att_is(c"movb $5, (%rdi)", c"C6 07 05")
	att_is(c"addl $1, (%rdi)", c"83 07 01")
	att_is(c"addq %rbx, %rax", c"48 01 D8")
	att_is(c"orb $2, (%rdi)", c"80 0F 02")
	att_is(c"andb $253, (%rdi)", c"80 27 FD")
	att_is(c"decl (%rdi)", c"FF 0F")
	att_is(c"incl (%rdi)", c"FF 07")
	att_is(c"adcq %rbx, %rax", c"48 11 D8")
	att_is(c"sbbq %rbx, %rax", c"48 19 D8")
	att_is(c"testb $1, (%rdi)", c"F6 07 01")
	att_is(c"xorl %eax, %eax", c"31 C0")
	att_is(c"cmpq %rbx, %rax", c"48 39 D8")

	# Double-suffix zero/sign extension.
	att_is(c"movzbl (%rdi), %eax", c"0F B6 07")
	att_is(c"movzwl (%rdi), %eax", c"0F B7 07")
	att_is(c"movslq %edi, %rax", c"48 63 C7")

	# Memory with displacement, base, index and scale.
	att_is(c"movq 8(%rdi), %rax", c"48 8B 47 08")
	att_is(c"leaq (%rdi,%rsi,4), %rax", c"48 8D 04 B7")
	att_is(c"movq -16(%rbp), %rax", c"48 8B 45 F0")

	# Bit tests and scans.
	att_is(c"btq %rcx, %rax", c"48 0F A3 C8")
	att_is(c"btsq %rax, (%rdi)", c"48 0F AB 07")
	att_is(c"bsfq %rcx, %rax", c"48 0F BC C1")
	att_is(c"bsrq %rcx, %rax", c"48 0F BD C1")
	att_is(c"popcntq %rcx, %rax", c"F3 48 0F B8 C1")

	# Atomics with the lock prefix.
	att_is(c"lock addq %rax, (%rdi)", c"F0 48 01 07")
	att_is(c"lock btsq %rax, (%rdi)", c"F0 48 0F AB 07")
	att_is(c"lock cmpxchgq %rcx, (%rdi)", c"F0 48 0F B1 0F")
	att_is(c"lock xaddq %rcx, (%rdi)", c"F0 48 0F C1 0F")
	att_is(c"lock decl (%rdi)", c"F0 FF 0F")
	att_is(c"xchgq %rax, (%rdi)", c"48 87 07")

	# Serializing / privileged / flag instructions.
	att_is(c"cpuid", c"0F A2")
	att_is(c"rdtsc", c"0F 31")
	att_is(c"rdmsr", c"0F 32")
	att_is(c"wrmsr", c"0F 30")
	att_is(c"pushfq", c"9C")
	att_is(c"popfq", c"9D")
	att_is(c"sti", c"FB")
	att_is(c"cli", c"FA")
	att_is(c"lfence", c"0F AE E8")
	att_is(c"mfence", c"0F AE F0")
	att_is(c"xsetbv", c"0F 01 D1")
	att_is(c"wbinvd", c"0F 09")
	att_is(c"hlt", c"F4")
	att_is(c"nop", c"90")

	# Flag setters and conditional set (not suffix-split).
	att_is(c"sete %al", c"0F 94 C0")
	att_is(c"setc %dl", c"0F 92 C2")


	# Port I/O and FPU state save (kernel driver / FPU paths).
	att_is(c"inl %dx, %eax", c"ED")
	att_is(c"inb %dx, %al", c"EC")
	att_is(c"inw %dx, %ax", c"66 ED")
	att_is(c"outl %eax, %dx", c"EF")
	att_is(c"outb %al, %dx", c"EE")
	att_is(c"inb $8, %al", c"E4 08")
	att_is(c"fxsaveq (%rax)", c"48 0F AE 00")
	att_is(c"fxrstorq (%rax)", c"48 0F AE 08")

	# Segment overrides: the %fs/%gs prefix comes first, ahead of lock and
	# the operand-size prefix (per-CPU and thread-local accesses).
	att_is(c"movq %gs:0x28, %rax", c"65 48 8B 04 25 28 00 00 00")
	att_is(c"movq %fs:0, %rax", c"64 48 8B 04 25 00 00 00 00")
	att_is(c"movl %gs:8(%rdi), %eax", c"65 8B 47 08")
	att_is(c"movw %ax, %gs:(%rdi)", c"65 66 89 07")
	att_is(c"lock incl %gs:(%rdi)", c"65 F0 FF 07")
	att_is(c"addq $1, %gs:16", c"65 48 83 04 25 10 00 00 00 01")
	att_is(c"movq %rax, %fs:(%rbx,%rcx,8)", c"64 48 89 04 CB")
	att_is(c"incq %gs:0x10", c"65 48 FF 04 25 10 00 00 00")

	# Negative immediates keep their sign.
	att_is(c"andq $-16, %rsp", c"48 83 E4 F0")
	att_is(c"movl $-14, %eax", c"B8 F2 FF FF FF")
	att_is(c"addq $-200, %rax", c"48 05 38 FF FF FF")

	println(c"asm_att_test passed")
	return 0
