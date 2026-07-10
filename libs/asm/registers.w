/*
Register name tables for the assembler/disassembler libraries
(docs/projects/assembler_disassembler.md, issue #164).

Lookups return an encoded (size_bytes << 8) | number word so a single
table answers both "which register" and "which width", or -1 when the
name is unknown. asm_reg_number/asm_reg_size unpack it.

Compiled by the seed-compat gate (asm_seed_gate): only seed-understood
syntax here.
*/
import lib.lib
import libs.asm.insn


int asm_reg_encode(int size, int number):
	return (size << 8) | number


int asm_reg_number(int encoded):
	return encoded & 255


int asm_reg_size(int encoded):
	return encoded >> 8


############################### name tables ###################################

# x86 register numbers follow the hardware encoding (eax=0 .. edi=7);
# x64 extends to r15=15; arm64 uses x0..x30 with 31 = sp/xzr by context.

char* asm_reg_name_x86_32(int number):
	if (number == 0):
		return c"eax"
	if (number == 1):
		return c"ecx"
	if (number == 2):
		return c"edx"
	if (number == 3):
		return c"ebx"
	if (number == 4):
		return c"esp"
	if (number == 5):
		return c"ebp"
	if (number == 6):
		return c"esi"
	if (number == 7):
		return c"edi"
	return 0


char* asm_reg_name_x86_16(int number):
	if (number == 0):
		return c"ax"
	if (number == 1):
		return c"cx"
	if (number == 2):
		return c"dx"
	if (number == 3):
		return c"bx"
	if (number == 4):
		return c"sp"
	if (number == 5):
		return c"bp"
	if (number == 6):
		return c"si"
	if (number == 7):
		return c"di"
	return 0


char* asm_reg_name_x86_8(int number):
	if (number == 0):
		return c"al"
	if (number == 1):
		return c"cl"
	if (number == 2):
		return c"dl"
	if (number == 3):
		return c"bl"
	if (number == 4):
		return c"ah"
	if (number == 5):
		return c"ch"
	if (number == 6):
		return c"dh"
	if (number == 7):
		return c"bh"
	return 0


# x64 names: numbers 0..7 are the classic set widened, 8..15 are r8..r15.
char* asm_reg_name_x64(int number):
	if (number == 0):
		return c"rax"
	if (number == 1):
		return c"rcx"
	if (number == 2):
		return c"rdx"
	if (number == 3):
		return c"rbx"
	if (number == 4):
		return c"rsp"
	if (number == 5):
		return c"rbp"
	if (number == 6):
		return c"rsi"
	if (number == 7):
		return c"rdi"
	if (number == 8):
		return c"r8"
	if (number == 9):
		return c"r9"
	if (number == 10):
		return c"r10"
	if (number == 11):
		return c"r11"
	if (number == 12):
		return c"r12"
	if (number == 13):
		return c"r13"
	if (number == 14):
		return c"r14"
	if (number == 15):
		return c"r15"
	return 0


# Extended x64 registers r8..r15 at a sub-qword width: "r8d"/"r8w"/"r8b"
# (dword/word/byte) built from the number plus a width suffix. Returns a
# malloc'd name, or 0 when number is outside 8..15.
char* asm_reg_name_x64_ext(int number, int suffix):
	if (number < 8 | number > 15):
		return 0
	char* name = malloc(5)
	name[0] = 'r'
	int i = 1
	if (number < 10):
		name[i] = '0' + number
		i = i + 1
	else:
		name[i] = '1'
		name[i + 1] = '0' + (number - 10)
		i = i + 2
	name[i] = suffix
	name[i + 1] = 0
	return name


# arm64: xN (8 bytes) / wN (4 bytes); 31 is sp (or zr by context).
# Returns a malloc'd name for the numbered registers.
char* asm_reg_name_arm64(int number, int size):
	if (number == 31):
		if (size == 4):
			return c"wsp"
		return c"sp"
	char* prefix = c"x"
	if (size == 4):
		prefix = c"w"
	char* name = malloc(4)
	name[0] = prefix[0]
	if (number < 10):
		name[1] = '0' + number
		name[2] = 0
	else:
		name[1] = '0' + number / 10
		name[2] = '0' + number % 10
		name[3] = 0
	return name


# Preferred display name for a register operand of the given arch/size.
# arm64 number 31 formats as sp; callers that mean xzr/wzr handle it
# themselves (the meaning is per-instruction, not per-register).
char* asm_reg_name(int arch, int number, int size):
	if (arch == ASM_ARCH_X86()):
		if (size == 1):
			return asm_reg_name_x86_8(number)
		if (size == 2):
			return asm_reg_name_x86_16(number)
		return asm_reg_name_x86_32(number)
	if (arch == ASM_ARCH_X64()):
		if (number >= 8 & size <= 4):
			# r8..r15 in dword/word/byte width: r8d / r8w / r8b.
			if (size == 1):
				return asm_reg_name_x64_ext(number, 'b')
			if (size == 2):
				return asm_reg_name_x64_ext(number, 'w')
			return asm_reg_name_x64_ext(number, 'd')
		if (size == 1):
			return asm_reg_name_x86_8(number)
		if (size == 2):
			return asm_reg_name_x86_16(number)
		if (size == 4):
			return asm_reg_name_x86_32(number)
		return asm_reg_name_x64(number)
	if (arch == ASM_ARCH_ARM64()):
		return asm_reg_name_arm64(number, size)
	return 0


################################## lookup #####################################

int asm_reg_scan_table(int arch_size, char* name, int number_limit):
	int number = 0
	while (number < number_limit):
		char* candidate = 0
		if (arch_size == 0):
			candidate = asm_reg_name_x86_8(number)
		else if (arch_size == 1):
			candidate = asm_reg_name_x86_16(number)
		else if (arch_size == 2):
			candidate = asm_reg_name_x86_32(number)
		else:
			candidate = asm_reg_name_x64(number)
		if (cast(int, candidate) != 0):
			if (strcmp(candidate, name) == 0):
				return number
		number = number + 1
	return -1


# Look up an x86/x64 register name in any width. Returns the encoded
# (size << 8) | number word, or -1.
int asm_reg_lookup_x86(char* name):
	int number = asm_reg_scan_table(2, name, 8)
	if (number >= 0):
		return asm_reg_encode(4, number)
	number = asm_reg_scan_table(3, name, 16)
	if (number >= 0):
		return asm_reg_encode(8, number)
	number = asm_reg_scan_table(1, name, 8)
	if (number >= 0):
		return asm_reg_encode(2, number)
	number = asm_reg_scan_table(0, name, 8)
	if (number >= 0):
		return asm_reg_encode(1, number)
	return -1


# Look up an arm64 register name (xN, wN, sp, wsp, xzr, wzr).
# Returns the encoded (size << 8) | number word, or -1.
int asm_reg_lookup_arm64(char* name):
	if (strcmp(name, c"sp") == 0):
		return asm_reg_encode(8, 31)
	if (strcmp(name, c"wsp") == 0):
		return asm_reg_encode(4, 31)
	if (strcmp(name, c"xzr") == 0):
		return asm_reg_encode(8, 31)
	if (strcmp(name, c"wzr") == 0):
		return asm_reg_encode(4, 31)
	int size = 0
	if (name[0] == 'x'):
		size = 8
	else if (name[0] == 'w'):
		size = 4
	else:
		return -1
	if (name[1] < '0' | name[1] > '9'):
		return -1
	int number = name[1] - '0'
	if (name[2] != 0):
		if (name[2] < '0' | name[2] > '9'):
			return -1
		if (name[3] != 0):
			return -1
		number = number * 10 + (name[2] - '0')
	if (number > 30):
		return -1
	return asm_reg_encode(size, number)
