# IEEE binary16 storage conversions for the Wasm MVP target. Keep the
# sign on the operand stack and round the positive magnitude with integer
# operations, so signed zero, gradual underflow and ties-to-even do not
# depend on a host floating-point mode. The virtual xmm0 is register 5.


# Push an operation on the current magnitude without changing $ax.
void wasm_half_ax_op(int opcode, int value):
	wasm_get_ax()
	wasm_i32_const(value)
	wasm_op(opcode)


# An expression-valued if; these private regions have no branch targets
# and balance before returning to the shared structured-control emitter.
void wasm_half_if():
	wasm_op(0x04)
	wasm_op(0x7f)   # if (result i32)


void wasm_half_to_single():
	wasm_movd_eax_xmm0()
	wasm_half_ax_op(0x71, 0x8000)
	wasm_i32_const(16)
	wasm_op(0x74)   # sign << 16, kept below the magnitude result
	wasm_half_ax_op(0x71, 0x7fff)
	wasm_set_ax()
	wasm_half_ax_op(0x4f, 0x7c00)   # magnitude >= half infinity
	wasm_half_if()
		wasm_half_ax_op(0x71, 0x3ff)
		wasm_i32_const(13)
		wasm_op(0x74)
		wasm_i32_const(0x7f800000)
		wasm_op(0x72)
		wasm_half_ax_op(0x4b, 0x7c00)
		wasm_half_if()
			wasm_i32_const(0x400000)   # quiet a signaling NaN
		wasm_op(0x05)
			wasm_i32_const(0)
		wasm_op(0x0b)
		wasm_op(0x72)
	wasm_op(0x05)
		wasm_half_ax_op(0x49, 0x400)
		wasm_half_if()
			# Subnormal h has exact value h * 2^-24, representable in f32.
			wasm_get_ax()
			wasm_op(0xb3)   # f32.convert_i32_u
			wasm_op(0x43)
			emit_int32(0x33800000)   # f32.const 2^-24
			wasm_op(0x94)   # f32.mul
			wasm_op(0xbc)   # i32.reinterpret_f32
		wasm_op(0x05)
			wasm_half_ax_op(0x74, 13)
			wasm_i32_const(0x38000000)   # exponent bias adjustment
			wasm_op(0x6a)
		wasm_op(0x0b)
	wasm_op(0x0b)
	wasm_op(0x72)   # restore sign
	wasm_op(0xbe)
	wasm_reg_set(5)


void wasm_single_to_half():
	wasm_reg_get(3)   # preserve $cx below sign and result
	wasm_movd_eax_xmm0()
	wasm_half_ax_op(0x76, 16)
	wasm_i32_const(0x8000)
	wasm_op(0x71)
	wasm_half_ax_op(0x71, 0x7fffffff)
	wasm_set_ax()
	wasm_half_ax_op(0x4f, 0x7f800000)
	wasm_half_if()
		wasm_half_ax_op(0x4b, 0x7f800000)
		wasm_half_if()
			wasm_half_ax_op(0x76, 13)
			wasm_i32_const(0x3ff)
			wasm_op(0x71)
			wasm_i32_const(0x7e00)   # retain payload and quiet NaNs
			wasm_op(0x72)
		wasm_op(0x05)
			wasm_i32_const(0x7c00)
		wasm_op(0x0b)
	wasm_op(0x05)
		wasm_half_ax_op(0x4f, 0x477ff000)   # halfway from max finite to infinity
		wasm_half_if()
			wasm_i32_const(0x7c00)
		wasm_op(0x05)
			wasm_half_ax_op(0x49, 0x38800000)   # smaller than minimum normal half
			wasm_half_if()
				wasm_half_ax_op(0x49, 0x33000000)   # below half of minimum subnormal
				wasm_half_if()
					wasm_i32_const(0)
				wasm_op(0x05)
					# shift = 126 - f32 exponent (14..24)
					wasm_i32_const(126)
					wasm_half_ax_op(0x76, 23)
					wasm_op(0x6b)
					wasm_reg_set(3)
					wasm_half_ax_op(0x71, 0x7fffff)
					wasm_i32_const(0x800000)
					wasm_op(0x72)
					wasm_set_ax()
					# (mantissa + (1 << (shift-1)) - 1 + retained_lsb) >> shift
					wasm_get_ax()
					wasm_i32_const(1)
					wasm_reg_get(3)
					wasm_i32_const(1)
					wasm_op(0x6b)
					wasm_op(0x74)
					wasm_i32_const(1)
					wasm_op(0x6b)
					wasm_op(0x6a)
					wasm_get_ax()
					wasm_reg_get(3)
					wasm_op(0x76)
					wasm_i32_const(1)
					wasm_op(0x71)
					wasm_op(0x6a)
					wasm_reg_get(3)
					wasm_op(0x76)
				wasm_op(0x0b)
			wasm_op(0x05)
				# Normal: discard 13 fraction bits, with ties to an even LSB.
				wasm_half_ax_op(0x6a, 0xfff)
				wasm_half_ax_op(0x76, 13)
				wasm_i32_const(1)
				wasm_op(0x71)
				wasm_op(0x6a)
				wasm_i32_const(0x38000000)
				wasm_op(0x6b)
				wasm_i32_const(13)
				wasm_op(0x76)
			wasm_op(0x0b)
		wasm_op(0x0b)
	wasm_op(0x0b)
	wasm_op(0x72)   # restore sign
	wasm_op(0xbe)
	wasm_reg_set(5)
	wasm_reg_set(3)
