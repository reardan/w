# wbuild: binary=wvm_syscall_bench_fixture arch=x64
# wbuild: target=wvm_syscall_bench_vmcall dep=wv2
# wbuild: step="bin/wv2 x64 --syscall-abi=vmcall tests/wvm_syscall_bench_fixture.w -o bin/wvm_syscall_bench_vmcall"
import lib.lib

int main():
	for i in range(100000):
		if (syscall(186, 0, 0, 0) != 1): return 1
	return 0
