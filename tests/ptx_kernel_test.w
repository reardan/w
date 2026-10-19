# wbuild: timeout=120000
/*
ptx_kernel_test: the device-code emitter (code_generator/ptx.w) end to
end. tests/ptx_kernel_probe.w declares kernels whose bodies reach emit
helpers ordinary gpu fixtures never execute -- binary operands complex
enough to spill %bx and push stack slots, compound assignment to
non-promoted locals, 32-bit bitwise ops, unsigned compares, short
circuit ||, truthy while/if, struct assignment with inline array
fields, float<->int conversions in both directions and widths, float64
negation, float compares in both operand orders, and the `debugger;`
trap -- and the test compiles it with --ptx=<dump> and asserts the
embedded module carries each shape. Nothing is launched, so the test
runs on hosts without a CUDA driver (docs/projects/cuda.md: kernels
compile to an embedded PTX module; only `launch` touches the driver).
*/
import lib.testing
import lib.file
import lib.process
import lib.str

int ptx_has(char* dump, char* needle):
	return contains(dump, needle) >= 0

void test_ptx_kernel_module_dump():
	char* dump_path = f"bin/ptx_kernel_{getpid()}.ptx"
	char* out_path = f"bin/ptx_kernel_{getpid()}.out"
	char** args = strv_new(9)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"x64")
	strv_set(args, 2, f"--ptx={dump_path}")
	strv_set(args, 3, c"tests/ptx_kernel_probe.w")
	strv_set(args, 4, c"-o")
	strv_set(args, 5, out_path)
	process_result* result = process_run(args[0], args, 0, 0, 90000)
	free(cast(void*, args))
	assert1(result != 0)
	assert_equal(0, result.status)
	char* dump = file_read_text(dump_path)
	assert1(dump != 0)
	# The kernels are all present in one embedded module.
	assert_equal(1, ptx_has(dump, c".visible .entry ptx_arith("))
	assert_equal(1, ptx_has(dump, c".visible .entry ptx_slots("))
	assert_equal(1, ptx_has(dump, c".visible .entry ptx_unsigned("))
	assert_equal(1, ptx_has(dump, c".visible .entry ptx_float("))
	assert_equal(1, ptx_has(dump, c".visible .entry ptx_arrays("))
	assert_equal(1, ptx_has(dump, c".visible .entry ptx_deep("))
	assert_equal(1, ptx_has(dump, c".visible .entry ptx_copy("))
	assert_equal(1, ptx_has(dump, c".visible .entry ptx_for("))
	assert_equal(1, ptx_has(dump, c".visible .entry ptx_wide("))
	# Stack-machine shapes: struct-field pushes, %bx spills and reloads,
	# bx->ax moves, and the bx-restore pop.
	assert_equal(1, ptx_has(dump, c"ld.u64 %cx, [%ax+"))
	assert_equal(1, ptx_has(dump, c"ld.u64 %bx, [%sp+"))
	assert_equal(1, ptx_has(dump, c"mov.b64 %ax, %bx;"))
	assert_equal(1, ptx_has(dump, c"ld.u64 %bx, [%bx];"))
	assert_equal(1, ptx_has(dump, c"add.s64 %bx, %bx, "))
	# 32-bit staging: float32 negation flips the sign bit through %w0.
	assert_equal(1, ptx_has(dump, c"xor.b32"))
	assert_equal(1, ptx_has(dump, c"cvt.u32.u64 %w0, %ax;"))
	# Shifts take the count through the .u32 staging register.
	assert_equal(1, ptx_has(dump, c"shl.u64 %ax, %cx, %w0;"))
	assert_equal(1, ptx_has(dump, c"shr.u64 %ax, %cx, %w0;"))
	# Unsigned compares type .u64; signed ones .s64.
	assert_equal(1, ptx_has(dump, c"setp.lt.u64 %p, %bx, %ax;"))
	assert_equal(1, ptx_has(dump, c"setp.lt.s64 %p, %bx, %ax;"))
	# float32 -> float64 promotion and both truncate directions.
	assert_equal(1, ptx_has(dump, c"cvt.f64.f32 %da, %fa;"))
	assert_equal(1, ptx_has(dump, c"cvt.f64.f32 %db, %fb;"))
	assert_equal(1, ptx_has(dump, c"cvt.rzi.s64.f32 %ax, %fa;"))
	assert_equal(1, ptx_has(dump, c"cvt.rzi.s64.f64 %ax, %da;"))
	# int -> float conversions from the left-hand register.
	assert_equal(1, ptx_has(dump, c"cvt.rn.f32.s64 %fa, %bx;"))
	assert_equal(1, ptx_has(dump, c"cvt.rn.f64.s64 %db, %bx;"))
	# float64 negation flips bit 63; the ternary select materializes.
	assert_equal(1, ptx_has(dump, c"xor.b64 %ax, %ax, 0x8000000000000000;"))
	assert_equal(1, ptx_has(dump, c"selp.b64 %ax, 1, 0, %p;"))
	# The `debugger;` statement is the device trap.
	assert_equal(1, ptx_has(dump, c"trap;"))
	free(dump)
	unlink(dump_path)
	unlink(out_path)
	process_result_free(result)

