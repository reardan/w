# Long-mode ring-3 CPU state, supervisor syscall/fault gates, and TSS.
import lib.vmm.elf


void cell_segment(char* segment, int selector, int kind, int privilege, int code):
	mem_fill[char](segment, 0, 24)
	int limit = (65535 << 16) | 65535
	save_int32(segment + 8, limit)
	save_int16(segment + 12, selector)
	segment[14] = kind
	segment[15] = 1
	segment[16] = privilege
	segment[17] = 1 - code # db
	segment[18] = 1 # s
	segment[19] = code # l
	segment[20] = 1 # g


void cell_descriptor(char* destination, int access, int flags):
	mem_fill[char](destination, 0, 8)
	save_int16(destination, 65535)
	destination[5] = access
	destination[6] = flags


int cell_cpu_setup(vm_cell* cell):
	kvm_machine* vm = cell.machine
	if (kvm_set_supported_cpuid(vm) < 0): return cell_fail(cell, c"KVM CPUID setup failed")
	if (kvm_get_sregs(vm, cell.sregs) < 0): return cell_fail(cell, c"KVM_GET_SREGS failed")
	char* s = cell.sregs
	cell_segment(s, 35, 11, 3, 1) # CS = 0x23
	for i in range(1, 6): cell_segment(s + i * 24, 27, 3, 3, 0)
	# Flat GDT: kernel code/data, user data/code, and 64-bit TSS.
	char* gdt = cell.ram + 16384
	cell_descriptor(gdt + 8, 155, 175)
	cell_descriptor(gdt + 16, 147, 207)
	cell_descriptor(gdt + 24, 243, 207)
	cell_descriptor(gdt + 32, 251, 175)
	save_int16(gdt + 40, 103)
	save_int16(gdt + 42, 24576)
	gdt[45] = 137 # available 64-bit TSS, base 0x6000
	char* tss = cell.ram + 24576
	save_int64(tss + 4, 1048576) # rsp0: supervisor exception stack
	save_int16(tss + 102, 104) # no I/O permission bitmap
	mem_fill[char](s + 144, 0, 48)
	save_int64(s + 144, 24576)
	save_int32(s + 152, 103)
	save_int16(s + 156, 40)
	s[158] = 11 # busy TSS
	s[159] = 1
	s[190] = 1 # LDT unusable
	save_int64(s + 192, 16384)
	save_int16(s + 200, 55)
	save_int64(s + 208, 20480)
	save_int16(s + 216, 4095)
	# Every exception has an exit gate. Host validates the port and RIP,
	# retrieves the faulting RIP from the supervisor exception stack.
	for i in range(256):
		int handler = 32768 + i * 16
		char* gate = cell.ram + 20480 + i * 16
		save_int16(gate, handler)
		save_int16(gate + 2, 8)
		gate[5] = 142
		save_int16(gate + 6, handler >> 16)
		char* code = cell.ram + handler
		code[0] = 184 # mov eax,vector
		save_int32(code + 1, i)
		code[5] = 230 # out 0xea,al
		code[6] = 234
		code[7] = 244 # hlt (host ends execution before it)
	# OUT preserves syscall arguments. Flush the guest TLB before every
	# SYSRET so host edits to page permissions take effect immediately.
	# RAX is saved in supervisor scratch, never on an untrusted stack.
	char* trampoline = cell.ram + CELL_TRAMPOLINE
	mem_copy[char](trampoline, c"\xe6\xe9\x48\xa3", 4)
	save_int64(trampoline + 4, CELL_TRAMPOLINE + 256)
	mem_copy[char](trampoline + 12, c"\x0f\x20\xd8\x0f\x22\xd8\x48\xa1", 8)
	save_int64(trampoline + 20, CELL_TRAMPOLINE + 256)
	mem_copy[char](trampoline + 28, c"\x48\x0f\x07", 3)
	int pg = 1
	save_int64(s + 224, (pg << 31) | 65587) # PG|WP|NE|ET|MP|PE
	save_int64(s + 240, 4096) # CR3
	save_int64(s + 248, 1568) # PAE|OSFXSR|OSXMMEXCPT
	save_int64(s + 264, 3329) # SCE|LME|LMA|NXE
	if (kvm_set_sregs(vm, s) < 0): return cell_fail(cell, c"KVM long-mode setup failed")
	# MSRs: STAR, LSTAR, FMASK. Upper STAR selector yields user CS=0x23,
	# SS=0x1b; lower STAR selector yields kernel CS=8, SS=16.
	int star = 16
	star = (star << 48) | (8 << 32)
	if (kvm_set_msr(vm, (49152 << 16) | 129, star) < 0): return cell_fail(cell, c"KVM STAR setup failed")
	if (kvm_set_msr(vm, (49152 << 16) | 130, CELL_TRAMPOLINE) < 0): return cell_fail(cell, c"KVM LSTAR setup failed")
	if (kvm_set_msr(vm, (49152 << 16) | 132, 263936) < 0): return cell_fail(cell, c"KVM FMASK setup failed")
	char[416] fpu
	mem_fill[char](&fpu[0], 0, 416)
	save_int16(&fpu[128], 895)
	save_int32(&fpu[408], 8064)
	if (sys_ioctl(vm.cpu_fd, kvm_request(1, 416, 141), cast(int, &fpu[0])) < 0): return cell_fail(cell, c"KVM FPU setup failed")
	save_int64(cell.regs + 48, cell.stack)
	save_int64(cell.regs + 128, cell.entry)
	save_int64(cell.regs + 136, 2) # IF=0, IOPL=0
	if (kvm_set_regs(vm, cell.regs) < 0): return cell_fail(cell, c"KVM_SET_REGS failed")
	return 1
