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

# x86/x64 names by width in bytes (1/2/4/8), as asm_name_slot tables with
# 4-byte slots: 8 entries, 16 for the x64 qword set.
char* asm_reg_table(int size):
	if (size == 1):
		return c"al\0\0cl\0\0dl\0\0bl\0\0ah\0\0ch\0\0dh\0\0bh\0\0"
	if (size == 2):
		return c"ax\0\0cx\0\0dx\0\0bx\0\0sp\0\0bp\0\0si\0\0di\0\0"
	if (size == 4):
		return c"eax\0ecx\0edx\0ebx\0esp\0ebp\0esi\0edi\0"
	return c"rax\0rcx\0rdx\0rbx\0rsp\0rbp\0rsi\0rdi\0r8\0\0r9\0\0r10\0r11\0r12\0r13\0r14\0r15\0"


char* asm_reg_name_x86_32(int number):
	return asm_name_slot(asm_reg_table(4), 4, 8, number)


char* asm_reg_name_x86_16(int number):
	return asm_name_slot(asm_reg_table(2), 4, 8, number)


char* asm_reg_name_x86_8(int number):
	return asm_name_slot(asm_reg_table(1), 4, 8, number)


# x64 names: numbers 0..7 are the classic set widened, 8..15 are r8..r15.
char* asm_reg_name_x64(int number):
	return asm_name_slot(asm_reg_table(8), 4, 16, number)


# Extended x64 registers r8..r15 at a sub-qword width: "r8d"/"r8w"/"r8b"
# (dword/word/byte) built from the number plus a width suffix. Returns a
# malloc'd name, or 0 when number is outside 8..15.
char* asm_reg_name_x64_ext(int number, int suffix):
	if (number < 8 || number > 15):
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
	if (arch == ASM_ARCH_X86):
		if (size == 1):
			return asm_reg_name_x86_8(number)
		if (size == 2):
			return asm_reg_name_x86_16(number)
		return asm_reg_name_x86_32(number)
	if (arch == ASM_ARCH_X64):
		if (number >= 8 && size <= 4):
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
	if (arch == ASM_ARCH_ARM64):
		return asm_reg_name_arm64(number, size)
	return 0


########################### x86 opcode-group names ###########################

# Mnemonic tables shared by x86_decode.w (/ext -> name) and x86_encode.w
# (name -> /ext), asm_name_slot layout: group 1 is the ALU /ext (and the
# 00-3f ALU column order), 2 the shifts, 3 the f6/f7 group, 5 the ff group
# and 8 the 0f ba bit tests; an empty slot is an unassigned /ext.
char* asm_x86_group_table(int group):
	if (group == 1):
		return c"add\0or\0\0adc\0sbb\0and\0sub\0xor\0cmp\0"
	if (group == 2):
		return c"rol\0ror\0rcl\0rcr\0shl\0shr\0sal\0sar\0"
	if (group == 3):
		return c"test\0\0\0\0\0\0not\0\0neg\0\0mul\0\0imul\0div\0\0idiv\0"
	if (group == 5):
		return c"inc\0\0dec\0\0call\0\0\0\0\0\0jmp\0\0\0\0\0\0\0push\0\0\0\0\0\0"
	return c"\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0bt\0\0bts\0btr\0btc\0"


int asm_x86_group_stride(int group):
	if (group == 3 || group == 5):
		return 5
	return 4


# The mnemonic of /ext in an opcode group, or 0 when unassigned.
char* asm_x86_group_name(int group, int ext):
	return asm_name_slot(asm_x86_group_table(group), asm_x86_group_stride(group), 8, ext)


# The /ext of mnemonic m in an opcode group, or -1.
int asm_x86_group_ext(int group, char* m):
	return asm_name_slot_find(asm_x86_group_table(group), asm_x86_group_stride(group), 8, m)


# Condition-code suffixes by cc number (0x70+cc / 0x0f80+cc / 0x0f90+cc).
char* asm_x86_cc_table():
	return c"o\0\0no\0b\0\0ae\0e\0\0ne\0be\0a\0\0s\0\0ns\0p\0\0np\0l\0\0ge\0le\0g\0\0"


# Scalar-float ALU mnemonics of f3 (ss) / f2 (sd) 0f 58..5e, by opcode -
# 0x58 (asm_name_slot layout, 9-byte slots).
char* asm_x86_sse_table(int rep):
	if (rep == 0xf2):
		return c"addsd\0\0\0\0mulsd\0\0\0\0cvtsd2ss\0\0\0\0\0\0\0\0\0\0subsd\0\0\0\0\0\0\0\0\0\0\0\0\0divsd\0\0\0\0"
	return c"addss\0\0\0\0mulss\0\0\0\0cvtss2sd\0\0\0\0\0\0\0\0\0\0subss\0\0\0\0\0\0\0\0\0\0\0\0\0divss\0\0\0\0"


################################## lookup #####################################

# Look up an x86/x64 register name in any width. Returns the encoded
# (size << 8) | number word, or -1.
int asm_reg_lookup_x86(char* name):
	int number = asm_name_slot_find(asm_reg_table(4), 4, 8, name)
	if (number >= 0):
		return asm_reg_encode(4, number)
	number = asm_name_slot_find(asm_reg_table(8), 4, 16, name)
	if (number >= 0):
		return asm_reg_encode(8, number)
	number = asm_name_slot_find(asm_reg_table(2), 4, 8, name)
	if (number >= 0):
		return asm_reg_encode(2, number)
	number = asm_name_slot_find(asm_reg_table(1), 4, 8, name)
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
	if (name[1] < '0' || name[1] > '9'):
		return -1
	int number = name[1] - '0'
	if (name[2] != 0):
		if (name[2] < '0' || name[2] > '9'):
			return -1
		if (name[3] != 0):
			return -1
		number = number * 10 + (name[2] - '0')
	if (number > 30):
		return -1
	return asm_reg_encode(size, number)
