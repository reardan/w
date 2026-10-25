# Differential fixture for tests/wllvm_test.w: functions whose x64 asm
# block is the whole body (docs/projects/asm_functions.md) lower through
# their assembled bytes, called with the native stack convention from a
# SysV shim: before the definition, through a function value, with more
# arguments than SysV passes in registers, with labels, and beside a block
# that falls through to its portable body. Prints each result; the exit
# status is a checksum. Not a standalone test (no wbuild directive).
import lib.lib


int sub2(int a, int b);


int sub2(int a, int b):
	asm x64:
		"mov rax,[rsp+0x10]"
		"sub rax,[rsp+8]"
		"ret"
	return a - b


# Argument k of n is at [rsp + 8*(n-k+1)]: a is the deepest.
int weigh8(int a, int b, int c, int d, int e, int f, int g, int h):
	asm x64:
		"mov rax,[rsp+0x40]"
		"mov rcx,[rsp+0x38]"
		"lea rax,[rax+rcx*2]"
		"mov rcx,[rsp+0x30]"
		"lea rcx,[rcx+rcx*2]"
		"add rax,rcx"
		"mov rcx,[rsp+0x28]"
		"shl rcx,2"
		"add rax,rcx"
		"add rax,[rsp+0x20]"
		"sub rax,[rsp+0x18]"
		"mov rcx,[rsp+0x10]"
		"imul rcx,rcx,7"
		"add rax,rcx"
		"mov rcx,[rsp+8]"
		"shl rcx,3"
		"add rax,rcx"
		"ret"
	return a + 2 * b + 3 * c + 4 * d + e - f + 7 * g + 8 * h


int sum_to(int n):
	asm x64:
		"mov rcx,[rsp+8]"
		"xor eax,eax"
		"loop: test rcx,rcx"
		"je done"
		"add rax,rcx"
		"dec rcx"
		"jmp loop"
		"done: ret"
	int total = 0
	for i in range(n + 1): total = total + i
	return total


# Negative inputs fall through to the W body.
int clamp_negative(int x):
	asm x64:
		"mov rax,[rsp+8]"
		"test rax,rax"
		"js portable"
		"ret"
	if (x < 0): return 0 - 100
	return x


# 1 when the asm block ran.
int asm_active():
	asm x64:
		"mov eax,1"
		"ret"
	return 0


type binary_op = fn(int, int) -> int


int apply2(binary_op* f, int a, int b):
	return f(a, b)


int main():
	int sum = 0
	list[int] results = list[int]{asm_active(), sub2(10, 3), sub2(3, 10), apply2(sub2, 8, 3), sum_to(100), weigh8(1, 2, 3, 4, 5, 6, 7, 8), weigh8(0 - 1, 0, 0, 0, 0, 9, 0, 1), clamp_negative(42), clamp_negative(0 - 5)}
	for value in results:
		println(value)
		sum = sum + value
	results.free()
	return sum & 255
