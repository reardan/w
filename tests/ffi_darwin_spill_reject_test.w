# The still-rejected arm64_darwin extern overflow shape: two or more
# stack spills need per-argument natural sizes the FFI classifier does
# not carry (code_generator/ffi.w, emit_c_abi_call_arm64), so only a
# single integer-class spill is allowed beyond the 8 integer + 8 float
# register arguments. This 10-integer-argument extern (two spills) must
# keep failing with the frozen message; the allowed single-spill case
# is compile-covered by graphics_darwin building
# graphics/gl_texture_test.w (glTexImage2D, 9 arguments).
# wbuild: name=ffi_darwin_spill_reject_test arch_only=arm64_darwin compile_fail
# wbuild: expect_stderr="arm64_darwin extern calls support at most 8 integer and 8 float arguments"

c_lib "/usr/lib/libSystem.B.dylib"

extern int darwin_ten_int_args(int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8, int a9, int a10)


int main():
	return darwin_ten_int_args(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
