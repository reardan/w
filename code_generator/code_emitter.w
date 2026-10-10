import code_generator.integer


char *code
int code_size
int codepos
int base_code_offset
int code_offset
# In-process code lives at the addresses compiled callers already use.
# Its executable mapping cannot be moved with the heap allocator.
int code_fixed
# Standalone assembler clients import this module without compiler diagnostics.
# An in-process compiler installs its recoverable diagnostic entry here.
type code_fixed_error_callback = fn(char*) -> void
int code_fixed_error_hook

# W^X text/data split (docs/projects/arm64.md Stage 3, extended to every
# file target by docs/projects/wx_split.md). When data_split is set,
# mutable global-variable storage is emitted into a separate RW buffer
# (`data`) mapped at data_offset, so the executable segment stays
# read-execute and the data segment read-write. The in-process REPL and
# debugger leave data_split at 0, keeping globals inline in the single
# executed buffer (their mmap is RWX), so nothing changes for them.
char *data
int data_size
int datapos
int data_offset
int data_split

int word_size
int word_size_log2

# Target instruction-set family: 0 = x86/x86-64, 1 = arm64 (AArch64).
# word_size still distinguishes 32- vs 64-bit pointers; target_isa selects
# which instruction emitter the x86.w helpers dispatch to. Defaults to 0 so
# the x86 and x64 targets are wholly unaffected.
int target_isa

# Target operating system / executable container: 0 = linux (ELF),
# 1 = darwin (Mach-O, the arm64_darwin target, docs/projects/arm64.md
# Stage 4), 2 = windows (PE32+, the win64 target,
# docs/projects/windows.md). Selects the container writer, the __arch__
# library modules and the extern C ABI. Defaults to 0 so every existing
# Linux target is wholly unaffected.
int target_os

# Where the finished ELF is written: stdout by default, or the file given
# with the -o flag.
int output_fd

# 'w check' on a library module: a missing _main/main entry point is not
# an error — the backend finishers skip the entry-call patch instead of
# dying, since no runnable artifact is produced anyway. Set by link_impl
# (compiler/compiler.w) in check mode only; defaults to 0 so every
# executable-producing path still requires an entry point.
int entry_optional

# File offset of the program header table and of the rel32 displacement in
# the entry stub's "call _main". Both shift when the header layout changes
# (e.g. reserving extra program headers for dynamic linking), so the finish
# pass patches these recorded positions instead of hardcoded constants.
int elf_pie   /* explicit x64 Linux --pie; other targets stay unchanged */
int x64_syscall_abi /* 1: KVM ring-3 vmcall, 0: native Linux syscall */
int x64_hypercall_count
int[64] x64_hypercall_sites
int phdr_table_pos
int entry_call_disp_pos

# Thread-local storage (docs/projects/thread_local.md). tls_size is the
# byte size of the per-thread block every 'thread_local' global lives
# in: word 0 is the block's self pointer (gs:[0] on x64, fs:[0] on x86), variables
# follow at the offsets grammar/program.w assigns. tls_size_patch_pos is
# the code offset of the imm32 inside the __w_tls_size stub, patched with
# the final size when the executable is finished (0 = no stub emitted).
int tls_size
int tls_size_patch_pos


void resize_code(int n):
	if (code_fixed):
		if ((n < 0) || (codepos < 0) || (codepos >= code_size) || (n >= code_size - codepos)):
			char* message = c"in-process code buffer exhausted; start a new session"
			if (code_fixed_error_hook): (cast(code_fixed_error_callback*, code_fixed_error_hook))(message)
			println2(message)
			exit(1)
	if (code_size <= codepos + n):
		int x = (codepos + n) << 1
		code = realloc(code, code_size, x)
		code_size = x


# --- register-resident locals (docs/projects/register_allocation_pgo.md
# §2.2, unit R2) ---------------------------------------------------------
# The backend-side state of function-scoped register promotion. It lives
# here, in the first backend module, because code_generator/arm64.w (the
# prologue), x86.w (the emitters) and dwarf.w (the frame notes) all read
# it and are imported after this file; the scan and the promotion
# decision are in compiler/regalloc_scan.w.
#
# reg_lvalue / reg_lvalue_end: the register lvalue note. sym_emit_value
# (compiler/symbol_table.w) emits NO bytes for a promoted local; it records
# the register here with reg_lvalue_end = codepos, the same contract as
# the lea/imm/cmp notes in x86.w: valid only while nothing has been
# emitted since. Its consumers (promote_eax and the 32-bit loaders, the
# '=' rule, the declaration storage hooks, multi-assignment) take the
# register and clear the note before emitting. Any other emission while
# the note is current is a compiler bug the guard below reports instead
# of silently materialising a stale stack word.
int reg_lvalue
int reg_lvalue_end
int reg_lvalue_sym
# --no-regs / -O0: promote nothing.
int regalloc_disabled
# --no-cond-branch / -O0: &&, || and ! in a condition keep their
# value-producing form (grammar/cond_branch.w).
int cond_branch_disabled
# --no-loop-rotate / -O0: while/for loops keep their top-tested shape
# (grammar/while_statement.w, loop_rotate_on).
int loop_rotate_disabled
# --no-narrow-regs: int32/uint32 locals and arguments stay on the stack
# (unit A8, docs/projects/codegen_gap_plan.md §2.7); the reference for
# tests/regalloc_diff_test.w. The two masks name the promoted registers
# that hold a narrow value on x64, by hardware register number: a
# uint32 (zero-extended: every write is a 32-bit form) and an int32
# (sign-extended: a 32-bit write followed by movsxd). The register
# always holds the value exactly as the memory path's load would
# promote it, so every reader -- the register reads, the shuttle and
# compare folds, an addressing-mode index -- stays word-sized
# (code_generator/x86.w, regalloc_reg_kind); only the writers look here.
int narrow_regs_disabled
int regalloc_zx_mask
int regalloc_sx_mask
# A condition chain has emitted its branches and left its regions open
# for the consumer (grammar/cond_branch.w, cond_pending_*). The consumer
# clears it before it emits; any other emission while it is set is a
# value use of the chain, so emit/emit_i first give the chain its value
# form (cond_pending_materialize), which is a correct lowering of the
# pending state wherever it happens -- the check sits where the register
# lvalue guard does, so no grammar path can read the chain as a value
# without it.
int cond_pending
void cond_pending_materialize();   /* grammar/cond_branch.w */
# Registers the next prologue must push (set by the pre-scan, consumed by
# be_function_prologue), the registers the CURRENT function's prologue
# did push (a bitmask over hardware register numbers, and their count),
# and whether a scanned function's body is being compiled.
int regalloc_pending_mask
int regalloc_saved_mask
int regalloc_saved_count
int regalloc_active
int regalloc_function
# Promoted locals of the current function (0 lets the stack-slot
# assertions in x86.w return at once).
int regalloc_promoted_count

void regalloc_guard_fail();   /* compiler/regalloc_scan.w: the diagnostic */

# Direct calls (docs/projects/codegen_gap_plan.md §2.4, unit A4): a call
# whose callee is a known W function is one `call rel32` instead of
# materializing the callee's address, parking it on the stack and
# reloading it before `call eax`. The identifier primary notes such a
# callee here instead of emitting its address: kind 1 a function symbol
# (id = its table offset), kind 2 a generic instantiation whose body the
# drain compiles later (id = its instance index). Like the register
# lvalue note the callee note is valid only while nothing has been
# emitted since (direct_callee_end == codepos). The call suffix turns it
# into a call record keyed by the call's stack base (grammar/stack_slot.w),
# a primary not followed by '(' materializes the address instead, and
# any other emission while the note is current is a compiler bug the
# guard below reports.
int direct_callee_kind
int direct_callee_id
int direct_callee_end
# --no-direct-calls: every call reloads its callee into the accumulator.
int direct_calls_disabled
# --no-addr-modes: no [base+index*scale+disp] operands (unit A2,
# code_generator/x86.w's address note); every load and store goes
# through the accumulator address as before, the reference for
# tests/regalloc_diff_test.w and the fallback a miscompile report asks for.
int addr_modes_disabled
# --no-expr-regs (and -O0): no expression register stack (unit A3,
# code_generator/x86.w's ers_* section); every parked operand goes
# through 'push eax' / 'pop ebx' as before, the reference for
# tests/regalloc_diff_test.w and the fallback a miscompile report asks for.
int ers_disabled
# 1 while the function being compiled may contain a variable shift, a
# division or a modulo -- or was not scanned (compiler/regalloc_scan.w
# sets 0 only after seeing the whole body): the expression register
# stack then leaves ecx/edx (the shift count and the division's high
# half) alone and parks in r8-r11 only (nothing on x86).
int ers_hazard
# --no-x86-budget: x86-32 keeps its pre-A9 register budget -- no loop
# registers in ecx/edx (compiler/regalloc_scan.w, rl_target_mask), the
# reference for tests/regalloc_diff_test.w. Nothing on x64.
int x86_budget_disabled
# The caller-saved registers the open loops own (R3, rl_add /
# regalloc_loop_leave in compiler/regalloc_scan.w), as a bitmask over
# hardware register numbers: the expression register stack never parks
# in one of them.
int regalloc_loop_owned

void direct_callee_guard_fail();   /* grammar/stack_slot.w: the diagnostic */

void direct_callee_guard():
	if (direct_callee_end == codepos): direct_callee_guard_fail()

# The fail-closed guard: a current register lvalue note means some grammar
# path is about to emit code against the accumulator as if it held the
# local's address.
void regalloc_guard():
	if (reg_lvalue_end != 0):
		if (reg_lvalue_end == codepos): regalloc_guard_fail()


void emit(int n, char *s):
	if (reg_lvalue_end != 0): regalloc_guard()
	if (direct_callee_kind != 0): direct_callee_guard()
	if (cond_pending != 0): cond_pending_materialize()
	resize_code(n)
	for i in range(n):
		code[codepos] = s[i]
		codepos = codepos + 1


void emit_string(char* s):
	emit(strlen(s) + 1, s)


void emit_i(int v, int n):
	if (reg_lvalue_end != 0): regalloc_guard()
	if (direct_callee_kind != 0): direct_callee_guard()
	if (cond_pending != 0): cond_pending_materialize()
	resize_code(n)
	char* p = code + codepos
	save_i(p, v, n)
	codepos = codepos + n


# --- RW data segment (Stage 3 W^X split) --------------------------------
# Global-variable storage is appended here through these helpers, keeping
# the hot code-emission path (emit / emit_i) untouched.

void ensure_data(int n):
	if (data_size <= datapos + n):
		int x = (datapos + n) << 1
		if (x < 4096): x = 4096
		data = realloc(data, data_size, x)
		data_size = x


# Reserve n zero bytes and return the vaddr of the reserved region's start.
int emit_data_zeros(int n):
	ensure_data(n)
	int start = datapos
	for i in range(n):
		data[datapos] = 0
		datapos = datapos + 1
	return data_offset + start


# Append one target word (8 bytes on the 64-bit arm64 target).
void emit_data_word(int v):
	ensure_data(word_size)
	save_i(data + datapos, v, word_size)
	datapos = datapos + word_size


# --- Rebase table (PIE data pointers) ------------------------
# Pointer-sized cells in the RW data segment that hold absolute linked
# vaddrs (string-descriptor data pointers, global array headers) are
# recorded here during compilation. The container writer appends the
# table (count + entries, one word each) to the data segment and the
# entry stub adds the load slide to every listed cell at startup, so the
# image stays correct when the kernel slides it. Dynamic x64 PIE emits
# RELATIVE relocations from the same records instead. Code needs no
# entries: address materialization is PC-relative on arm64 and x64.

char* rebase_table
int rebase_table_size
int rebase_count


# Record the vaddr of one pointer-sized data cell whose stored value
# must be slid at startup.
void rebase_note(int vaddr):
	int needed = (rebase_count + 1) * 8
	if (rebase_table_size < needed):
		int x = needed << 1
		if (x < 4096): x = 4096
		rebase_table = realloc(rebase_table, rebase_table_size, x)
		rebase_table_size = x
	save_i(rebase_table + rebase_count * 8, vaddr, 8)
	rebase_count = rebase_count + 1


void emit_int8(int v):
	emit_i(v, 1)


void emit_int16(int v):
	emit_i(v, 2)


void emit_int32(int v):
	emit_i(v, 4)


void emit_int64(int v):
	emit_i(v, 8)


void emit_target_word(int v):
	if (word_size == 8): emit_int64(v)
	else: emit_int32(v)


void emit_int(int v):
	emit_int32(v)


void emit_zeros(int num):
	while (num > 0):
		emit_int8(0)
		num = num - 1


# Bounds-check kinds for be_bounds_branch (code_generator/x86.w, issue
# #228): the index is in ebx, the length or bound in eax, and
# BOUNDS_EAX_LE_LIMIT compares eax against an immediate limit. Each
# branches to its region when the condition holds.
enum BoundsKind:
	BOUNDS_EAX_NEG        # eax < 0
	BOUNDS_EBX_NEG        # ebx < 0
	BOUNDS_EBX_GT_EAX     # ebx > eax
	BOUNDS_EBX_LT_EAX     # ebx < eax
	BOUNDS_EBX_LE_EAX     # ebx <= eax
	BOUNDS_EAX_LE_LIMIT   # eax <= limit

# The signed relation a kind tests: 0 less, 1 greater, 2 less-or-equal.
int bounds_relation(int kind):
	if (kind == BOUNDS_EBX_GT_EAX): return 1
	if (kind >= BOUNDS_EBX_LE_EAX): return 2
	return 0
