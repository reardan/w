# bfloat16 is the upper half of IEEE float32: 1 sign, 8 exponent and 7
# fraction bits. Integer conversion works on every target, including CPUs
# without AVX512_BF16 and PTX targets predating native bfloat instructions.
# Only the accumulator changes; the secondary operand stays live. Stores
# round to nearest, ties to even, independently of FP control registers.
# NaNs retain sign/payload and become quiet: rounding must never turn a
# small NaN payload into infinity or wrap a large payload into zero.

void bfloat16_to_float32_eax():
	if (target_isa == 3):
		ptx_line(c"and.b64 %ax, %ax, 0xffff;")
		ptx_line(c"shl.b64 %ax, %ax, 16;")
	elif (target_isa == 2): wasm_ax_op_const(0x74, 16)
	elif (target_isa == 1): a64(op(0x53, 0x103c00))   # lsl w0,w0,#16
	else: emit(3, c"\xc1\xe0\x10")   # shl eax,16 (32-bit on x64 too)


void float32_to_bfloat16_eax():
	if (target_isa == 3):
		ptx_line(c"cvt.u32.u64 %w0, %ax;")
		ptx_line(c"and.b32 %w1, %w0, 0x7fffffff;")
		ptx_line(c"setp.gt.u32 %p, %w1, 0x7f800000;")
		ptx_line(c"shr.u64 %cx, %ax, 16;")
		ptx_line(c"and.b64 %cx, %cx, 0xffff;")
		ptx_line(c"or.b64 %cx, %cx, 0x40;")
		ptx_line(c"shr.u32 %w1, %w0, 16;")
		ptx_line(c"and.b32 %w1, %w1, 1;")
		ptx_line(c"add.u32 %w0, %w0, %w1;")
		ptx_line(c"add.u32 %w0, %w0, 0x7fff;")
		ptx_line(c"shr.u32 %w0, %w0, 16;")
		ptx_line(c"cvt.u64.u32 %ax, %w0;")
		ptx_line(c"@%p mov.b64 %ax, %cx;")
	elif (target_isa == 2):
		# select(upper | quiet_bit, rounded, abs_bits > infinity).
		# Keep intermediates on the Wasm operand stack, leaving W's
		# evaluation stack and all other accumulator locals untouched.
		wasm_get_ax()
		wasm_i32_const(16)
		wasm_op(0x76)   # i32.shr_u
		wasm_i32_const(0x40)
		wasm_op(0x72)   # i32.or
		wasm_get_ax()
		wasm_i32_const(0x7fff)
		wasm_op(0x6a)   # i32.add
		wasm_get_ax()
		wasm_i32_const(16)
		wasm_op(0x76)
		wasm_i32_const(1)
		wasm_op(0x71)   # i32.and
		wasm_op(0x6a)
		wasm_i32_const(16)
		wasm_op(0x76)
		wasm_get_ax()
		wasm_i32_const(0x7fffffff)
		wasm_op(0x71)
		wasm_i32_const(0x7f800000)
		wasm_op(0x4b)   # i32.gt_u
		wasm_op(0x1b)   # select
		wasm_set_ax()
	elif (target_isa == 1):
		a64(op(0x2a, 0x0003e9))   # mov w9,w0
		a64(op(0x53, 0x107c0a))   # lsr w10,w0,#16
		a64(op(0x12, 0x00014b))   # and w11,w10,#1
		a64(op(0x0b, 0x0b0000))   # add w0,w0,w11
		a64(op(0x52, 0x8fffeb))   # mov w11,#0x7fff
		a64(op(0x0b, 0x0b0000))   # add w0,w0,w11
		a64(op(0x53, 0x107c00))   # lsr w0,w0,#16
		a64(op(0x32, 0x1a014a))   # orr w10,w10,#0x40
		a64(op(0x12, 0x007929))   # and w9,w9,#0x7fffffff
		a64(op(0x52, 0xaff00b))   # mov w11,#0x7f800000
		a64(op(0x6b, 0x0b013f))   # cmp w9,w11
		a64(op(0x1a, 0x808140))   # csel w0,w10,w0,hi
	else:
		# Save full-width scratch registers, including register parks
		# on x64. The private pushes are balanced inside this emitter.
		emit(2, c"\x51\x52")   # push ecx/rcx; push edx/rdx
		emit(4, c"\x89\xc1\x89\xc2")   # mov ecx,eax; mov edx,eax
		emit(6, c"\x81\xe2\xff\xff\xff\x7f")   # and edx,0x7fffffff
		emit(6, c"\x81\xfa\x00\x00\x80\x7f")   # cmp edx,0x7f800000
		emit(2, c"\x77\x12")   # ja NaN
		emit(3, c"\xc1\xe9\x10")   # shr ecx,16
		emit(3, c"\x83\xe1\x01")   # and ecx,1
		emit(2, c"\x01\xc8")   # add eax,ecx
		emit(5, c"\x05\xff\x7f\x00\x00")   # add eax,0x7fff
		emit(3, c"\xc1\xe8\x10")   # shr eax,16
		emit(2, c"\xeb\x06")   # jmp done
		emit(3, c"\xc1\xe8\x10")   # NaN: shr eax,16
		emit(3, c"\x83\xc8\x40")   # or eax,0x40
		emit(2, c"\x5a\x59")   # done: pop edx/rdx; pop ecx/rcx
