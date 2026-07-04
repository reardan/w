/*
Calling-convention shims for extern (shared-library) functions.

W's internal convention pushes every argument on the stack (last argument
on top, caller cleans up) and returns in eax/rax. C libraries follow the
platform ABI instead, so each extern gets a generated stub that converts
between the two and jumps through the function's GOT slot (which the
dynamic loader fills in before the entry point runs):

  x64  System V: first six args in rdi/rsi/rdx/rcx/r8/r9, the rest on a
                 16-byte-aligned stack, al = number of vector registers.
  x86  cdecl:    all args re-pushed right-to-left onto a 16-byte-aligned
                 stack (modern i386 libc uses SSE).

At stub entry rsp/esp points at the return address, so W argument i (0
based) sits at [sp + word_size * (n - i)] and the callee slot just past it.
*/
import code_generator.code_emitter


# System V AMD64 stub for an n-argument import.
void emit_ffi_shim_x64(int n, int got_vaddr):
	# First six arguments go into registers, read before the frame is set up.
	if (n >= 1):
		emit(4, c"\x48\x8b\xbc\x24")   /* mov rdi,[rsp+disp32] */
		emit_int32(n << 3)
	if (n >= 2):
		emit(4, c"\x48\x8b\xb4\x24")   /* mov rsi,[rsp+disp32] */
		emit_int32((n - 1) << 3)
	if (n >= 3):
		emit(4, c"\x48\x8b\x94\x24")   /* mov rdx,[rsp+disp32] */
		emit_int32((n - 2) << 3)
	if (n >= 4):
		emit(4, c"\x48\x8b\x8c\x24")   /* mov rcx,[rsp+disp32] */
		emit_int32((n - 3) << 3)
	if (n >= 5):
		emit(4, c"\x4c\x8b\x84\x24")   /* mov r8,[rsp+disp32] */
		emit_int32((n - 4) << 3)
	if (n >= 6):
		emit(4, c"\x4c\x8b\x8c\x24")   /* mov r9,[rsp+disp32] */
		emit_int32((n - 5) << 3)

	emit(1, c"\x55")               /* push rbp */
	emit(3, c"\x48\x89\xe5")       /* mov rbp,rsp */
	emit(4, c"\x48\x83\xe4\xf0")   /* and rsp,-16 */

	int stack_args = n - 6
	if (stack_args < 0):
		stack_args = 0
	# An odd number of stack pushes would leave rsp 8 off a 16-byte boundary.
	if ((stack_args & 1) == 1):
		emit(4, c"\x48\x83\xec\x08")   /* sub rsp,8 */

	# Push args 7..n in reverse so arg7 lands at the lowest address.
	int i = n - 1
	while (i >= 6):
		emit(2, c"\xff\xb5")           /* push qword [rbp+disp32] */
		emit_int32(8 + ((n - i) << 3))
		i = i - 1

	emit(2, c"\x31\xc0")           /* xor eax,eax (0 vector regs, for varargs) */
	emit(3, c"\xff\x14\x25")       /* call qword ptr [abs32] */
	emit_int32(got_vaddr)
	emit(3, c"\x48\x89\xec")       /* mov rsp,rbp */
	emit(1, c"\x5d")               /* pop rbp */
	emit(1, c"\xc3")               /* ret */


# cdecl stub for an n-argument import.
void emit_ffi_shim_x86(int n, int got_vaddr):
	emit(1, c"\x55")           /* push ebp */
	emit(2, c"\x89\xe5")       /* mov ebp,esp */
	emit(3, c"\x83\xe4\xf0")   /* and esp,-16 */

	# Pad so the n 4-byte pushes finish on a 16-byte boundary.
	int pad = (16 - ((n << 2) & 15)) & 15
	if (pad > 0):
		emit(2, c"\x83\xec")   /* sub esp,imm8 */
		emit_int8(pad)

	# Push args right-to-left so arg0 ends on top (cdecl order).
	int i = n - 1
	while (i >= 0):
		emit(2, c"\xff\xb5")   /* push dword [ebp+disp32] */
		emit_int32(4 + ((n - i) << 2))
		i = i - 1

	emit(2, c"\xff\x15")       /* call dword ptr [abs32] */
	emit_int32(got_vaddr)
	emit(2, c"\x89\xec")       /* mov esp,ebp */
	emit(1, c"\x5d")           /* pop ebp */
	emit(1, c"\xc3")           /* ret */


void emit_ffi_shim(int n, int got_vaddr):
	if (word_size == 8):
		emit_ffi_shim_x64(n, got_vaddr)
	else:
		emit_ffi_shim_x86(n, got_vaddr)
