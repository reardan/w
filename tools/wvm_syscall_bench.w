# wbuild: binary=wvm_syscall_bench arch=x64 tag=tests dep=wvm_syscall_bench_fixture dep=wvm_syscall_bench_vmcall
# Run after wbuild wvm_syscall_bench_fixture wvm_syscall_bench_vmcall.
# Wall-clock measurement of 100000 gettid round trips, alternating ABI order.
# Includes CPU setup; no performance threshold on shared/uncontrolled hosts.
import lib.vmm.cell
import lib.file
import lib.process

int syscall_bench_ns():
	timespec ts
	if (sys_clock_gettime(clock_monotonic, cast(int, &ts)) < 0): return 0
	return ts.seconds * 1000000000 + ts.nanoseconds

int main():
	char*[2] paths
	paths[0] = c"bin/wvm_syscall_bench_fixture"
	paths[1] = c"bin/wvm_syscall_bench_vmcall"
	int[2] total
	total[0] = 0
	total[1] = 0
	for repeat in range(10):
		int abi = repeat % 2
		int fd = open(paths[abi], 0, 0)
		if (fd < 0): return 2
		int size = file_size(fd)
		close(fd)
		char* image = file_read_text(paths[abi])
		if (image == 0): return 2
		vm_cell* cell = cell_new()
		if (cell == 0): return 2
		int ok = cell_elf_load(cell, image, size)
		free(image)
		char** argv = strv_new(1)
		argv[0] = c"bench"
		if (ok): ok = cell_stack(cell, 1, argv)
		free(cast(void*, argv))
		int start = syscall_bench_ns()
		if (ok): ok = cell_run(cell, 30000)
		int elapsed = syscall_bench_ns() - start
		if (ok == 0 || cell.status != 0):
			if (cell.error != 0): println(cell.error)
			cell_free(cell)
			return 1
		total[abi] = total[abi] + elapsed
		cell_free(cell)
	println(c"mean ns/gettid (5 x 100000 calls, includes VM setup):")
	print(c"syscall=")
	print(total[0] / 500000)
	print(c" vmcall=")
	println(total[1] / 500000)
	return 0
