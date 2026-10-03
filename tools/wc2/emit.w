# Minimal static Linux ELF32 adapter. Production ELF emission owns compiler
# globals/dynamic linking/debug sections; this leaf needs only RX code and a
# non-executable stack. The image owns its bytes, independently of its module.
import tools.wc2.x86
import code_generator.integer
import lib.framing


asm_buffer* wc2_emit(wc2_module* m):
	wc2_node* expression = wc2_validate_executable(m)
	if (expression == 0): return 0
	asm_buffer* out = asm_buffer_new()
	# ELF header (52 bytes), PT_LOAD and PT_GNU_STACK (32 bytes each).
	for i in range(116): asm_buffer_byte(out, 0)
	char* header = out.data
	mem_copy(header, c"\x7fELF\x01\x01\x01", 7)
	save_int16(header + 16, 2)       # ET_EXEC
	save_int16(header + 18, 3)       # EM_386
	save_int32(header + 20, 1)      # EV_CURRENT
	save_int32(header + 24, 0x08048000 + 116)
	save_int32(header + 28, 52)     # program header offset
	save_int16(header + 40, 52)
	save_int16(header + 42, 32)
	save_int16(header + 44, 2)
	save_int32(header + 52, 1)      # PT_LOAD, file offset zero
	save_int32(header + 60, 0x08048000)
	save_int32(header + 64, 0x08048000)
	save_int32(header + 76, 5)      # PF_R | PF_X
	save_int32(header + 80, 4096)
	save_int32(header + 84, 0x6474e551)  # PT_GNU_STACK
	save_int32(header + 108, 6)     # PF_R | PF_W
	save_int32(header + 112, 16)
	# Process entry calls a real function, then exits with its return value.
	asm_buffer_byte(out, 0xe8)
	int call_fixup = out.length
	asm_buffer_int32(out, 0)
	wc2_x86(out, c"mov", 3, 0)
	wc2_immediate(out, 0, 1)        # Linux i386 SYS_exit
	asm_buffer_byte(out, 0xcd)
	asm_buffer_byte(out, 0x80)
	asm_buffer_patch_int32(out, call_fixup, out.length - call_fixup - 4)
	wc2_emit_expression(m, expression, out)
	wc2_x86(out, c"ret", -1, -1)
	# Buffer growth invalidates 'header'; patch through the current buffer.
	asm_buffer_patch_int32(out, 68, out.length)
	asm_buffer_patch_int32(out, 72, out.length)
	return out


# Complete the image before touching the destination. An exclusive sibling
# temporary plus rename preserves old output on validation and I/O failures.
int wc2_write_executable(char* path, asm_buffer* image):
	string_builder* temporary = string_new()
	string_append(temporary, path)
	string_append(temporary, c".wc2.")
	string_append_int(temporary, getpid())
	int fd = open(temporary.data, 193, 493)  # WRONLY | CREAT | EXCL, 0755
	if (fd < 0):
		string_free(temporary)
		return 0
	int ok = write_all(fd, image.data, image.length) == image.length
	if (close(fd) < 0): ok = 0
	if (ok): ok = chmod(temporary.data, 493) == 0
	if (ok): ok = rename(temporary.data, path) == 0
	if (ok == 0): unlink(temporary.data)
	string_free(temporary)
	return ok
