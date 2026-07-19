/*
Arch-neutral core of the in-house assembler/disassembler libraries
(docs/projects/assembler_disassembler.md, issue #164): the structured
instruction/operand model that encoders, decoders, the text parser and
the formatter all share, plus the byte buffer and label/fixup machinery
the assembler emits through.

This library is compiled directly by the committed seed as a build gate
(asm_seed_gate): only seed-understood syntax here.
*/
import lib.lib


# Architecture ids (asm_insn.arch, asm_binary.machine mapping)
int ASM_ARCH_X86():
	return 0


int ASM_ARCH_X64():
	return 1


int ASM_ARCH_ARM64():
	return 2


# Base-register sentinel for x64 RIP-relative memory ([rip+disp32]): a
# ModRM mod=0 rm=5 form is PC-relative in 64-bit mode, not the absolute
# [disp32] it is in 32-bit mode. Stored in asm_operand.base (which never
# holds a real register number >= 16), so no extra field is needed; the
# formatter prints it as "rip" and the encoder re-emits the rm=5 (no-SIB)
# form instead of the SIB form a genuine absolute [disp32] uses on x64.
int ASM_BASE_RIP():
	return 16


# Register classes (asm_operand.rclass for kind reg)
int ASM_RCLASS_GP():
	return 0


int ASM_RCLASS_XMM():
	return 1


int ASM_RCLASS_X87():
	return 2


# Operand kinds
int ASM_OP_NONE():
	return 0


int ASM_OP_REG():
	return 1


int ASM_OP_IMM():
	return 2


int ASM_OP_MEM():
	return 3


int ASM_OP_LABEL():
	return 4


/*
One operand. Which fields are meaningful depends on kind:
	reg:   reg, size
	imm:   imm, size
	mem:   base, index, scale, disp, size (base/index -1 when absent)
	label: label
*/
struct asm_operand:
	int kind
	int reg
	int rclass    # register class for kind reg (gp/xmm/x87)
	int base
	int index
	int scale
	int disp
	int disp_size # encoded displacement width for kind mem: 0 none/auto,
	              # 1 disp8, 4 disp32 (lets the encoder reproduce the exact
	              # bytes a decoder saw, even non-minimal forms)
	int imm
	int imm_hi    # high 32 bits of a 64-bit immediate (movabs); W's int is
	              # 32-bit, so an imm64 is carried as imm (low) + imm_hi (high)
	int size      # operand size in bytes (1/2/4/8); 0 = arch default
	char* label


void asm_operand_clear(asm_operand* op):
	op.kind = ASM_OP_NONE()
	op.reg = -1
	op.rclass = ASM_RCLASS_GP()
	op.base = -1
	op.index = -1
	op.scale = 1
	op.disp = 0
	op.disp_size = 0
	op.imm = 0
	op.imm_hi = 0
	op.size = 0
	op.label = 0


/*
One decoded or to-be-encoded instruction. 'length'/'bytes' describe the
encoding when known (decoder fills them; encoder produces them). At most
three operands, dest-first (Intel order).
*/
struct asm_insn:
	int arch
	int address
	int length
	int branch_target   # absolute target for rel branches; -1 otherwise
	int raw             # raw 32-bit word for arm64 opaque-passthrough forms
	                    # (recognized mnemonic but operands not modeled); 0
	                    # for modeled/x86 instructions. Encoders that see a
	                    # nonzero raw on an opaque insn re-emit it verbatim.
	char* mnemonic
	asm_operand op1
	asm_operand op2
	asm_operand op3


void asm_insn_clear(asm_insn* insn):
	insn.arch = ASM_ARCH_X86()
	insn.address = 0
	insn.length = 0
	insn.branch_target = -1
	insn.raw = 0
	insn.mnemonic = 0
	asm_operand_clear(&insn.op1)
	asm_operand_clear(&insn.op2)
	asm_operand_clear(&insn.op3)


# Minimal-width lowercase hex ("0x12", not the zero-padded "0x00000012"
# that lib.hex produces) for a non-negative value — the corpus/canonical
# immediate form.
char* asm_hex_min(int v):
	char* digits = c"0123456789abcdef"
	char* tmp = malloc(16)
	int n = 0
	if (v == 0):
		tmp[0] = '0'
		n = 1
	while (v != 0):
		tmp[n] = digits[v & 15]
		n = n + 1
		v = (v >> 4) & 0x0fffffff
	char* out = malloc(n + 3)
	out[0] = '0'
	out[1] = 'x'
	int i = 0
	while (i < n):
		out[2 + i] = tmp[n - 1 - i]
		i = i + 1
	out[2 + n] = 0
	free(tmp)
	return out


# Minimal-width lowercase hex for a 64-bit value carried as (hi, lo). When
# the high word is zero this is just asm_hex_min(lo); otherwise the low word
# is zero-padded to a full 8 digits so no bits are lost
# (0x12345678, 0x90123456 -> "0x1234567890123456").
char* asm_hex_min64(int hi, int lo):
	if (hi == 0):
		return asm_hex_min(lo)
	char* digits = c"0123456789abcdef"
	char* lopart = malloc(9)
	int i = 0
	while (i < 8):
		lopart[i] = digits[(lo >> ((7 - i) * 4)) & 15]
		i = i + 1
	lopart[8] = 0
	return strjoin(asm_hex_min(hi), lopart)


int asm_insn_operand_count(asm_insn* insn):
	if (insn.op1.kind == ASM_OP_NONE()):
		return 0
	if (insn.op2.kind == ASM_OP_NONE()):
		return 1
	if (insn.op3.kind == ASM_OP_NONE()):
		return 2
	return 3


################################ byte buffer ##################################

struct asm_buffer:
	int capacity
	int length
	char* data


asm_buffer* asm_buffer_new():
	asm_buffer* b = cast(asm_buffer*, malloc(12))
	b.capacity = 64
	b.length = 0
	b.data = malloc(b.capacity)
	return b


void asm_buffer_free(asm_buffer* b):
	free(b.data)
	free(cast(char*, b))


void asm_buffer_reserve(asm_buffer* b, int extra):
	if (b.length + extra <= b.capacity):
		return
	int capacity = b.capacity
	while (b.length + extra > capacity):
		capacity = capacity * 2
	b.data = realloc(b.data, b.capacity, capacity)
	b.capacity = capacity


void asm_buffer_byte(asm_buffer* b, int v):
	asm_buffer_reserve(b, 1)
	b.data[b.length] = v
	b.length = b.length + 1


void asm_buffer_bytes(asm_buffer* b, char* data, int n):
	asm_buffer_reserve(b, n)
	int i = 0
	while (i < n):
		b.data[b.length + i] = data[i]
		i = i + 1
	b.length = b.length + n


# Little-endian 32-bit word, the common immediate/displacement width.
void asm_buffer_int32(asm_buffer* b, int v):
	asm_buffer_byte(b, v & 255)
	asm_buffer_byte(b, (v >> 8) & 255)
	asm_buffer_byte(b, (v >> 16) & 255)
	asm_buffer_byte(b, (v >> 24) & 255)


# Overwrite an already-emitted little-endian 32-bit word (fixup patching).
void asm_buffer_patch_int32(asm_buffer* b, int position, int v):
	b.data[position] = v & 255
	b.data[position + 1] = (v >> 8) & 255
	b.data[position + 2] = (v >> 16) & 255
	b.data[position + 3] = (v >> 24) & 255


############################## labels and fixups ##############################

# Fixup kinds
int ASM_FIX_REL32():
	return 0


int ASM_FIX_ABS32():
	return 1


struct asm_label_record:
	char* name
	int position   # buffer offset, -1 until defined


struct asm_fixup_record:
	char* name
	int position   # buffer offset of the 4-byte field to patch
	int kind


/*
Label table for one assembly unit. rel32 fixups are patched with
(target - (position + 4)): the displacement is relative to the end of
the 4-byte field, matching x86 call/jmp semantics.
*/
struct asm_labels:
	list[asm_label_record] labels
	list[asm_fixup_record] fixups


asm_labels* asm_labels_new():
	asm_labels* t = cast(asm_labels*, malloc(8))
	t.labels = new list[asm_label_record]
	t.fixups = new list[asm_fixup_record]
	return t


int asm_labels_find(asm_labels* t, char* name):
	int i = 0
	while (i < t.labels.length):
		asm_label_record rec = t.labels[i]
		if (strcmp(rec.name, name) == 0):
			return i
		i = i + 1
	return -1


void asm_labels_define(asm_labels* t, char* name, int position):
	int i = asm_labels_find(t, name)
	if (i >= 0):
		asm_label_record rec = t.labels[i]
		rec.position = position
		t.labels[i] = rec
		return
	asm_label_record fresh
	fresh.name = name
	fresh.position = position
	t.labels.push(fresh)


void asm_labels_reference(asm_labels* t, char* name, int position, int kind):
	asm_fixup_record fix
	fix.name = name
	fix.position = position
	fix.kind = kind
	t.fixups.push(fix)


# Patch every fixup against the defined labels. Returns the number of
# fixups whose label was never defined (0 = fully resolved).
int asm_labels_resolve(asm_labels* t, asm_buffer* b):
	int unresolved = 0
	int i = 0
	while (i < t.fixups.length):
		asm_fixup_record fix = t.fixups[i]
		int target = -1
		int found = asm_labels_find(t, fix.name)
		if (found >= 0):
			asm_label_record rec = t.labels[found]
			target = rec.position
		if (target < 0):
			unresolved = unresolved + 1
		else if (fix.kind == ASM_FIX_REL32()):
			asm_buffer_patch_int32(b, fix.position, target - (fix.position + 4))
		else:
			asm_buffer_patch_int32(b, fix.position, target)
		i = i + 1
	return unresolved
