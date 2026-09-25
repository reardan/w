/*
lib.dlcall: optional shared libraries at run time -- dlopen/dlsym plus
C-ABI call trampolines (x64 Linux only).

Why this exists: `c_lib` records a DT_NEEDED entry and `extern` binds
eagerly through a GOT slot, so a program that names a library the
machine lacks fails in the dynamic loader before main runs -- there is
no way to probe for it. That is fine for libcuda (it ships with the
driver) but not for toolkit-only libraries such as libcublas, which a
program should use when present and skip otherwise (lib/cublas.w).
This module only needs libdl.so.2 at load time (present on every glibc
system; on glibc >= 2.34 the symbols live in libc.so.6 and libdl.so.2
is a stub, and the loader's global lookup finds them either way).

The catch: a dlsym result is a C function pointer, and W function
pointers use W's stack convention (arguments pushed in declaration
order, last argument on top; result in rax). An indirect W call to a C
symbol would pass garbage. dl_trampoline(sym, nargs) therefore builds a
small x64 stub in an executable page that converts one W call into a
System V call and returns a W-callable address:

	push rbp; mov rbp, rsp; and rsp, -16
	[sub rsp, 8 when the stack-argument count is odd]
	push qword [rbp+off(i)]      for i = nargs-1 .. 6 (stack args)
	mov  rdi/rsi/rdx/rcx/r8/r9, qword [rbp+off(i)]   for i = 0 .. 5
	mov  r11, sym; xor eax, eax; call r11
	movsxd rax, eax              (only when ret32: C int results)
	leave; ret

where off(i) = 16 + 8*(nargs-1-i) is W's slot for argument i. al = 0
keeps variadic callees (printf-style) happy as long as no float is
passed. Scope: integer/pointer arguments only (floats would need xmm
registers -- pass them by pointer, as cuBLAS's alpha/beta already are)
and an integer/pointer result; every C callee-saved register the
trampoline touches is restored by `leave`.

Cast the returned address to a typed W function pointer and call it:

	type strlen_fn = fn(char*) -> int
	strlen_fn* f = cast(strlen_fn*, dl_trampoline(dl_sym(h, c"strlen"), 1, 0))
	int n = f(c"abc")

dl_trampoline_argv(sym, nargs, ret32) is the array form: the stub takes
ONE W argument, a pointer to nargs 8-byte words, and loads argument i
from word i (`mov r10, [rbp+16]`, then [r10+8*i] in place of off(i)).
Call it through dl_call(stub, args). It exists because a `type ... =
fn(...)` alias currently overflows the compiler's parameter buffer past
10 parameters (grammar/type_alias_declaration.w mallocs 10 slots with
no bound check -- cuBLAS gemm takes 14), and it is also the convenient
shape for arguments assembled at run time.
*/
import lib.lib
import code_generator.integer

c_lib "libdl.so.2"

extern char* dlopen(char* path, int flags)
extern char* dlsym(char* handle, char* name)


int __dl_page
int __dl_page_used


# dlopen with RTLD_NOW (2) | RTLD_LOCAL (0). Returns 0 when the library
# (or one of its dependencies) is missing -- never fatal.
char* dl_open(char* soname):
	return dlopen(soname, 2)


# dlsym; 0 when the symbol is missing.
char* dl_sym(char* handle, char* name):
	if (handle == 0):
		return cast(char*, 0)
	return dlsym(handle, name)


void __dl_emit(char* p, int b):
	p[__dl_page_used] = b
	__dl_page_used = __dl_page_used + 1


void __dl_emit32(char* p, int v):
	save_i(p + __dl_page_used, v, 4)
	__dl_page_used = __dl_page_used + 4


# Emit `mov <arg reg i>, qword [base+disp32]` for System V integer
# argument register i (rdi rsi rdx rcx r8 r9). base is rbp (W-argument
# mode) or r10 (argv mode); the REX byte and ModRM differ accordingly.
void __dl_emit_load_arg(char* p, int i, int argv, int disp):
	int rex = 0x48
	if (i >= 4):
		rex = 0x4c
	if (argv):
		rex = rex + 1    # REX.B: base register r10
	__dl_emit(p, rex)
	__dl_emit(p, 0x8b)
	# reg field per register, rm = 101 (rbp) or 010 (r10), mod = 10
	int reg = 7
	if (i == 1):
		reg = 6
	else if (i == 2):
		reg = 2
	else if (i == 3):
		reg = 1
	else if (i == 4):
		reg = 0
	else if (i == 5):
		reg = 1
	int rm = 5
	if (argv):
		rm = 2
	__dl_emit(p, 0x80 + reg * 8 + rm)
	__dl_emit32(p, disp)


# Byte offset of C argument i: W's stack slot above the saved rbp and
# return address, or word i of the argv array.
int __dl_arg_disp(int i, int nargs, int argv):
	if (argv):
		return 8 * i
	return 16 + 8 * (nargs - 1 - i)


int __dl_build(char* sym, int nargs, int ret32, int argv):
	if (sym == 0 || nargs < 0 || nargs > 32 || __word_size__ != 8):
		return 0
	int need = 64 + nargs * 8
	if (__dl_page == 0 || __dl_page_used + need > 4096):
		__dl_page = mmap(0, 4096, 3, 34)
		if (__dl_page < 0):
			__dl_page = 0
			return 0
		__dl_page_used = 0
	else:
		if (mprotect(__dl_page, 4096, 3) != 0):
			return 0
	char* p = cast(char*, __dl_page)
	int start = __dl_page_used
	__dl_emit(p, 0x55)    # push rbp
	__dl_emit(p, 0x48)    # mov rbp, rsp
	__dl_emit(p, 0x89)
	__dl_emit(p, 0xe5)
	__dl_emit(p, 0x48)    # and rsp, -16
	__dl_emit(p, 0x83)
	__dl_emit(p, 0xe4)
	__dl_emit(p, 0xf0)
	if (argv):
		__dl_emit(p, 0x4c)    # mov r10, qword [rbp+16]
		__dl_emit(p, 0x8b)
		__dl_emit(p, 0x95)
		__dl_emit32(p, 16)
	int nstack = 0
	if (nargs > 6):
		nstack = nargs - 6
	if (nstack % 2 == 1):
		__dl_emit(p, 0x48)    # sub rsp, 8
		__dl_emit(p, 0x83)
		__dl_emit(p, 0xec)
		__dl_emit(p, 0x08)
	int i = nargs - 1
	while (i >= 6):
		if (argv):
			__dl_emit(p, 0x41)    # push qword [r10+disp32]
			__dl_emit(p, 0xff)
			__dl_emit(p, 0xb2)
		else:
			__dl_emit(p, 0xff)    # push qword [rbp+disp32]
			__dl_emit(p, 0xb5)
		__dl_emit32(p, __dl_arg_disp(i, nargs, argv))
		i = i - 1
	i = 0
	while (i < nargs && i < 6):
		__dl_emit_load_arg(p, i, argv, __dl_arg_disp(i, nargs, argv))
		i = i + 1
	__dl_emit(p, 0x49)    # mov r11, imm64
	__dl_emit(p, 0xbb)
	save_i(p + __dl_page_used, cast(int, sym), 8)
	__dl_page_used = __dl_page_used + 8
	__dl_emit(p, 0x31)    # xor eax, eax
	__dl_emit(p, 0xc0)
	__dl_emit(p, 0x41)    # call r11
	__dl_emit(p, 0xff)
	__dl_emit(p, 0xd3)
	if (ret32):
		__dl_emit(p, 0x48)    # movsxd rax, eax
		__dl_emit(p, 0x63)
		__dl_emit(p, 0xc0)
	__dl_emit(p, 0xc9)    # leave
	__dl_emit(p, 0xc3)    # ret
	# Keep the next stub 16-byte aligned.
	while (__dl_page_used % 16 != 0):
		__dl_emit(p, 0xcc)
	if (mprotect(__dl_page, 4096, 5) != 0):
		return 0
	return __dl_page + start


# A W-callable address that forwards nargs integer/pointer arguments to
# the C function sym. ret32 = 1 sign-extends a 32-bit C int result (the
# upper half of rax is undefined after such a call); 0 returns rax as is
# (pointers, 64-bit integers). Returns 0 when sym is 0, nargs is out of
# range (0..32) or the target is not x64. Stubs are packed into 4 KB
# pages that are mapped RW, filled, then flipped to RX.
int dl_trampoline(char* sym, int nargs, int ret32):
	return __dl_build(sym, nargs, ret32, 0)


# The array form (see the header): the stub takes one int* holding the
# nargs argument words. Call it with dl_call.
int dl_trampoline_argv(char* sym, int nargs, int ret32):
	return __dl_build(sym, nargs, ret32, 1)


type dl_argv_fn = fn(int*) -> int


# Invoke a dl_trampoline_argv stub on an argument array.
int dl_call(int stub, int* args):
	dl_argv_fn* f = cast(dl_argv_fn*, stub)
	return f(args)
