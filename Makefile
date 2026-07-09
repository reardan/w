

# The seed stage stays flagless (the committed seed may predate --strict);
# the self-host stages compile with warnings as errors so unsafe type
# mismatches fail the build.
build: w
	mkdir -p bin
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2
	./bin/wv2 --strict w.w -o ./bin/wv3
	./bin/wv3 --strict w.w -o ./bin/wv4
	./bin/wv4 --strict w.w -o ./bin/wv5

# Self-host fixpoint check: wv3, wv4 and wv5 must be byte-identical.
# This is the cheapest regression guard for a bootstrapped compiler; run it
# before 'make update' promotes a new seed.
verify: build
	cmp ./bin/wv3 ./bin/wv4
	cmp ./bin/wv4 ./bin/wv5
	@echo "self-host fixpoint OK: wv3 == wv4 == wv5"

update: verify
	./archive.sh
	mv -f ./bin/wv2 ./w

# --- native macOS bootstrap (Apple Silicon; run these on a Mac) ---
# ./w_darwin is the committed arm64_darwin seed, ad-hoc signed so a fresh
# checkout runs it directly. Each stage's output is signed on a copy that
# is renamed over the original (the kernel caches signature state per
# vnode, so an executed inode must be replaced, never rewritten); the
# _raw files stay unsigned for the byte-identical fixpoint compare.
build_darwin: w_darwin FORCE
	mkdir -p bin
	./w_darwin arm64_darwin w.w -o ./bin/wv2_darwin_raw
	cp ./bin/wv2_darwin_raw ./bin/wv2_darwin.signing
	codesign -f -s - ./bin/wv2_darwin.signing
	mv -f ./bin/wv2_darwin.signing ./bin/wv2_darwin
	./bin/wv2_darwin arm64_darwin w.w -o ./bin/wv3_darwin_raw
	cp ./bin/wv3_darwin_raw ./bin/wv3_darwin.signing
	codesign -f -s - ./bin/wv3_darwin.signing
	mv -f ./bin/wv3_darwin.signing ./bin/wv3_darwin
	./bin/wv3_darwin arm64_darwin w.w -o ./bin/wv4_darwin_raw

verify_darwin: build_darwin
	cmp ./bin/wv3_darwin_raw ./bin/wv4_darwin_raw
	@echo "darwin self-host fixpoint OK: wv3_darwin == wv4_darwin"

update_darwin: verify_darwin
	mkdir -p old
	cp ./w_darwin ./old/w_darwin_`date '+%d_%m_%y_%H_%M_%S'` 2>/dev/null || true
	cp -f ./bin/wv3_darwin ./w_darwin

test: w FORCE
	./bin/wv2 tests/test.w >./bin/test
	chmod +x ./bin/test
	./bin/test

test_debug: w FORCE
	./bin/wv2 test.w >./bin/test
	chmod +x ./bin/test
	ddd ./bin/test

testing_ground: w FORCE
	./bin/wv2 tests/testing_ground.w >./bin/testing_ground
	chmod +x ./bin/testing_ground
	./bin/testing_ground arg1 arg2 arg3 -o output -i=input --input=doubledash

asm_test: w FORCE
	./bin/wv2 tests/asm_test.w >./bin/asm_test
	chmod +x ./bin/asm_test
	./bin/asm_test

net_basic: w FORCE
	./bin/wv2 tests/net_basic.w >./bin/net_basic
	chmod +x ./bin/net_basic
	./bin/net_basic

net: w FORCE
	./bin/wv2 tests/net.w >./bin/net
	chmod +x ./bin/net
	./bin/net

net_test: w FORCE
	./bin/wv2 lib/net_test.w -o ./bin/net_test
	./bin/net_test

poll_test: w FORCE
	./bin/wv2 lib/poll_test.w -o ./bin/poll_test
	./bin/poll_test

framing_test: w FORCE
	./bin/wv2 lib/framing_test.w -o ./bin/framing_test
	./bin/framing_test

event_loop_test: w FORCE
	./bin/wv2 lib/event_loop_test.w -o ./bin/event_loop_test
	./bin/event_loop_test

event_loop_64_test: w FORCE
	./bin/wv2 x64 lib/event_loop_test.w -o ./bin/event_loop_64_test
	./bin/event_loop_64_test

task_test: w FORCE
	./bin/wv2 lib/task_test.w -o ./bin/task_test
	./bin/task_test

task_64_test: w FORCE
	./bin/wv2 x64 lib/task_test.w -o ./bin/task_64_test
	./bin/task_64_test

task_io_test: w FORCE
	./bin/wv2 lib/task_io_test.w -o ./bin/task_io_test
	./bin/task_io_test
	./bin/wv2 examples/web/task_echo_server.w -o ./bin/task_echo_server
	./bin/task_echo_server

task_io_64_test: w FORCE
	./bin/wv2 x64 lib/task_io_test.w -o ./bin/task_io_64_test
	./bin/task_io_64_test
	./bin/wv2 x64 examples/web/task_echo_server.w -o ./bin/task_echo_server_64
	./bin/task_echo_server_64

json_rpc_test: w FORCE
	./bin/wv2 lib/json_rpc_test.w -o ./bin/json_rpc_test
	./bin/json_rpc_test
	./bin/wv2 examples/web/json_rpc_server.w -o ./bin/json_rpc_server

json_rpc_64_test: w FORCE
	./bin/wv2 x64 lib/json_rpc_test.w -o ./bin/json_rpc_64_test
	./bin/json_rpc_64_test
	./bin/wv2 x64 examples/web/json_rpc_server.w -o ./bin/json_rpc_server_64

pointer_test: w FORCE
	./bin/wv2 tests/pointer_test.w >./bin/pointer_test
	chmod +x ./bin/pointer_test
	./bin/pointer_test

hello: w FORCE
	./bin/wv2 tests/hello.w >./bin/hello
	chmod +x ./bin/hello
	./bin/hello

# Imports plus the 'import x as alias' form: the test binary covers the
# happy paths, the fixtures assert the alias diagnostics.
import_test: w FORCE
	./bin/wv2 tests/import_test.w >./bin/import_test
	chmod +x ./bin/import_test
	./bin/import_test
	! ./bin/wv2 tests/import_alias_wrong_module_error_fixture.w -o ./bin/import_alias_wrong_module_error_fixture 2>./bin/import_alias_wrong_module_error_fixture.stderr
	grep -qF "symbol 'local_helper' is not defined in module imported as 'sub'" ./bin/import_alias_wrong_module_error_fixture.stderr
	! ./bin/wv2 tests/import_alias_duplicate_error_fixture.w -o ./bin/import_alias_duplicate_error_fixture 2>./bin/import_alias_duplicate_error_fixture.stderr
	grep -qF "duplicate import alias: 'sub'" ./bin/import_alias_duplicate_error_fixture.stderr
	@echo "import test OK"

c_import_test: w FORCE
	./bin/wv2 tests/c_import_test.w >./bin/c_import_test
	chmod +x ./bin/c_import_test
	./bin/c_import_test

c_preprocessor_test: w FORCE
	./bin/wv2 tests/c_preprocessor_test.w -o ./bin/c_preprocessor_test
	./bin/c_preprocessor_test

c_import_errno_test: w FORCE
	./bin/wv2 tests/c_import_errno_test.w >./bin/c_import_errno_test
	chmod +x ./bin/c_import_errno_test
	./bin/c_import_errno_test

# Broad libc headers imported together: exercises the preprocessor, the C
# parser, the importer and cross-header symbol collision handling.
c_import_libc_test: w FORCE
	./bin/wv2 tests/c_import_libc_test.w -o ./bin/c_import_libc_test
	./bin/c_import_libc_test

c_import_libc_test_x64: w FORCE
	./bin/wv2 x64 tests/c_import_libc_test.w -o ./bin/c_import_libc_test_x64
	./bin/c_import_libc_test_x64


directory_test: w FORCE
	./bin/wv2 tests/directory_test.w >./bin/directory_test
	chmod +x ./bin/directory_test
	./bin/directory_test

net_log_socket: FORCE
	sudo stap -e 'probe syscall.socket { printf("%s[%d] -> %s(%s)\n", execname(), pid(), name, argstr) }'

net_log: FORCE
	sudo stap -e 'probe syscall.sendto { printf("%s[%d] -> %s(%s)\n", execname(), pid(), name, argstr) }'

log_write: FORCE
	sudo stap -e 'probe syscall.write { printf("%s[%d] -> %s(%s)\n", execname(), pid(), name, argstr) }'

net_debug: w FORCE
	./bin/wv2 net.w >./bin/net
	chmod +x ./bin/net
	ddd ./bin/net

simple: w FORCE
	./bin/wv2 tests/simple.w >./bin/simple
	chmod +x ./bin/simple
	./bin/simple

simple_debug: w FORCE
	./bin/wv2 tests/simple.w >./bin/simple
	chmod +x ./bin/simple
	ddd ./bin/simple

x64_test: w FORCE
	./bin/wv2 x64 tests/x64_test.w >./bin/x64_test
	chmod +x ./bin/x64_test
	./bin/x64_test

x64_float_test: w FORCE
	./bin/wv2 x64 tests/x64_float_test.w >./bin/x64_float_test
	chmod +x ./bin/x64_float_test
	./bin/x64_float_test | grep -q "x64 float OK"
	@echo "x64 float test OK"

x64_int64_test: w FORCE
	./bin/wv2 x64 tests/x64_int64_test.w >./bin/x64_int64_test
	chmod +x ./bin/x64_int64_test
	./bin/x64_int64_test | grep -q "x64 int64 OK"
	@echo "x64 int64 test OK"

int64_x86_error_test: w FORCE
	! ./bin/wv2 tests/x64_int64_test.w -o ./bin/int64_x86_error_test 2>./bin/int64_x86_error_test.stderr
	grep -qF "int64 requires the x64 target" ./bin/int64_x86_error_test.stderr
	@echo "int64 x86 error test OK"

build_x64: w FORCE
	./bin/wv2 x64 w.w -o ./bin/wv2_64
	./bin/wv2_64 x64 w.w -o ./bin/wv3_64
	./bin/wv3_64 x64 w.w -o ./bin/wv4_64

# x64 self-host fixpoint check, mirroring 'verify'. wv2_64 is built by the
# x86-hosted compiler, so the first cmp also proves the output does not
# depend on the host word size.
verify_x64: build_x64
	cmp ./bin/wv2_64 ./bin/wv3_64
	cmp ./bin/wv3_64 ./bin/wv4_64
	@echo "x64 self-host fixpoint OK: wv2_64 == wv3_64 == wv4_64"

# AArch64 (arm64) target. The x86-hosted compiler cross-compiles w.w to a
# 64-bit arm64 ELF (wv2_arm64); running that under qemu recompiles w.w and
# the result must be byte-identical (self-host fixpoint), the arm64 analog
# of verify_x64. Requires qemu-user (qemu-aarch64-static); -cpu max provides
# the FEAT_PAuth/PAuth2/FPAC pointer-authentication the M3 has, so the
# pac=ret return-address signing is actually enforced. See docs/projects/arm64.md.
QEMU_ARM64 ?= qemu-aarch64-static -cpu max

build_arm64: w FORCE
	./bin/wv2 arm64 w.w -o ./bin/wv2_arm64
	$(QEMU_ARM64) ./bin/wv2_arm64 arm64 w.w -o ./bin/wv3_arm64

verify_arm64: build_arm64
	cmp ./bin/wv2_arm64 ./bin/wv3_arm64
	@echo "arm64 self-host fixpoint OK: wv2_arm64 == wv3_arm64"

# A representative slice of the suite compiled to arm64 and run under qemu.
# Not part of the default 'tests' aggregate because it needs qemu-user.
arm64_smoke_test: w FORCE
	./bin/wv2 arm64 lib/lib_test.w -o ./bin/lib_arm64_test
	$(QEMU_ARM64) ./bin/lib_arm64_test
	./bin/wv2 arm64 structures/hash_table_test.w -o ./bin/hash_table_arm64_test
	$(QEMU_ARM64) ./bin/hash_table_arm64_test
	./bin/wv2 arm64 tests/map_set_builtin_test.w -o ./bin/map_set_builtin_arm64_test
	$(QEMU_ARM64) ./bin/map_set_builtin_arm64_test
	./bin/wv2 arm64 tests/generator_test.w -o ./bin/generator_arm64_test
	$(QEMU_ARM64) ./bin/generator_arm64_test
	@echo "arm64 smoke test OK"

# Stage 5 pointer authentication (docs/projects/arm64.md D6).
# pac_flag_test only inspects the emitted bytes (no emulator), so it is
# part of the default 'tests' aggregate; the runtime tests below need
# qemu-user and stay out, like arm64_smoke_test.
pac_flag_test: w FORCE
	sh tools/pac_flag_check.sh ./bin/wv2

# Cross-compile the PAC fixtures as arm64e Mach-O (compile-only guard,
# like graphics_darwin); tools/mac/run_darwin_tests.sh signs and runs
# them natively on a Mac, where the corruption fixtures must die.
pac_darwin: w FORCE
	./bin/wv2 arm64_darwin --pac=full tests/pac_full_test.w -o ./bin/pac_full_darwin_test
	./bin/wv2 arm64_darwin --pac=full tests/pac_corrupt_fnptr_test.w -o ./bin/pac_corrupt_fnptr_darwin_test
	./bin/wv2 arm64_darwin --pac=full tests/pac_corrupt_ret_test.w -o ./bin/pac_corrupt_ret_darwin_test

pac_full_test_arm64: w FORCE
	./bin/wv2 arm64 --pac=full tests/pac_full_test.w -o ./bin/pac_full_arm64_test
	$(QEMU_ARM64) ./bin/pac_full_arm64_test | grep -q "pac full OK"
	@echo "pac full arm64 test OK"

# The corruption fixtures MUST die at the authenticating instruction:
# qemu -cpu max (FEAT_FPAC) delivers SIGILL (exit 132); macOS reports
# SIGSEGV/SIGBUS for the same faults. Assert death by signal (>= 128)
# and that the post-corruption print was never reached.
pac_corrupt_test_arm64: w FORCE
	./bin/wv2 arm64 --pac=full tests/pac_corrupt_fnptr_test.w -o ./bin/pac_corrupt_fnptr_arm64_test
	rc=0; $(QEMU_ARM64) ./bin/pac_corrupt_fnptr_arm64_test > ./bin/pac_corrupt_fnptr.out || rc=$$?; test $$rc -ge 128
	! grep -q "NOT REACHED" ./bin/pac_corrupt_fnptr.out
	./bin/wv2 arm64 tests/pac_corrupt_ret_test.w -o ./bin/pac_corrupt_ret_arm64_test
	rc=0; $(QEMU_ARM64) ./bin/pac_corrupt_ret_arm64_test > ./bin/pac_corrupt_ret.out || rc=$$?; test $$rc -ge 128
	! grep -q "NOT REACHED" ./bin/pac_corrupt_ret.out
	@echo "pac corruption tests OK (both fixtures died)"

# graphics.math is pure W (no libm), so it runs on both targets.
graphics_math_test: w FORCE
	./bin/wv2 graphics/math_test.w -o ./bin/graphics_math_test
	./bin/graphics_math_test

graphics_math_64_test: w FORCE
	./bin/wv2 x64 graphics/math_test.w -o ./bin/graphics_math_64_test
	./bin/graphics_math_64_test

# Renders a triangle through GLX with string shaders and verifies the
# pixels via glReadPixels. Prints "graphics gl smoke SKIP" and passes on
# headless hosts (no X display), like cuda_smoke does for missing GPUs.
graphics_gl_smoke_test: w FORCE
	./bin/wv2 x64 graphics/gl_smoke_test.w -o ./bin/graphics_gl_smoke_test
	./bin/graphics_gl_smoke_test | grep -q "graphics gl smoke"
	@echo "graphics gl smoke test OK"

# Interactive spinning-triangle demo window (close it to exit; needs X).
graphics_demo: w FORCE
	./bin/wv2 x64 graphics/demo.w -o ./bin/graphics_demo
	./bin/graphics_demo

# Compile-only guard for the macOS backend: cross-compiles the darwin
# binaries so Linux CI catches breakage; running them is Mac-side
# (tools/mac/run_darwin_tests.sh — needs codesign and a GUI session).
graphics_darwin: w FORCE
	./bin/wv2 arm64_darwin tests/dynamic_darwin_test.w -o ./bin/dynamic_darwin_test
	./bin/wv2 arm64_darwin graphics/gl_smoke_test.w -o ./bin/graphics_gl_smoke_darwin
	./bin/wv2 arm64_darwin graphics/demo.w -o ./bin/graphics_demo_darwin
	@echo "graphics darwin cross-compile OK"

# Windows x64 (win64) target: cross-compiles to a PE32+ console .exe.
# See docs/projects/windows.md. The runtime tests need Wine; they are not
# part of the default 'tests' aggregate for that reason. win64_header_test
# only inspects the produced file, so it runs anywhere binutils exists.
WINE ?= wine

win64_header_test: w FORCE
	./bin/wv2 win64 tests/win64_hello.w -o ./bin/win64_hello.exe
	objdump -f ./bin/win64_hello.exe | grep -q "pei-x86-64"
	objdump -p ./bin/win64_hello.exe | grep -q "ExitProcess"
	objdump -p ./bin/win64_hello.exe | grep -q "kernel32.dll"
	@echo "win64 header test OK"

win64_hello_test: w FORCE
	./bin/wv2 win64 tests/win64_hello.w -o ./bin/win64_hello.exe
	WINEDEBUG=-all $(WINE) ./bin/win64_hello.exe | grep -q "hello from win64"
	@echo "win64 hello test OK"

win64_smoke_test: w FORCE
	./bin/wv2 win64 tests/win64_smoke.w -o ./bin/win64_smoke.exe
	WINEDEBUG=-all $(WINE) ./bin/win64_smoke.exe | grep -q "win64 smoke OK"
	@echo "win64 smoke test OK"

# Windows twin of dynamic_test: extern/c_lib against msvcrt.dll through
# the PE import table and the Win64 ABI shims.
dynamic_test_win64: w FORCE
	./bin/wv2 win64 tests/dynamic_test_win64.w -o ./bin/dynamic_test_win64.exe
	WINEDEBUG=-all $(WINE) ./bin/dynamic_test_win64.exe | grep -q "dynamic linking OK"
	@echo "dynamic test win64 OK"

tests_win64: win64_header_test win64_hello_test win64_smoke_test dynamic_test_win64 FORCE

tests_x64: verify_x64 lib_64_test path_64_test time_64_test result_64_test result_propagate_64_test env_64_test process_64_test stream_64_test array_slice_string_64_test x64_test x64_float_test x64_int64_test net_64_test poll_64_test framing_64_test dynamic_test_x64 extern_alias_test_x64 c_import_libc_test_x64 float_abi_test_x64 varargs_test_x64 extern_data_test_x64 defer_64_test default_args_64_test varargs_w_64_test list_64_test array_list_64_test linked_list_64_test hash_map_64_test hash_table_64_test string_64_test map_set_builtin_64_test list_builtin_64_test switch_64_test for_container_64_test compound_assign_64_test template_string_64_test generator_64_test feature_interaction_64_test feature_combo_64_test dynamic_var_64_test generics_64_test generics_inference_64_test json_64_test json_codec_64_test json_rpc_64_test event_loop_64_test task_64_test task_io_64_test format_64_test args_64_test graphics_math_64_test graphics_gl_smoke_test repl_test_x64 debug_test_x64 FORCE

# Dynamic linking: call libc through extern declarations and check the
# result against the raw syscall. dynamic_test links the 32-bit libc,
# dynamic_test_x64 the 64-bit libc.
dynamic_test: w FORCE
	./bin/wv2 tests/dynamic_test.w >./bin/dynamic_test
	chmod +x ./bin/dynamic_test
	./bin/dynamic_test | grep -q "dynamic linking OK"
	@echo "dynamic test OK"

dynamic_test_x64: w FORCE
	./bin/wv2 x64 tests/dynamic_test.w >./bin/dynamic_test_x64
	chmod +x ./bin/dynamic_test_x64
	./bin/dynamic_test_x64 | grep -q "dynamic linking OK"
	@echo "dynamic test x64 OK"

# Same check compiled to arm64 (AAPCS64 shims + aarch64 .interp): runs
# natively on aarch64 hosts (pass QEMU_ARM64= in the w-dev container).
# Under qemu it needs the aarch64 libc sysroot (qemu-aarch64-static
# -L /usr/aarch64-linux-gnu), like dynamic_test needs libc6:i386.
dynamic_test_arm64: w FORCE
	./bin/wv2 arm64 tests/dynamic_test.w -o ./bin/dynamic_test_arm64
	$(QEMU_ARM64) ./bin/dynamic_test_arm64 | grep -q "dynamic linking OK"
	@echo "dynamic test arm64 OK"

# extern alias ('= "symbol"'): a library symbol bound under a different
# W name, once per call signature.
extern_alias_test_x64: w FORCE
	./bin/wv2 x64 tests/extern_alias_test.w -o ./bin/extern_alias_test_x64
	./bin/extern_alias_test_x64 | grep -q "extern alias OK"
	@echo "extern alias test x64 OK"

# Imported data objects (extern declarations without a parameter list):
# stdout/stderr/optind arrive via COPY relocations.
extern_data_test: w FORCE
	./bin/wv2 tests/extern_data_test.w -o ./bin/extern_data_test
	./bin/extern_data_test | grep -q "extern data stdout write"
	./bin/extern_data_test | grep -q "extern data OK"
	./bin/extern_data_test 2>&1 >/dev/null | grep -q "extern data stderr 42 formatted"
	@echo "extern data test OK"

extern_data_test_x64: w FORCE
	./bin/wv2 x64 tests/extern_data_test.w -o ./bin/extern_data_test_x64
	./bin/extern_data_test_x64 | grep -q "extern data stdout write"
	./bin/extern_data_test_x64 | grep -q "extern data OK"
	./bin/extern_data_test_x64 2>&1 >/dev/null | grep -q "extern data stderr 42 formatted"
	@echo "extern data test x64 OK"

# Variadic C imports (extern ... declarations): integer, string and
# promoted-float arguments through printf-family functions.
varargs_test: w FORCE
	./bin/wv2 tests/varargs_test.w -o ./bin/varargs_test
	./bin/varargs_test | grep -q "printf: 7 seven 7.25"
	./bin/varargs_test | grep -q "varargs OK"
	@echo "varargs test OK"

varargs_test_x64: w FORCE
	./bin/wv2 x64 tests/varargs_test.w -o ./bin/varargs_test_x64
	./bin/varargs_test_x64 | grep -q "printf: 7 seven 7.25"
	./bin/varargs_test_x64 | grep -q "varargs OK"
	@echo "varargs test x64 OK"

# Floating-point C ABI through the FFI shims: float32 on both targets,
# float64 (xmm argument/return passing) on x64 only.
float_abi_test: w FORCE
	./bin/wv2 tests/float_abi_test.w -o ./bin/float_abi_test
	./bin/float_abi_test | grep -q "float abi OK"
	@echo "float abi test OK"

float_abi_test_x64: w FORCE
	./bin/wv2 x64 tests/float_abi_test.w -o ./bin/float_abi_test_x64
	./bin/float_abi_test_x64 | grep -q "float abi OK"
	./bin/wv2 x64 tests/x64_float_abi_test.w -o ./bin/x64_float_abi_test
	./bin/x64_float_abi_test | grep -q "x64 float abi OK"
	./bin/wv2 x64 tests/x64_c_import_float_test.w -o ./bin/x64_c_import_float_test
	./bin/x64_c_import_float_test | grep -q "x64 c_import float OK"
	@echo "float abi test x64 OK"

# Float args/returns through the AAPCS64 shims (see dynamic_test_arm64
# for the qemu sysroot note).
float_abi_test_arm64: w FORCE
	./bin/wv2 arm64 tests/float_abi_test.w -o ./bin/float_abi_test_arm64
	$(QEMU_ARM64) ./bin/float_abi_test_arm64 | grep -q "float abi OK"
	@echo "float abi test arm64 OK"

# JIT-load a hand-written PTX kernel through libcuda and run vector add on
# the GPU. Requires an NVIDIA driver + GPU, so it is not part of 'tests'.
cuda_smoke: w FORCE
	./bin/wv2 x64 tests/cuda_smoke.w >./bin/cuda_smoke
	chmod +x ./bin/cuda_smoke
	./bin/cuda_smoke | grep -q "cuda vector add OK"
	@echo "cuda smoke OK"

x64_test_debug: w FORCE
	./bin/wv2 x64 tests/x64_test.w >./bin/x64_test
	chmod +x ./bin/x64_test
	ddd ./bin/x64_test

elf: w FORCE
	./bin/wv2 tests/elf.w >./bin/elf
	chmod +x ./bin/elf
	./bin/elf

convert: w FORCE
	./bin/wv2 debugger/convert.w >./bin/convert
	chmod +x ./bin/convert
	# objdump -d ~/git/net/tcp | ./bin/convert

struct_test: w FORCE
	./bin/wv2 tests/struct_test.w >./bin/struct_test
	chmod +x ./bin/struct_test
	./bin/struct_test

struct_method_test: w FORCE
	./bin/wv2 tests/struct_method_test.w >./bin/struct_method_test
	chmod +x ./bin/struct_method_test
	./bin/struct_method_test

struct_test_debug: w FORCE
	./bin/wv2 tests/struct_test.w >./bin/struct_test
	chmod +x ./bin/struct_test
	ddd ./bin/struct_test

range_test: w FORCE
	./bin/wv2 tests/range_test.w >./bin/range_test
	chmod +x ./bin/range_test
	./bin/range_test

type_system_p0_test: w FORCE
	./bin/wv2 tests/type_system_p0_test.w >./bin/type_system_p0_test
	chmod +x ./bin/type_system_p0_test
	./bin/type_system_p0_test

type_system_error_test: w FORCE
	! ./bin/wv2 tests/type_system_error_fixture.w -o ./bin/type_system_error_fixture 2>./bin/type_system_error_fixture.stderr
	grep -qF "assignment to const" ./bin/type_system_error_fixture.stderr
	! ./bin/wv2 tests/type_system_const_pointer_error_fixture.w -o ./bin/type_system_const_pointer_error_fixture 2>./bin/type_system_const_pointer_error_fixture.stderr
	grep -qF "assignment to const" ./bin/type_system_const_pointer_error_fixture.stderr
	! ./bin/wv2 tests/type_system_cast_error_fixture.w -o ./bin/type_system_cast_error_fixture 2>./bin/type_system_cast_error_fixture.stderr
	grep -qF "cannot cast an address to a sub-word integer" ./bin/type_system_cast_error_fixture.stderr
	! ./bin/wv2 tests/type_system_function_cast_error_fixture.w -o ./bin/type_system_function_cast_error_fixture 2>./bin/type_system_function_cast_error_fixture.stderr
	grep -qF "cannot cast an address to a sub-word integer" ./bin/type_system_function_cast_error_fixture.stderr
	@echo "type system error test OK"

type_system_warning_test: w FORCE
	./bin/wv2 tests/type_system_warning_fixture.w -o ./bin/type_system_warning_fixture 2>./bin/type_system_warning_fixture.stderr
	grep -qF "warning: initialization type mismatch: expected 'binary_op_warning*', got 'function'" ./bin/type_system_warning_fixture.stderr
	grep -qF "warning: assignment type mismatch: expected 'binary_op_warning*', got 'function'" ./bin/type_system_warning_fixture.stderr
	@echo "type system warning test OK"

range_test_debug: w FORCE
	./bin/wv2 tests/range_test.w >./bin/range_test
	chmod +x ./bin/range_test
	ddd ./bin/range_test

# Compile-only fixtures asserting the compiler's type mismatch warnings.
# warning_fixture.w must produce each expected message; the clean fixture
# must compile silently.
warning_test: w FORCE
	./bin/wv2 tests/warning_fixture.w -o ./bin/warning_fixture 2>./bin/warning_fixture.stderr
	grep -qF "warning: assignment type mismatch: expected 'char*', got 'int*'" ./bin/warning_fixture.stderr
	grep -qF "warning: assignment type mismatch: expected 'char*', got 'char**'" ./bin/warning_fixture.stderr
	grep -qF "warning: initialization type mismatch: expected 'int*', got 'char*'" ./bin/warning_fixture.stderr
	grep -qF "warning: function 'takes_char_ptr' argument 1 type mismatch: expected 'char*', got 'int*'" ./bin/warning_fixture.stderr
	grep -qF "warning: return type mismatch: expected 'char*', got 'int*'" ./bin/warning_fixture.stderr
	grep -qF "warning: assignment type mismatch: expected 'pair', got 'single'" ./bin/warning_fixture.stderr
	grep -qF "warning: assignment type mismatch: expected 'char*', got 'int'" ./bin/warning_fixture.stderr
	grep -qF "warning: assignment type mismatch: expected 'int', got 'char*'" ./bin/warning_fixture.stderr
	grep -qF "warning: function 'takes_char_ptr' argument 1 type mismatch: expected 'char*', got 'int'" ./bin/warning_fixture.stderr
	grep -qF "warning: return type mismatch: expected 'char*', got 'int'" ./bin/warning_fixture.stderr
	grep -qF "warning: initialization type mismatch: expected 'char*', got 'function'" ./bin/warning_fixture.stderr
	grep -qF "warning: assignment type mismatch: expected 'int', got 'function'" ./bin/warning_fixture.stderr
	grep -qF "warning: line indented with spaces instead of tabs" ./bin/warning_fixture.stderr
	grep -qF "warning: file does not end with a newline" ./bin/warning_fixture.stderr
	./bin/wv2 tests/warning_clean_fixture.w -o ./bin/warning_clean_fixture 2>./bin/warning_clean_fixture.stderr
	! grep -q "warning:" ./bin/warning_clean_fixture.stderr
	./bin/wv2 tests/import_alias_warning_fixture.w -o ./bin/import_alias_warning_fixture 2>./bin/import_alias_warning_fixture.stderr
	grep -qF "warning: unqualified use of 'subfolder_value' from module imported as 'sub'" ./bin/import_alias_warning_fixture.stderr
	./bin/wv2 tests/string_char_warning_fixture.w -o ./bin/string_char_warning_fixture 2>./bin/string_char_warning_fixture.stderr
	grep -qF "warning: return type mismatch: expected 'char*', got 'string value'" ./bin/string_char_warning_fixture.stderr
	grep -qF "warning: initialization type mismatch: expected 'char*', got 'string value'" ./bin/string_char_warning_fixture.stderr
	grep -qF "warning: function 'takes_char_ptr' argument 1 type mismatch: expected 'char*', got 'string value'" ./bin/string_char_warning_fixture.stderr
	grep -qF "warning: assignment type mismatch: expected 'char*', got 'string value'" ./bin/string_char_warning_fixture.stderr
	@echo "warning test OK"

# --strict promotes warnings to a failing exit: the warning fixture must
# fail without leaving an output binary, the clean fixture must still
# compile silently, and check mode must propagate the failure.
strict_mode_test: w FORCE
	rm -f ./bin/strict_mode_fixture
	! ./bin/wv2 --strict tests/warning_fixture.w -o ./bin/strict_mode_fixture 2>./bin/strict_mode_fixture.stderr
	grep -qF "warning: assignment type mismatch: expected 'char*', got 'int*'" ./bin/strict_mode_fixture.stderr
	grep -qF "warning(s) treated as errors (--strict)" ./bin/strict_mode_fixture.stderr
	test ! -e ./bin/strict_mode_fixture
	./bin/wv2 --strict tests/warning_clean_fixture.w -o ./bin/strict_mode_clean 2>./bin/strict_mode_clean.stderr
	! grep -q "warning:" ./bin/strict_mode_clean.stderr
	! ./bin/wv2 check --strict tests/warning_fixture.w 2>./bin/strict_mode_check.stderr
	grep -qF "warning(s) treated as errors (--strict)" ./bin/strict_mode_check.stderr
	./bin/wv2 check --strict tests/warning_clean_fixture.w 2>./bin/strict_mode_check_clean.stderr
	@echo "strict mode test OK"

check_json_test: w FORCE
	./bin/wv2 check --json tests/warning_fixture.w >./bin/check_json_warning.ndjson 2>./bin/check_json_warning.stderr
	grep -qF '"severity": "warning"' ./bin/check_json_warning.ndjson
	grep -qF '"file": "$(CURDIR)/tests/warning_fixture.w"' ./bin/check_json_warning.ndjson
	grep -qE '"line": [1-9][0-9]*' ./bin/check_json_warning.ndjson
	grep -qE '"column": [1-9][0-9]*' ./bin/check_json_warning.ndjson
	grep -qF '"message": "assignment type mismatch: expected '\''char*'\'', got '\''int*'\''"' ./bin/check_json_warning.ndjson
	grep -qF '"token":' ./bin/check_json_warning.ndjson
	grep -qF '"arch": "x86"' ./bin/check_json_warning.ndjson
	! ./bin/wv2 check --json tests/type_system_error_fixture.w >./bin/check_json_error.ndjson 2>./bin/check_json_error.stderr
	grep -qF '"severity": "error"' ./bin/check_json_error.ndjson
	grep -qF '"message": "assignment to const"' ./bin/check_json_error.ndjson
	./bin/wv2 check --json tests/warning_clean_fixture.w >./bin/check_json_clean.ndjson 2>./bin/check_json_clean.stderr
	test ! -s ./bin/check_json_clean.ndjson
	./bin/wv2 check --json x64 tests/warning_fixture.w >./bin/check_json_warning_x64.ndjson 2>./bin/check_json_warning_x64.stderr
	grep -qF '"arch": "x64"' ./bin/check_json_warning_x64.ndjson
	@echo "check json test OK"

# Symbol/type declaration metadata dump for LSP/indexer tooling.
symbols_test: w FORCE
	./bin/wv2 symbols --json tests/symbols_fixture.w >./bin/symbols_fixture.ndjson 2>./bin/symbols_fixture.stderr
	grep -qF '"name": "sym_fixture_add", "kind": "function", "type": "int"' ./bin/symbols_fixture.ndjson
	grep -qF '"name": "sym_fixture_counter", "kind": "object", "type": "int"' ./bin/symbols_fixture.ndjson
	grep -qF '"name": "sym_fixture_point", "kind": "struct", "type": "sym_fixture_point"' ./bin/symbols_fixture.ndjson
	grep -qF '"name": "sym_fixture_size", "kind": "alias"' ./bin/symbols_fixture.ndjson
	grep -qF '"name": "sym_fixture_color", "kind": "enum"' ./bin/symbols_fixture.ndjson
	grep -qE '"name": "sym_fixture_add".*"file": "[^"]*tests/symbols_fixture.w", "line": 11, "column": 5' ./bin/symbols_fixture.ndjson
	grep -qE '"name": "sym_fixture_red".*"line": 18, "column": 2' ./bin/symbols_fixture.ndjson
	grep -qE '"name": "sym_fixture_green".*"line": 19, "column": 2' ./bin/symbols_fixture.ndjson
	grep -qF '"arch": "x86"' ./bin/symbols_fixture.ndjson
	./bin/wv2 symbols tests/symbols_fixture.w >./bin/symbols_fixture.txt 2>./bin/symbols_fixture_human.stderr
	grep -qE 'tests/symbols_fixture.w:11:5: function sym_fixture_add: int' ./bin/symbols_fixture.txt
	./bin/wv2 symbols --json x64 tests/symbols_fixture.w >./bin/symbols_fixture_x64.ndjson 2>./bin/symbols_fixture_x64.stderr
	grep -qF '"arch": "x64"' ./bin/symbols_fixture_x64.ndjson
	grep -qF '"name": "sym_fixture_add", "kind": "function", "type": "int"' ./bin/symbols_fixture_x64.ndjson
	@echo "symbols test OK"

# The compiler's own sources are the largest clean fixture: the strict
# type checks must not fire anywhere in the self-hosted compile.
self_host_warning_test: w FORCE
	./bin/wv2 w.w -o ./bin/self_host_warning_check 2>./bin/self_host_warning_check.stderr
	! grep -q "warning:" ./bin/self_host_warning_check.stderr
	./bin/wv2 x64 w.w -o ./bin/self_host_warning_check_64 2>./bin/self_host_warning_check_64.stderr
	! grep -q "warning:" ./bin/self_host_warning_check_64.stderr
	@echo "self host warning test OK"

type_table_test: w FORCE
	./bin/wv2 compiler/type_table_test.w >./bin/type_table_test
	chmod +x ./bin/type_table_test
	./bin/type_table_test

bignum_test: w FORCE
	./bin/wv2 compiler/bignum_test.w >./bin/bignum_test
	chmod +x ./bin/bignum_test
	./bin/bignum_test

float_literal_test: w FORCE
	./bin/wv2 tests/float_literal_test.w >./bin/float_literal_test
	chmod +x ./bin/float_literal_test
	./bin/float_literal_test

float_test: w FORCE
	./bin/wv2 tests/float_test.w >./bin/float_test
	chmod +x ./bin/float_test
	./bin/float_test

float_reference_test: w FORCE
	cc -std=c99 -O0 -fno-fast-math tests/float_reference.c -o ./bin/float_reference_c
	./bin/float_reference_c f32 >./bin/float_reference_c32.out
	./bin/wv2 tests/float_reference.w -o ./bin/float_reference_w32
	./bin/float_reference_w32 >./bin/float_reference_w32.out
	diff -u ./bin/float_reference_c32.out ./bin/float_reference_w32.out
	./bin/float_reference_c f64 >./bin/float_reference_c64.out
	./bin/wv2 x64 tests/x64_float_reference.w -o ./bin/float_reference_w64
	./bin/float_reference_w64 >./bin/float_reference_w64.out
	diff -u ./bin/float_reference_c64.out ./bin/float_reference_w64.out
	@echo "float reference test OK"

array_slice_string_test: w FORCE
	./bin/wv2 tests/array_slice_string_test.w -o ./bin/array_slice_string_test
	./bin/array_slice_string_test

array_slice_string_64_test: w FORCE
	./bin/wv2 x64 tests/array_slice_string_test.w -o ./bin/array_slice_string_64_test
	./bin/array_slice_string_64_test

string_utf8_test: w FORCE
	./bin/wv2 tests/string_utf8_test.w -o ./bin/string_utf8_test
	./bin/string_utf8_test
	! ./bin/wv2 tests/string_utf8_invalid_fixture.w -o ./bin/string_utf8_invalid_fixture 2>./bin/string_utf8_invalid_fixture.stderr
	grep -qF "invalid UTF-8 string literal" ./bin/string_utf8_invalid_fixture.stderr
	./bin/wv2 tests/string_utf8_invalid_cstr_fixture.w -o ./bin/string_utf8_invalid_cstr_fixture
	! ./bin/string_utf8_invalid_cstr_fixture 2>./bin/string_utf8_invalid_cstr_fixture.stderr
	grep -qF "invalid UTF-8 c string" ./bin/string_utf8_invalid_cstr_fixture.stderr
	./bin/wv2 tests/string_utf8_invalid_cstr_arg_fixture.w -o ./bin/string_utf8_invalid_cstr_arg_fixture
	! ./bin/string_utf8_invalid_cstr_arg_fixture 2>./bin/string_utf8_invalid_cstr_arg_fixture.stderr
	grep -qF "invalid UTF-8 c string" ./bin/string_utf8_invalid_cstr_arg_fixture.stderr
	@echo "string utf8 test OK"

grapheme_test: w FORCE
	./bin/wv2 tests/grapheme_test.w -o ./bin/grapheme_test
	./bin/grapheme_test

bounds_trap_test: w FORCE
	./bin/wv2 tests/bounds_trap_test.w -o ./bin/bounds_trap_test
	! ./bin/bounds_trap_test
	./bin/wv2 --bounds=off tests/bounds_trap_test.w -o ./bin/bounds_trap_test_off
	@echo "bounds trap test OK"

range_bounds_trap_test: w FORCE
	./bin/wv2 tests/range_bounds_trap_test.w -o ./bin/range_bounds_trap_test
	! ./bin/range_bounds_trap_test
	./bin/wv2 --bounds=off tests/range_bounds_trap_test.w -o ./bin/range_bounds_trap_test_off
	@echo "range bounds trap test OK"

buffer_field_assign_test: w FORCE
	! ./bin/wv2 tests/buffer_field_assign_test.w -o ./bin/buffer_field_assign_test 2>./bin/buffer_field_assign_test.stderr
	grep -qF "cannot assign to read-only buffer field" ./bin/buffer_field_assign_test.stderr
	@echo "buffer field assign test OK"

array_error_test: w FORCE
	! ./bin/wv2 tests/array_param_error_fixture.w -o ./bin/array_param_error_fixture 2>./bin/array_param_error_fixture.stderr
	grep -qF "fixed array parameter is not implemented; use T[] instead" ./bin/array_param_error_fixture.stderr
	! ./bin/wv2 tests/array_union_error_fixture.w -o ./bin/array_union_error_fixture 2>./bin/array_union_error_fixture.stderr
	grep -qF "fixed array fields are not implemented in unions" ./bin/array_union_error_fixture.stderr
	! ./bin/wv2 tests/array_constructor_error_fixture.w -o ./bin/array_constructor_error_fixture 2>./bin/array_constructor_error_fixture.stderr
	grep -qF "cannot initialize fixed-array field in constructor" ./bin/array_constructor_error_fixture.stderr
	@echo "array error test OK"

logging: w FORCE
	./bin/wv2 logging.w >./bin/logging
	chmod +x ./bin/logging
	./bin/logging

# Doesn't seem like these threading modules are in good shape:
threading: w FORCE
	./bin/wv2 tests/threading.w >./bin/threading
	chmod +x ./bin/threading
	./bin/threading

threading_test: w FORCE
	./bin/wv2 tests/threading_test.w >./bin/threading_test
	chmod +x ./bin/threading_test
	./bin/threading_test

threading_test_debug: w FORCE
	./bin/wv2 tests/threading_test.w >./bin/threading_test
	chmod +x ./bin/threading_test
	ddd ./bin/threading_test


whttp: w FORCE
	./bin/wv2 tests/whttp.w >./bin/whttp
	chmod +x ./bin/whttp
	./bin/whttp

tcp: w FORCE
	./bin/wv2 tests/tcp.w >./bin/tcp
	chmod +x ./bin/tcp
	./bin/tcp
#	ddd ./bin/tcp

grammar_test: w FORCE
	./bin/wv2 grammar/grammar_test.w >./bin/grammar_test
	chmod +x ./bin/grammar_test
	./bin/grammar_test
#	ddd ./bin/grammar_test

list_test: w FORCE
	./bin/wv2 structures/list_test.w >./bin/list_test
	chmod +x ./bin/list_test
	./bin/list_test

list_64_test: w FORCE
	./bin/wv2 x64 structures/list_test.w -o ./bin/list_64_test
	./bin/list_64_test

lib_test: w FORCE
	./bin/wv2 lib/lib_test.w >./bin/lib_test
	chmod +x ./bin/lib_test
	./bin/lib_test

lib_64_test: w FORCE
	./bin/wv2 x64 lib/lib_test.w >./bin/lib_test
	chmod +x ./bin/lib_test
	./bin/lib_test

path_64_test: w FORCE
	./bin/wv2 x64 lib/path_test.w -o ./bin/path_64_test
	./bin/path_64_test

time_64_test: w FORCE
	./bin/wv2 x64 lib/time_test.w -o ./bin/time_64_test
	./bin/time_64_test

net_64_test: w FORCE
	./bin/wv2 x64 lib/net_test.w -o ./bin/net_64_test
	./bin/net_64_test

poll_64_test: w FORCE
	./bin/wv2 x64 lib/poll_test.w -o ./bin/poll_64_test
	./bin/poll_64_test

framing_64_test: w FORCE
	./bin/wv2 x64 lib/framing_test.w -o ./bin/framing_64_test
	./bin/framing_64_test

lib_64_test_debug: w FORCE
	./bin/wv2 x64 lib/lib_test.w >./bin/lib_test
	chmod +x ./bin/lib_test
	ddd ./bin/lib_test

repl: w FORCE
	./bin/wv2 repl.w -o ./bin/repl
	./bin/repl

repl_x64: w FORCE
	./bin/wv2 x64 repl.w -o ./bin/repl64
	./bin/repl64

repl_test: w FORCE
	./bin/wv2 repl.w -o ./bin/repl
	printf 'print(c"hello from the repl\\x0a")\n:quit\n' | ./bin/repl | grep -q "hello from the repl"
	# A bad entry must not kill the process, and later entries must still work
	printf 'this is not valid w\nprint(c"recovered\\x0a")\n:quit\n' | ./bin/repl | grep -q "recovered"
	printf 'int x = = 3\nqq + 1\nprint(c"second recovery\\x0a")\n:quit\n' | ./bin/repl | grep -q "second recovery"
	# Multi-line function definitions persist and are callable
	printf 'int add(int a, int b):\n\treturn a + b\n\nadd(40, 2)\n:quit\n' | ./bin/repl | grep -q "42"
	# Interactive (pty) sessions auto-indent block bodies: no tabs typed here
	printf 'int fib(int n):\nif (n < 2):\nreturn n\nreturn fib(n - 1) + fib(n - 2)\n\nfib(10)\n:quit\n' | script -qc './bin/repl' /dev/null | grep -q "55"
	# Top-level variables persist between entries; bare expressions echo
	printf 'int x = 5\nx + 1\n:quit\n' | ./bin/repl | grep -q "6"
	printf '"hello string"\n:quit\n' | ./bin/repl | grep -q "hello string"
	# Redefinition shadows (Python-style rebinding); assignments stay silent
	printf 'int x = 5\nchar* x = c"shadowed"\nx\n:quit\n' | ./bin/repl | grep -q "shadowed"
	! printf 'int y = 3\ny = 9\n:quit\n' | ./bin/repl | grep -q "9"
	# Structs, new and imports work at the prompt
	printf 'struct pt:\n\tint x\n\tint y\n\npt* p = new pt(3, 4)\np.x + p.y\n:quit\n' | ./bin/repl | grep -q "7"
	# Import aliases bind at the prompt and qualified access resolves
	printf 'import tests.subfolder as sub\nsub.subfolder_value()\n:quit\n' | ./bin/repl | grep -q "1337"
	# Built-in container declarations work at the prompt (the runtime is
	# not auto-imported into the REPL's buffer, so import it first)
	printf 'import structures.w_list\nlist[int] l = list[int]{40, 2}\nl[0] + l[1]\n:quit\n' | ./bin/repl | grep -q "42"
	printf 'import structures.hash_table\nmap[char*, int] m = new map[char*, int]\nm[c"a"] = 41\nm[c"a"] + 1\n:quit\n' | ./bin/repl | grep -q "42"
	printf 'import structures.string\nstring_builder* s = string_from(c"imported")\ns.data\n:quit\n' | ./bin/repl | grep -q "imported"
	# Generic definitions persist across entries and instantiate on use
	printf 'T twice[T](T a):\n\treturn a + a\n\ntwice[int](21)\n:quit\n' | ./bin/repl | grep -q "42"
	printf 'struct pt[T]:\n\tT x\n\npt[int] g\ng.x = 7\ng.x\n:quit\n' | ./bin/repl | grep -q "7"
	printf 'import tests.generics_helper\nbox[int] b\nb.value = 21\nunbox[int](&b) + helper_boxed_sum(11, 10)\n:quit\n' | ./bin/repl | grep -q "42"
	# Errors inside multi-line entries and failed imports both recover
	printf 'int bad():\n\treturn qq\n\nprint(c"recovered fn\\x0a")\n:quit\n' | ./bin/repl | grep -q "recovered fn"
	printf 'import no.such.module\nprint(c"recovered import\\x0a")\n:quit\n' | ./bin/repl 2>/dev/null | grep -q "recovered import"
	# Run a file, then attach the prompt to its live definitions
	printf ':quit\n' | ./bin/repl tests/repl_fixture.w | grep -q "fixture main ran"
	printf 'fixture_helper(21)\nfixture_global\n:quit\n' | ./bin/repl tests/repl_fixture.w | grep -q "42"
	printf 'fixture_global\n:quit\n' | ./bin/repl tests/repl_fixture.w | grep -q "11"
	! printf ':quit\n' | ./bin/repl tests/repl_fixture.w --no_main | grep -q "fixture main ran"
	# Line editing on a pty: backspace fixes a typo before Enter
	rm -f ./bin/.w_history
	printf 'int q = 13\177\1774\nq + 1\n:quit\n' | HOME=./bin script -qc './bin/repl' /dev/null | grep -q "5"
	# Up-arrow recalls the previous entry and re-runs it
	test $$(printf 'int x = 41\nx + 1\n\033[A\n:quit\n' | HOME=./bin script -qc './bin/repl' /dev/null | grep -c "42") -eq 2
	# Accepted lines persist to $$HOME/.w_history
	grep -q "int x = 41" ./bin/.w_history
	rm -f ./bin/.w_history
	@echo "repl test OK"

# The x64 REPL: the same in-process model with 8-byte words; the code
# buffer sits in the low 2GB (MAP_32BIT) because the codegen embeds
# addresses as 32-bit immediates.
repl_test_x64: w FORCE
	./bin/wv2 x64 repl.w -o ./bin/repl64
	printf 'print(c"hello from the repl\\x0a")\n:quit\n' | ./bin/repl64 | grep -q "hello from the repl"
	printf 'this is not valid w\nprint(c"recovered\\x0a")\n:quit\n' | ./bin/repl64 | grep -q "recovered"
	printf 'int add(int a, int b):\n\treturn a + b\n\nadd(40, 2)\n:quit\n' | ./bin/repl64 | grep -q "42"
	printf 'int x = 5\nx + 1\n:quit\n' | ./bin/repl64 | grep -q "6"
	printf '"hello string"\n:quit\n' | ./bin/repl64 | grep -q "hello string"
	printf 'struct pt:\n\tint x\n\tint y\n\npt* p = new pt(3, 4)\np.x + p.y\n:quit\n' | ./bin/repl64 | grep -q "7"
	printf 'import structures.string\nstring_builder* s = string_from(c"imported")\ns.data\n:quit\n' | ./bin/repl64 | grep -q "imported"
	printf 'import structures.w_list\nlist[int] l = list[int]{40, 2}\nl[0] + l[1]\n:quit\n' | ./bin/repl64 | grep -q "42"
	printf 'import structures.hash_table\nmap[char*, int] m = new map[char*, int]\nm[c"a"] = 41\nm[c"a"] + 1\n:quit\n' | ./bin/repl64 | grep -q "42"
	printf 'int bad():\n\treturn qq\n\nprint(c"recovered fn\\x0a")\n:quit\n' | ./bin/repl64 | grep -q "recovered fn"
	printf ':quit\n' | ./bin/repl64 tests/repl_fixture.w | grep -q "fixture main ran"
	printf 'fixture_helper(21)\nfixture_global\n:quit\n' | ./bin/repl64 tests/repl_fixture.w | grep -q "42"
	! printf ':quit\n' | ./bin/repl64 tests/repl_fixture.w --no_main | grep -q "fixture main ran"
	# Line editing and history on a pty (same cases as the x86 repl_test)
	rm -f ./bin/.w_history
	printf 'int q = 13\177\1774\nq + 1\n:quit\n' | HOME=./bin script -qc './bin/repl64' /dev/null | grep -q "5"
	test $$(printf 'int x = 41\nx + 1\n\033[A\n:quit\n' | HOME=./bin script -qc './bin/repl64' /dev/null | grep -c "42") -eq 2
	grep -q "int x = 41" ./bin/.w_history
	rm -f ./bin/.w_history
	@echo "repl x64 test OK"

for_test: w FORCE
	./bin/wv2 tests/for_test.w >./bin/for_test
	chmod +x ./bin/for_test
	./bin/for_test

# Compound assignment operators (+=, -=, ..., <<=, >>=). The compile-error
# fixtures are arch-independent, so only the x86 target runs them.
compound_assign_test: w FORCE
	./bin/wv2 tests/compound_assign_test.w -o ./bin/compound_assign_test
	./bin/compound_assign_test
	! ./bin/wv2 tests/compound_assign_map_error_fixture.w -o ./bin/compound_assign_map_error_fixture 2>./bin/compound_assign_map_error_fixture.stderr
	grep -qF "compound assignment is not supported on map or set index targets" ./bin/compound_assign_map_error_fixture.stderr
	! ./bin/wv2 tests/compound_assign_struct_error_fixture.w -o ./bin/compound_assign_struct_error_fixture 2>./bin/compound_assign_struct_error_fixture.stderr
	grep -qF "compound assignment is not supported on struct values" ./bin/compound_assign_struct_error_fixture.stderr
	@echo "compound assign test OK"

compound_assign_64_test: w FORCE
	./bin/wv2 x64 tests/compound_assign_test.w -o ./bin/compound_assign_64_test
	./bin/compound_assign_64_test
	@echo "compound assign test x64 OK"

# 'name := expression' type-inferred local declarations
infer_test: w FORCE
	./bin/wv2 tests/infer_test.w -o ./bin/infer_test
	./bin/infer_test

# C-style ternary conditional expressions, including coexistence with
# the wresult '?' propagation suffix
ternary_test: w FORCE
	./bin/wv2 tests/ternary_test.w -o ./bin/ternary_test
	./bin/ternary_test

# Polymorphic print/println builtin: format dispatch by static type
print_builtin_test: w FORCE
	./bin/wv2 tests/print_builtin_test.w -o ./bin/print_builtin_test
	./bin/print_builtin_test > ./bin/print_builtin_test.out
	grep -qFx "greeting str via f" ./bin/print_builtin_test.out
	grep -qFx "1.250000" ./bin/print_builtin_test.out
	grep -qFx "[5, -1, 12]" ./bin/print_builtin_test.out
	grep -qFx "[one, two]" ./bin/print_builtin_test.out
	grep -qFx "[]" ./bin/print_builtin_test.out
	grep -qFx "big" ./bin/print_builtin_test.out
	@echo "print builtin test OK"

# Script mode: top-level statements compile into an implicit main; a
# declaration after the first statement is a clear compile error
script_mode_test: w FORCE
	./bin/wv2 tests/script_fixture.w -o ./bin/script_fixture
	./bin/script_fixture > ./bin/script_fixture.out
	grep -qFx "20" ./bin/script_fixture.out
	grep -qFx "nonzero" ./bin/script_fixture.out
	grep -qFx "[1, 3, 4]" ./bin/script_fixture.out
	grep -qFx "total=20" ./bin/script_fixture.out
	grep -qFx "deferred ran last" ./bin/script_fixture.out
	! ./bin/wv2 tests/script_error_fixture.w -o ./bin/script_error_fixture 2>./bin/script_error_fixture.stderr
	grep -qF "declarations must come before the first top-level statement" ./bin/script_error_fixture.stderr
	@echo "script mode test OK"

# input()/ints()/read_all() prelude helpers, fed by piped stdin
prelude_test: w FORCE
	./bin/wv2 tests/prelude_test.w -o ./bin/prelude_test
	printf 'header line\n1 2 3\n-4 and x5\n' | ./bin/prelude_test > ./bin/prelude_test.out
	grep -qFx "header line" ./bin/prelude_test.out
	grep -qFx "[1, 2, 3, -4, 5]" ./bin/prelude_test.out
	grep -qFx "7" ./bin/prelude_test.out
	@echo "prelude test OK"

# list[T] algorithm methods: sort, sort_by, map, filter, reduce, sum,
# min, max, reverse, count, index
list_methods_test: w FORCE
	./bin/wv2 tests/list_methods_test.w -o ./bin/list_methods_test
	./bin/list_methods_test

# lib/str.w: substring, index_of, split, replace, join
str_test: w FORCE
	./bin/wv2 tests/str_test.w -o ./bin/str_test
	./bin/str_test

# lib/math.w: min, max, abs, sign, gcd, pow
math_test: w FORCE
	./bin/wv2 tests/math_test.w -o ./bin/math_test
	./bin/math_test

# switch statement: dispatch, implicit break, break/continue interaction
# with loops, and its compile-error fixtures (arch-independent, so only
# the x86 target runs them)
switch_test: w FORCE
	./bin/wv2 tests/switch_test.w -o ./bin/switch_test
	./bin/switch_test
	! ./bin/wv2 tests/switch_default_not_last_error_fixture.w -o ./bin/switch_default_not_last_error_fixture 2>./bin/switch_default_not_last_error_fixture.stderr
	grep -qF "'default' must be the last clause in a switch" ./bin/switch_default_not_last_error_fixture.stderr
	! ./bin/wv2 tests/switch_body_error_fixture.w -o ./bin/switch_body_error_fixture 2>./bin/switch_body_error_fixture.stderr
	grep -qF "'case' or 'default' expected in switch body" ./bin/switch_body_error_fixture.stderr
	! ./bin/wv2 tests/switch_float_error_fixture.w -o ./bin/switch_float_error_fixture 2>./bin/switch_float_error_fixture.stderr
	grep -qF "switch on a float value is not supported" ./bin/switch_float_error_fixture.stderr
	@echo "switch test OK"

switch_64_test: w FORCE
	./bin/wv2 x64 tests/switch_test.w -o ./bin/switch_64_test
	./bin/switch_64_test
	@echo "switch test x64 OK"

# Cursor-protocol iteration: for x in <container>
for_container_64_test: w FORCE
	./bin/wv2 x64 tests/for_container_test.w -o ./bin/for_container_64_test
	./bin/for_container_64_test

# The compile-error fixtures are arch-independent, so only the x86 target
# runs them.
for_container_test: w FORCE
	./bin/wv2 tests/for_container_test.w -o ./bin/for_container_test
	./bin/for_container_test
	! ./bin/wv2 tests/for_container_error_fixture.w -o ./bin/for_container_error_fixture 2>./bin/for_container_error_fixture.stderr
	grep -qF "type 'point' is not iterable: point_iter_begin not found" ./bin/for_container_error_fixture.stderr
	! ./bin/wv2 tests/for_container_raw_pointer_error_fixture.w -o ./bin/for_container_raw_pointer_error_fixture 2>./bin/for_container_raw_pointer_error_fixture.stderr
	grep -qF "type 'int*' is not iterable: expected a pointer to a container struct" ./bin/for_container_raw_pointer_error_fixture.stderr
	! ./bin/wv2 tests/for_container_non_function_error_fixture.w -o ./bin/for_container_non_function_error_fixture 2>./bin/for_container_non_function_error_fixture.stderr
	grep -qF "type 'bad_iter_symbol' is not iterable: bad_iter_symbol_iter_begin is not a function" ./bin/for_container_non_function_error_fixture.stderr
	! ./bin/wv2 tests/for_container_wrong_arity_error_fixture.w -o ./bin/for_container_wrong_arity_error_fixture 2>./bin/for_container_wrong_arity_error_fixture.stderr
	grep -qF "type 'bad_iter_arity' is not iterable: bad_iter_arity_iter_begin has wrong arity" ./bin/for_container_wrong_arity_error_fixture.stderr
	! ./bin/wv2 tests/for_container_void_return_error_fixture.w -o ./bin/for_container_void_return_error_fixture 2>./bin/for_container_void_return_error_fixture.stderr
	grep -qF "type 'bad_iter_return' is not iterable: bad_iter_return_iter_begin must return a word-sized value" ./bin/for_container_void_return_error_fixture.stderr
	! ./bin/wv2 tests/for_container_wrong_param_error_fixture.w -o ./bin/for_container_wrong_param_error_fixture 2>./bin/for_container_wrong_param_error_fixture.stderr
	grep -qF "type 'bad_iter_param' is not iterable: bad_iter_param_iter_begin first parameter must match the iterable type" ./bin/for_container_wrong_param_error_fixture.stderr
	@echo "for container test OK"

# Generators + yield (docs/projects/iteration.md, stackful coroutines)
generator_64_test: w FORCE
	./bin/wv2 x64 tests/generator_test.w -o ./bin/generator_64_test
	./bin/generator_64_test

# The compile-error fixtures are arch-independent, so only the x86 target
# runs them.
generator_test: w FORCE
	./bin/wv2 tests/generator_test.w -o ./bin/generator_test
	./bin/generator_test
	! ./bin/wv2 tests/yield_outside_generator_error_fixture.w -o ./bin/yield_outside_generator_error_fixture 2>./bin/yield_outside_generator_error_fixture.stderr
	grep -qF "'yield' outside of a generator body" ./bin/yield_outside_generator_error_fixture.stderr
	! ./bin/wv2 tests/generator_return_value_error_fixture.w -o ./bin/generator_return_value_error_fixture 2>./bin/generator_return_value_error_fixture.stderr
	grep -qF "generators cannot return a value; use yield" ./bin/generator_return_value_error_fixture.stderr
	@echo "generator test OK"

# Go-style 'defer' statements (docs/projects/defer.md): runtime behavior
# plus the compile-error fixtures (arch-independent, so only the x86
# target runs them).
defer_test: w FORCE
	./bin/wv2 tests/defer_test.w -o ./bin/defer_test
	./bin/defer_test
	! ./bin/wv2 tests/defer_generator_error_fixture.w -o ./bin/defer_generator_error_fixture 2>./bin/defer_generator_error_fixture.stderr
	grep -qF "'defer' is not supported in generator bodies" ./bin/defer_generator_error_fixture.stderr
	! ./bin/wv2 tests/defer_declaration_error_fixture.w -o ./bin/defer_declaration_error_fixture 2>./bin/defer_declaration_error_fixture.stderr
	grep -qF "deferred statement cannot declare a variable" ./bin/defer_declaration_error_fixture.stderr
	! ./bin/wv2 tests/defer_return_error_fixture.w -o ./bin/defer_return_error_fixture 2>./bin/defer_return_error_fixture.stderr
	grep -qF "'return' is not allowed in a deferred statement" ./bin/defer_return_error_fixture.stderr
	! ./bin/wv2 tests/defer_nested_error_fixture.w -o ./bin/defer_nested_error_fixture 2>./bin/defer_nested_error_fixture.stderr
	grep -qF "'defer' cannot be nested in a deferred statement" ./bin/defer_nested_error_fixture.stderr
	! ./bin/wv2 tests/defer_top_level_error_fixture.w -o ./bin/defer_top_level_error_fixture 2>./bin/defer_top_level_error_fixture.stderr
	grep -qF "declarations must come before the first top-level statement" ./bin/defer_top_level_error_fixture.stderr
	@echo "defer test OK"

defer_64_test: w FORCE
	./bin/wv2 x64 tests/defer_test.w -o ./bin/defer_64_test
	./bin/defer_64_test
	@echo "defer test x64 OK"

# Default parameter values ("int times = 1"): runtime behavior plus the
# compile-error fixtures (arch-independent, so only the x86 target runs
# them) and the unchanged too-few-arguments warning.
default_args_test: w FORCE
	./bin/wv2 tests/default_args_test.w -o ./bin/default_args_test
	./bin/default_args_test
	! ./bin/wv2 tests/default_args_nontrailing_error_fixture.w -o ./bin/default_args_nontrailing_error_fixture 2>./bin/default_args_nontrailing_error_fixture.stderr
	grep -qF "parameter without a default follows a parameter with a default" ./bin/default_args_nontrailing_error_fixture.stderr
	! ./bin/wv2 tests/default_args_nonconstant_error_fixture.w -o ./bin/default_args_nonconstant_error_fixture 2>./bin/default_args_nonconstant_error_fixture.stderr
	grep -qF "default value for parameter must be a compile-time constant" ./bin/default_args_nonconstant_error_fixture.stderr
	./bin/wv2 tests/default_args_missing_warning_fixture.w -o ./bin/default_args_missing_warning_fixture 2>./bin/default_args_missing_warning_fixture.stderr
	grep -qF "warning: function 'da_no_defaults' expects 2 arguments, got 1" ./bin/default_args_missing_warning_fixture.stderr
	@echo "default args test OK"

default_args_64_test: w FORCE
	./bin/wv2 x64 tests/default_args_test.w -o ./bin/default_args_64_test
	./bin/default_args_64_test
	@echo "default args test x64 OK"

# W-native variadic functions ("int... values" collected into a slice);
# distinct from varargs_test, which covers variadic C imports.
varargs_w_test: w FORCE
	./bin/wv2 tests/varargs_w_test.w -o ./bin/varargs_w_test
	./bin/varargs_w_test
	! ./bin/wv2 tests/varargs_w_not_last_error_fixture.w -o ./bin/varargs_w_not_last_error_fixture 2>./bin/varargs_w_not_last_error_fixture.stderr
	grep -qF "variadic parameter must be the last parameter" ./bin/varargs_w_not_last_error_fixture.stderr
	! ./bin/wv2 tests/varargs_w_default_error_fixture.w -o ./bin/varargs_w_default_error_fixture 2>./bin/varargs_w_default_error_fixture.stderr
	grep -qF "a variadic parameter cannot follow parameters with default values" ./bin/varargs_w_default_error_fixture.stderr
	@echo "varargs w test OK"

varargs_w_64_test: w FORCE
	./bin/wv2 x64 tests/varargs_w_test.w -o ./bin/varargs_w_64_test
	./bin/varargs_w_64_test
	@echo "varargs w test x64 OK"

# Cross-feature interaction: template strings + default parameter
# values + W variadics + generators combined in one program.
feature_interaction_test: w FORCE
	./bin/wv2 tests/feature_interaction_test.w -o ./bin/feature_interaction_test
	./bin/feature_interaction_test
	@echo "feature interaction test OK"

feature_interaction_64_test: w FORCE
	./bin/wv2 x64 tests/feature_interaction_test.w -o ./bin/feature_interaction_64_test
	./bin/feature_interaction_64_test
	@echo "feature interaction test x64 OK"

# Cross-feature interaction: compound assignment + switch + defer +
# wresult[T]/'?' propagation + generic inference in one program (in
# particular, the '?' error path must run deferred statements).
feature_combo_test: w FORCE
	./bin/wv2 tests/feature_combo_test.w -o ./bin/feature_combo_test
	./bin/feature_combo_test
	@echo "feature combo test OK"

feature_combo_64_test: w FORCE
	./bin/wv2 x64 tests/feature_combo_test.w -o ./bin/feature_combo_64_test
	./bin/feature_combo_64_test
	@echo "feature combo test x64 OK"

# Dynamic 'var' type: runtime behavior, the wrong-tag unbox trap, and
# the compile-error fixtures (the fixtures are arch-independent, so
# only the x86 target runs them; see dynamic_var_64_test for the x64
# run). Unrelated to dynamic_test, which checks ELF dynamic linking.
dynamic_var_test: w FORCE
	./bin/wv2 tests/dynamic_var_test.w -o ./bin/dynamic_var_test
	./bin/dynamic_var_test
	./bin/wv2 tests/dynamic_var_trap_fixture.w -o ./bin/dynamic_var_trap_fixture
	! ./bin/dynamic_var_trap_fixture 2>./bin/dynamic_var_trap_fixture.stderr
	grep -qF "var runtime error: expected int, got char*" ./bin/dynamic_var_trap_fixture.stderr
	! ./bin/wv2 tests/dynamic_var_float_error_fixture.w -o ./bin/dynamic_var_float_error_fixture 2>./bin/dynamic_var_float_error_fixture.stderr
	grep -qF "cannot convert 'float32' to var" ./bin/dynamic_var_float_error_fixture.stderr
	! ./bin/wv2 tests/dynamic_var_mod_error_fixture.w -o ./bin/dynamic_var_mod_error_fixture 2>./bin/dynamic_var_mod_error_fixture.stderr
	grep -qF "var operands do not support %" ./bin/dynamic_var_mod_error_fixture.stderr
	! ./bin/wv2 tests/dynamic_var_variadic_error_fixture.w -o ./bin/dynamic_var_variadic_error_fixture 2>./bin/dynamic_var_variadic_error_fixture.stderr
	grep -qF "variadic parameter element type cannot be var" ./bin/dynamic_var_variadic_error_fixture.stderr
	! ./bin/wv2 tests/dynamic_var_default_error_fixture.w -o ./bin/dynamic_var_default_error_fixture 2>./bin/dynamic_var_default_error_fixture.stderr
	grep -qF "default values are not supported on var parameters" ./bin/dynamic_var_default_error_fixture.stderr
	@echo "dynamic var test OK"

dynamic_var_64_test: w FORCE
	./bin/wv2 x64 tests/dynamic_var_test.w -o ./bin/dynamic_var_64_test
	./bin/dynamic_var_64_test
	./bin/wv2 x64 tests/dynamic_var_trap_fixture.w -o ./bin/dynamic_var_trap_fixture_64
	! ./bin/dynamic_var_trap_fixture_64 2>./bin/dynamic_var_trap_fixture_64.stderr
	grep -qF "var runtime error: expected int, got char*" ./bin/dynamic_var_trap_fixture_64.stderr
	@echo "dynamic var test x64 OK"

# Generics with explicit instantiation (docs/projects/generics.md):
# runtime behavior plus the compile-error fixtures (arch-independent,
# so only the x86 target runs them).
generics_test: w FORCE
	./bin/wv2 tests/generics_test.w -o ./bin/generics_test
	./bin/generics_test
	! ./bin/wv2 tests/generics_unknown_param_error_fixture.w -o ./bin/generics_unknown_param_error_fixture 2>./bin/generics_unknown_param_error_fixture.stderr
	grep -qF "unknown type name: 'U'" ./bin/generics_unknown_param_error_fixture.stderr
	! ./bin/wv2 tests/generics_arg_count_error_fixture.w -o ./bin/generics_arg_count_error_fixture 2>./bin/generics_arg_count_error_fixture.stderr
	grep -qF "wrong number of type arguments for generic 'pick': expected 1, got 2" ./bin/generics_arg_count_error_fixture.stderr
	! ./bin/wv2 tests/generics_missing_args_error_fixture.w -o ./bin/generics_missing_args_error_fixture 2>./bin/generics_missing_args_error_fixture.stderr
	grep -qF "generic function 'make': cannot infer type argument 'T'" ./bin/generics_missing_args_error_fixture.stderr
	@echo "generics test OK"

generics_64_test: w FORCE
	./bin/wv2 x64 tests/generics_test.w -o ./bin/generics_64_test
	./bin/generics_64_test
	@echo "generics test x64 OK"

# Generic type-argument inference (docs/projects/generics.md): calls
# without '[type-args]' infer them from the argument types. Runtime
# behavior plus the inference error fixtures (arch-independent, so only
# the x86 target runs them).
generics_inference_test: w FORCE
	./bin/wv2 tests/generics_inference_test.w -o ./bin/generics_inference_test
	./bin/generics_inference_test
	! ./bin/wv2 tests/generics_infer_conflict_error_fixture.w -o ./bin/generics_infer_conflict_error_fixture 2>./bin/generics_infer_conflict_error_fixture.stderr
	grep -qF "conflicting types inferred for type parameter 'T': 'int' vs 'char*'" ./bin/generics_infer_conflict_error_fixture.stderr
	! ./bin/wv2 tests/generics_infer_struct_shape_error_fixture.w -o ./bin/generics_infer_struct_shape_error_fixture 2>./bin/generics_infer_struct_shape_error_fixture.stderr
	grep -qF "generic function 'sum_first': cannot infer type argument 'T'" ./bin/generics_infer_struct_shape_error_fixture.stderr
	! ./bin/wv2 tests/generics_infer_forward_error_fixture.w -o ./bin/generics_infer_forward_error_fixture 2>./bin/generics_infer_forward_error_fixture.stderr
	grep -qF "Cannot find symbol: 'later_pick'" ./bin/generics_infer_forward_error_fixture.stderr
	@echo "generics inference test OK"

generics_inference_64_test: w FORCE
	./bin/wv2 x64 tests/generics_inference_test.w -o ./bin/generics_inference_64_test
	./bin/generics_inference_64_test
	@echo "generics inference test x64 OK"

range: w FORCE
	./bin/wv2 range_test.w >./bin/range_test
	chmod +x ./bin/range_test
	./bin/range_test

test1: FORCE
	./w test.w >./bin/test
	chmod +x ./bin/test
	./bin/test arg1 arg2 arg3 -o output -i=input --input=doubledash

debug: FORCE
	./w test.w >./bin/test
	chmod +x ./bin/test
	gdb -ex run --args test arg1 arg2 arg3

multilayer_test: w FORCE
	./bin/wv2 tests/multilayer_test.w >./bin/multilayer_test
	chmod +x ./bin/multilayer_test
	./bin/multilayer_test

hash_map_test: w FORCE
	./bin/wv2 structures/hash_map_test.w -o ./bin/hash_map_test
	./bin/hash_map_test

hash_map_64_test: w FORCE
	./bin/wv2 x64 structures/hash_map_test.w -o ./bin/hash_map_64_test
	./bin/hash_map_64_test

hash_table_test: w FORCE
	./bin/wv2 structures/hash_table_test.w -o ./bin/hash_table_test
	./bin/hash_table_test

hash_table_64_test: w FORCE
	./bin/wv2 x64 structures/hash_table_test.w -o ./bin/hash_table_64_test
	./bin/hash_table_64_test

# The error fixture is arch-independent, so only the x86 target runs it.
map_set_builtin_64_test: w FORCE
	./bin/wv2 x64 tests/map_set_builtin_test.w -o ./bin/map_set_builtin_64_test
	./bin/map_set_builtin_64_test

map_set_builtin_test: w FORCE
	./bin/wv2 tests/map_set_builtin_test.w -o ./bin/map_set_builtin_test
	./bin/map_set_builtin_test
	! ./bin/wv2 tests/map_value_array_error_fixture.w -o ./bin/map_value_array_error_fixture 2>./bin/map_value_array_error_fixture.stderr
	grep -qF "map value type cannot be a fixed-size array" ./bin/map_value_array_error_fixture.stderr

# Built-in typed list[T]: literals, indexing, push/pop, length, iteration
# The warning/error fixtures are arch-independent, so only the x86 target
# runs them.
list_builtin_64_test: w FORCE
	./bin/wv2 x64 tests/list_builtin_test.w -o ./bin/list_builtin_64_test
	./bin/list_builtin_64_test

list_builtin_test: w FORCE
	./bin/wv2 tests/list_builtin_test.w -o ./bin/list_builtin_test
	./bin/list_builtin_test
	./bin/wv2 tests/list_builtin_warning_fixture.w -o ./bin/list_builtin_warning_fixture 2>./bin/list_builtin_warning_fixture.stderr
	grep -qF "warning: list push type mismatch: expected 'int', got 'char*'" ./bin/list_builtin_warning_fixture.stderr
	grep -qF "warning: assignment type mismatch: expected 'int', got 'char*'" ./bin/list_builtin_warning_fixture.stderr
	grep -qF "warning: initialization type mismatch: expected 'list[int]', got 'list[char*]'" ./bin/list_builtin_warning_fixture.stderr
	grep -qF "warning: for loop variable type mismatch: expected 'char*', got 'int'" ./bin/list_builtin_warning_fixture.stderr
	grep -qF "warning: list literal element type mismatch: expected 'char*', got 'int'" ./bin/list_builtin_warning_fixture.stderr
	! ./bin/wv2 tests/list_array_element_error_fixture.w -o ./bin/list_array_element_error_fixture 2>./bin/list_array_element_error_fixture.stderr
	grep -qF "list element type cannot be a fixed-size array" ./bin/list_array_element_error_fixture.stderr
	! ./bin/wv2 tests/list_array_field_error_fixture.w -o ./bin/list_array_field_error_fixture 2>./bin/list_array_field_error_fixture.stderr
	grep -qF "list element type cannot contain fixed-size array fields" ./bin/list_array_field_error_fixture.stderr
	! ./bin/wv2 tests/list_field_error_fixture.w -o ./bin/list_field_error_fixture 2>./bin/list_field_error_fixture.stderr
	grep -qF "list field 'append' not found" ./bin/list_field_error_fixture.stderr
	./bin/wv2 tests/list_pop_empty_fixture.w -o ./bin/list_pop_empty_fixture
	! ./bin/list_pop_empty_fixture
	./bin/wv2 tests/list_index_bounds_fixture.w -o ./bin/list_index_bounds_fixture
	! ./bin/list_index_bounds_fixture

# f"..." template strings: runtime behavior plus the compile-error
# fixtures (the fixtures are arch-independent, so only the x86 target
# runs them; see template_string_64_test for the x64 run).
template_string_test: w FORCE
	./bin/wv2 tests/template_string_test.w -o ./bin/template_string_test
	./bin/template_string_test
	! ./bin/wv2 tests/template_string_error_fixture.w -o ./bin/template_string_error_fixture 2>./bin/template_string_error_fixture.stderr
	grep -qF "unsupported template string expression type: 'int*'" ./bin/template_string_error_fixture.stderr
	! ./bin/wv2 tests/template_string_unterminated_fixture.w -o ./bin/template_string_unterminated_fixture 2>./bin/template_string_unterminated_fixture.stderr
	grep -qF "unterminated template string literal" ./bin/template_string_unterminated_fixture.stderr
	! ./bin/wv2 tests/template_string_unterminated_expr_fixture.w -o ./bin/template_string_unterminated_expr_fixture 2>./bin/template_string_unterminated_expr_fixture.stderr
	grep -qF "'}' expected in template string expression" ./bin/template_string_unterminated_expr_fixture.stderr
	! ./bin/wv2 tests/template_string_stray_brace_fixture.w -o ./bin/template_string_stray_brace_fixture 2>./bin/template_string_stray_brace_fixture.stderr
	grep -qF "single '}' in template string; use '}}'" ./bin/template_string_stray_brace_fixture.stderr
	@echo "template string test OK"

template_string_64_test: w FORCE
	./bin/wv2 x64 tests/template_string_test.w -o ./bin/template_string_64_test
	./bin/template_string_64_test

string_test: w FORCE
	./bin/wv2 structures/string_test.w -o ./bin/string_test
	./bin/string_test

string_64_test: w FORCE
	./bin/wv2 x64 structures/string_test.w -o ./bin/string_64_test
	./bin/string_64_test

array_list_test: w FORCE
	./bin/wv2 structures/array_list_test.w -o ./bin/array_list_test
	./bin/array_list_test

array_list_64_test: w FORCE
	./bin/wv2 x64 structures/array_list_test.w -o ./bin/array_list_64_test
	./bin/array_list_64_test

json_test: w FORCE
	./bin/wv2 structures/json_test.w -o ./bin/json_test
	./bin/json_test

json_64_test: w FORCE
	./bin/wv2 x64 structures/json_test.w -o ./bin/json_64_test
	./bin/json_64_test

# to_json/from_json builtin round trips
json_codec_test: w FORCE
	./bin/wv2 tests/json_codec_test.w -o ./bin/json_codec_test
	./bin/json_codec_test

json_codec_64_test: w FORCE
	./bin/wv2 x64 tests/json_codec_test.w -o ./bin/json_codec_64_test
	./bin/json_codec_64_test

parser_generator_test: w FORCE
	./bin/wv2 tools/parser_generator.w -o ./bin/parser_generator
	./bin/parser_generator tests/parser_generator/sample.pg -o ./bin/generated_sample_parser.w
	./bin/wv2 tests/parser_generator/generated_sample_test.w -o ./bin/parser_generator_test
	./bin/parser_generator_test

parser_generator_w_test: parser_generator_test FORCE
	git ls-files '*.w' > ./bin/parser_generator_w_files.txt
	./bin/parser_generator tests/parser_generator/w.pg -o ./bin/generated_w_parser.w
	./bin/wv2 tests/parser_generator/generated_w_parser_test.w -o ./bin/parser_generator_w_test
	./bin/parser_generator_w_test

parser_generator_c_test: parser_generator_test FORCE
	./bin/parser_generator tests/parser_generator/c.pg -o ./bin/generated_c_parser.w
	cmp ./bin/generated_c_parser.w ./libs/extras/c_import/generated_c_parser.w
	./bin/wv2 tests/parser_generator/generated_c_parser_test.w -o ./bin/parser_generator_c_test
	./bin/parser_generator_c_test

wtest: w FORCE
	@mkdir -p bin; test -x ./bin/wv2 || $(MAKE) -s build
	./bin/wv2 tools/test_map.w -o ./bin/wtest

test_changed: wtest FORCE
	git diff --name-only HEAD | ./bin/wtest changed | xargs -r $(MAKE)

wtest_map_test: wtest FORCE
	printf 'grammar/promote.w\n' | ./bin/wtest changed > ./bin/wtest_map.out
	printf 'verify\nself_host_warning_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed structures/json.w > ./bin/wtest_map.out
	printf 'json_test\njson_64_test\njson_codec_test\njson_codec_64_test\njson_rpc_test\njson_rpc_64_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed tests/warning_fixture.w > ./bin/wtest_map.out
	printf 'warning_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed libs/extras/parser_generator/generator.w > ./bin/wtest_map.out
	printf 'parser_generator_test\nparser_generator_w_test\nparser_generator_c_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed docs/todo.txt > ./bin/wtest_map.out
	test ! -s ./bin/wtest_map.out
	./bin/wtest changed unknown/new_file.w > ./bin/wtest_map.out
	printf 'tests\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	printf 'lib/stream.w\n' | ./bin/wtest changed > ./bin/wtest_map.out
	printf 'stream_test\nstream_64_test\nfile_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed lib/file.w > ./bin/wtest_map.out
	printf 'file_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed lib/line_edit.w > ./bin/wtest_map.out
	printf 'repl_test\ndebug_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed tools/wexec.w tests/wexec/good.json > ./bin/wtest_map.out
	printf 'wexec_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed build.json > ./bin/wtest_map.out
	printf 'wexec_test\ntests\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed tools/lsp/w_lsp.w > ./bin/wtest_map.out
	printf 'lsp_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed tools/mcp/w_toolchain_mcp.w > ./bin/wtest_map.out
	printf 'mcp_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed tools/hooks/w_check_hook.w .cursor/hooks.json > ./bin/wtest_map.out
	printf 'hook_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed .cursor/rules/w-source.mdc .cursor/skills/w-check-diagnostics/SKILL.md > ./bin/wtest_map.out
	test ! -s ./bin/wtest_map.out
	@echo "wtest map test OK"

rewrite_c_strings: w FORCE
	./bin/wv2 tools/rewrite_c_string_literals.w -o ./bin/rewrite_c_strings

grapheme_data: w FORCE
	./bin/wv2 tools/generate_grapheme_data.w -o ./bin/generate_grapheme_data
	./bin/generate_grapheme_data

wmcp: w FORCE
	@mkdir -p bin; test -x ./bin/wv2 || $(MAKE) -s build
	./bin/wv2 tools/mcp/w_toolchain_mcp.w -o ./bin/wmcp

mcp_test: wmcp FORCE
	./bin/wv2 tools/mcp/mcp_test.w -o ./bin/mcp_test
	./bin/mcp_test

# Stdio LSP server (diagnostics from 'check --json', definition from
# 'symbols --json'; see docs/projects/lsp.md).
wlsp: w FORCE
	@mkdir -p bin; test -x ./bin/wv2 || $(MAKE) -s build
	./bin/wv2 tools/lsp/w_lsp.w -o ./bin/wlsp

lsp_test: wlsp FORCE
	./bin/wv2 tools/lsp/lsp_test.w -o ./bin/lsp_test
	./bin/lsp_test

# Cursor postToolUse hook: emits 'check --json' diagnostics back into
# the agent's context after every .w edit (see .cursor/hooks.json).
whook: w FORCE
	@mkdir -p bin; test -x ./bin/wv2 || $(MAKE) -s build
	./bin/wv2 tools/hooks/w_check_hook.w -o ./bin/whook

hook_test: whook FORCE
	# a file with warnings produces an additional_context payload
	cp tests/warning_fixture.w ./bin/hook_edit_sample.w
	printf '{"hook_event_name":"postToolUse","tool_name":"Write","tool_input":{"path":"bin/hook_edit_sample.w"}}' | ./bin/whook > ./bin/hook_test.out
	grep -qF '"additional_context"' ./bin/hook_test.out
	grep -qF 'assignment type mismatch' ./bin/hook_test.out
	# afterFileEdit-style payloads (file_path at top level) work too
	printf '{"hook_event_name":"afterFileEdit","file_path":"bin/hook_edit_sample.w","edits":[]}' | ./bin/whook > ./bin/hook_test.out
	grep -qF 'assignment type mismatch' ./bin/hook_test.out
	# a clean file, a non-W file, a read tool, and a fixture are silent
	printf '{"hook_event_name":"postToolUse","tool_name":"StrReplace","tool_input":{"file_path":"tests/hello.w"}}' | ./bin/whook > ./bin/hook_test.out
	printf '{}\n' > ./bin/hook_test.expected
	diff -u ./bin/hook_test.expected ./bin/hook_test.out
	printf '{"hook_event_name":"postToolUse","tool_name":"Write","tool_input":{"path":"README.md"}}' | ./bin/whook > ./bin/hook_test.out
	diff -u ./bin/hook_test.expected ./bin/hook_test.out
	printf '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"bin/hook_edit_sample.w"}}' | ./bin/whook > ./bin/hook_test.out
	diff -u ./bin/hook_test.expected ./bin/hook_test.out
	printf '{"hook_event_name":"postToolUse","tool_name":"Write","tool_input":{"path":"tests/warning_fixture.w"}}' | ./bin/whook > ./bin/hook_test.out
	diff -u ./bin/hook_test.expected ./bin/hook_test.out
	# malformed input fails open
	printf 'not json' | ./bin/whook > ./bin/hook_test.out
	diff -u ./bin/hook_test.expected ./bin/hook_test.out
	# the committed wrapper drives the same path end to end
	printf '{"hook_event_name":"postToolUse","tool_name":"Write","tool_input":{"path":"bin/hook_edit_sample.w"}}' | ./.cursor/hooks/check_after_edit.sh > ./bin/hook_test.out
	grep -qF 'assignment type mismatch' ./bin/hook_test.out
	@echo "hook test OK"

# The W-native build executor (Method-5 manifest runner, see
# docs/projects/wexec.md). Fixture manifests cover the DAG, expectation
# and failure paths; the real build.json is exercised end to end.
wexec_test: w FORCE
	./bin/wv2 tools/wexec.w -o ./bin/wexec
	# happy path: dep runs before the requester, expectations pass
	./bin/wexec -f tests/wexec/good.json main | grep -q "dep before main"
	./bin/wexec -f tests/wexec/good.json main | grep -q "wexec: OK (2 targets)"
	# a target runs at most once per invocation
	./bin/wexec -f tests/wexec/good.json main main dep | grep -q "wexec: OK (2 targets)"
	# --list emits the targets in manifest order
	./bin/wexec -f tests/wexec/good.json --list > ./bin/wexec_list.out
	printf 'dep\nmain\nfails\nexpects_fail\nwrong_output\ncycle_a\ncycle_b\n' > ./bin/wexec_list.expected
	diff -u ./bin/wexec_list.expected ./bin/wexec_list.out
	# a failing step aborts the run with a nonzero exit
	! ./bin/wexec -f tests/wexec/good.json fails 2>./bin/wexec_fails.stderr
	grep -q "command failed with exit status" ./bin/wexec_fails.stderr
	# expect_fail inverts the exit status check
	./bin/wexec -f tests/wexec/good.json expects_fail | grep -q "wexec: OK (1 targets)"
	# a missing expected substring fails the step
	! ./bin/wexec -f tests/wexec/good.json wrong_output 2>./bin/wexec_wrong.stderr
	grep -q "expected stdout to contain" ./bin/wexec_wrong.stderr
	# unknown target, dependency cycle and invalid manifest all diagnose
	! ./bin/wexec -f tests/wexec/good.json no_such_target 2>./bin/wexec_unknown.stderr
	grep -q "unknown target" ./bin/wexec_unknown.stderr
	! ./bin/wexec -f tests/wexec/good.json cycle_a 2>./bin/wexec_cycle.stderr
	grep -q "dependency cycle" ./bin/wexec_cycle.stderr
	! ./bin/wexec -f tests/wexec/bad.json broken 2>./bin/wexec_bad.stderr
	grep -q "not valid JSON" ./bin/wexec_bad.stderr
	! ./bin/wexec -f tests/wexec/missing_manifest.json anything 2>./bin/wexec_missing.stderr
	grep -q "cannot read manifest" ./bin/wexec_missing.stderr
	# extended step fields: expect arrays, reject_*, expect_status, capture files
	./bin/wexec -f tests/wexec/features.json expect_array rejects status_ok capture_file | grep -q "wexec: OK (4 targets)"
	! ./bin/wexec -f tests/wexec/features.json expect_array_missing 2>./bin/wexec_features.stderr
	grep -q "expected stdout to contain: absent" ./bin/wexec_features.stderr
	! ./bin/wexec -f tests/wexec/features.json reject_present 2>./bin/wexec_features.stderr
	grep -q "expected stdout to not contain: warning:" ./bin/wexec_features.stderr
	! ./bin/wexec -f tests/wexec/features.json status_wrong 2>./bin/wexec_features.stderr
	grep -q "command exited 0, expected status 3" ./bin/wexec_features.stderr
	# content-hash caching: a second run hits, changed inputs or missing
	# outputs miss, --no-cache forces, targets without inputs always run
	printf 'v1\n' > ./bin/wexec_cache_input.txt
	rm -f ./bin/.wexec_cache/cache_hit ./bin/.wexec_cache/uses_dep ./bin/wexec_cache_out.txt
	! ./bin/wexec -f tests/wexec/cache.json cache_hit | grep -q "(cached)"
	./bin/wexec -f tests/wexec/cache.json cache_hit | grep -q "cache_hit (cached)"
	! ./bin/wexec -f tests/wexec/cache.json uses_dep | grep -q "uses_dep (cached)"
	./bin/wexec -f tests/wexec/cache.json uses_dep | grep -q "uses_dep (cached)"
	printf 'v2\n' > ./bin/wexec_cache_input.txt
	! ./bin/wexec -f tests/wexec/cache.json cache_hit | grep -q "(cached)"
	./bin/wexec -f tests/wexec/cache.json cache_hit | grep -q "cache_hit (cached)"
	rm -f ./bin/wexec_cache_out.txt
	! ./bin/wexec -f tests/wexec/cache.json cache_hit | grep -q "(cached)"
	! ./bin/wexec -f tests/wexec/cache.json --no-cache cache_hit | grep -q "(cached)"
	./bin/wexec -f tests/wexec/cache.json force | grep -q "force ran"
	./bin/wexec -f tests/wexec/cache.json force | grep -q "force ran"
	# parallel scheduler: three 0.6s branches overlap under the default
	# -j (nproc), -j 1 serializes, failures still abort with exit 1
	timeout 1.4 ./bin/wexec -f tests/wexec/parallel.json parallel_all | grep -q "wexec: OK (5 targets)"
	./bin/wexec -j 1 -f tests/wexec/parallel.json parallel_all | grep -q "wexec: OK (5 targets)"
	! ./bin/wexec -f tests/wexec/parallel.json parallel_fails 2>./bin/wexec_parallel.stderr
	grep -q "command failed with exit status" ./bin/wexec_parallel.stderr
	# no requested target: usage plus the target list, nonzero exit
	! ./bin/wexec -f tests/wexec/good.json > ./bin/wexec_noarg.out 2>./bin/wexec_noarg.stderr
	grep -q "usage: wexec" ./bin/wexec_noarg.stderr
	grep -q "main" ./bin/wexec_noarg.out
	# the real manifest: build and run a program end to end
	./bin/wexec hello | grep -q "hello, world!"
	@echo "wexec test OK"

wmeta: w FORCE
	./bin/wv2 tools/wmeta.w -o ./bin/wmeta

# Validate the repository's own package metadata (docs/package_metadata.txt).
metadata_check: wmeta FORCE
	./bin/wmeta check package.wmeta
	@echo "metadata check OK"

# Checker behavior against the fixture packages in tests/metadata/: the good
# package (with a vendored path dependency) passes, each bad fixture fails
# with its specific diagnostic.
metadata_test: wmeta FORCE
	./bin/wmeta check tests/metadata/good/package.wmeta | grep -qF "wmeta: OK package 'example.app' version 1.0.0"
	! ./bin/wmeta check tests/metadata/bad_version/package.wmeta 2>./bin/wmeta_bad_version.stderr
	grep -qF "expected three numeric components" ./bin/wmeta_bad_version.stderr
	! ./bin/wmeta check tests/metadata/missing_module/package.wmeta 2>./bin/wmeta_missing_module.stderr
	grep -qF "module 'nope.missing' not found" ./bin/wmeta_missing_module.stderr
	! ./bin/wmeta check tests/metadata/duplicate_module/package.wmeta 2>./bin/wmeta_duplicate_module.stderr
	grep -qF "duplicate module 'dup.thing'" ./bin/wmeta_duplicate_module.stderr
	! ./bin/wmeta check tests/metadata/bad_constraint/package.wmeta 2>./bin/wmeta_bad_constraint.stderr
	grep -qF "does not satisfy constraint ^2.0.0" ./bin/wmeta_bad_constraint.stderr
	! ./bin/wmeta check tests/metadata/collision/package.wmeta 2>./bin/wmeta_collision.stderr
	grep -qF "top-level module path 'net' claimed by packages" ./bin/wmeta_collision.stderr
	! ./bin/wmeta check tests/metadata/no_such_dir/package.wmeta 2>./bin/wmeta_missing_meta.stderr
	grep -qF "cannot read package.wmeta" ./bin/wmeta_missing_meta.stderr
	@echo "metadata test OK"

linked_list_test: w FORCE
	./bin/wv2 structures/linked_list_test.w -o ./bin/linked_list_test
	./bin/linked_list_test

linked_list_64_test: w FORCE
	./bin/wv2 x64 structures/linked_list_test.w -o ./bin/linked_list_64_test
	./bin/linked_list_64_test

format_test: w FORCE
	./bin/wv2 lib/format_test.w -o ./bin/format_test
	./bin/format_test

format_64_test: w FORCE
	./bin/wv2 x64 lib/format_test.w -o ./bin/format_64_test
	./bin/format_64_test

time_test: w FORCE
	./bin/wv2 lib/time_test.w -o ./bin/time_test
	./bin/time_test

args_test: w FORCE
	./bin/wv2 lib/args_test.w -o ./bin/args_test
	./bin/args_test

args_64_test: w FORCE
	./bin/wv2 x64 lib/args_test.w -o ./bin/args_64_test
	./bin/args_64_test

path_test: w FORCE
	./bin/wv2 lib/path_test.w -o ./bin/path_test
	./bin/path_test

result_test: w FORCE
	./bin/wv2 lib/result_test.w -o ./bin/result_test
	./bin/result_test

result_64_test: w FORCE
	./bin/wv2 x64 lib/result_test.w -o ./bin/result_64_test
	./bin/result_64_test

# Postfix '?' error propagation on wresult[T]* (docs/error_results.txt):
# runtime behavior plus the compile-error fixtures (arch-independent,
# so only the x86 target runs them).
result_propagate_test: w FORCE
	./bin/wv2 tests/result_propagate_test.w -o ./bin/result_propagate_test
	./bin/result_propagate_test
	! ./bin/wv2 tests/result_propagate_int_operand_error_fixture.w -o ./bin/result_propagate_int_operand_error_fixture 2>./bin/result_propagate_int_operand_error_fixture.stderr
	grep -qF "Could not find a valid primary expression" ./bin/result_propagate_int_operand_error_fixture.stderr
	! ./bin/wv2 tests/result_propagate_return_type_error_fixture.w -o ./bin/result_propagate_return_type_error_fixture 2>./bin/result_propagate_return_type_error_fixture.stderr
	grep -qF "'?' requires the enclosing function to return a wresult[...]*" ./bin/result_propagate_return_type_error_fixture.stderr
	@echo "result propagate test OK"

result_propagate_64_test: w FORCE
	./bin/wv2 x64 tests/result_propagate_test.w -o ./bin/result_propagate_64_test
	./bin/result_propagate_64_test
	@echo "result propagate test x64 OK"

env_test: w FORCE
	./bin/wv2 lib/env_test.w -o ./bin/env_test
	./bin/env_test

env_64_test: w FORCE
	./bin/wv2 x64 lib/env_test.w -o ./bin/env_64_test
	./bin/env_64_test

process_test: w FORCE
	./bin/wv2 lib/process_test.w -o ./bin/process_test
	./bin/process_test

process_64_test: w FORCE
	./bin/wv2 x64 lib/process_test.w -o ./bin/process_64_test
	./bin/process_64_test

stream_test: w FORCE
	./bin/wv2 lib/stream_test.w -o ./bin/stream_test
	./bin/stream_test

stream_64_test: w FORCE
	./bin/wv2 x64 lib/stream_test.w -o ./bin/stream_64_test
	./bin/stream_64_test

file_test: w FORCE
	./bin/wv2 lib/file_test.w -o ./bin/file_test
	./bin/file_test

wdbg: w FORCE
	./bin/wv2 debugger/debugger.w -o ./bin/wdbg

# The in-process debugger: compile fixtures with 'debugger' statements,
# drive the command loop over stdin, and check each command's output.
debug_test: wdbg FORCE
	# basics: trap announcement, registers, location, raw stack, continue
	printf 'r\nl\nc\n' | ./bin/wdbg tests/debug_fixture.w | grep -q "breakpoint hit at eip="
	printf 'r\nc\n' | ./bin/wdbg tests/debug_fixture.w | grep -q "eax: 0x"
	printf 'l\nc\n' | ./bin/wdbg tests/debug_fixture.w | grep -q "debug_fixture.w:9"
	printf 'st\nc\n' | ./bin/wdbg tests/debug_fixture.w | grep -qE "0x[0-9a-f]+: 0x"
	printf 'c\n' | ./bin/wdbg tests/debug_fixture.w | grep -q "after breakpoint"
	printf 'c\n' | ./bin/wdbg tests/debug_fixture.w | grep -q "debuggee main returned 7"
	printf 'c\nc\n' | ./bin/wdbg tests/debug_fixture.w --break_start | grep -q "after breakpoint"
	printf 'q\n' | ./bin/wdbg tests/debug_fixture.w > /dev/null
	# stepping: step, step into a call, next over a call, stepi, finish
	printf 's\nl\nc\n' | ./bin/wdbg tests/debug_fixture.w | grep -q "debug_fixture.w:10"
	printf 's\ns\nl\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "debug_fixture2.w:12"
	printf 'n\nn\nl\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "debug_fixture2.w:22"
	printf 'si\nl\nc\n' | ./bin/wdbg tests/debug_fixture.w | grep -q "debug_fixture.w:10"
	printf 's\ns\ns\nfin\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "value returned = 6"
	printf 's\nl\nc\nc\n' | ./bin/wdbg tests/debug_fixture2.w --break_start | grep -q "debug_fixture2.w:17"
	# breakpoints: by function, file:line, temporary, delete, list
	printf 'b add\nc\np a\nc\nc\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "a = 3"
	printf 'b debug_fixture2.w:22\nc\np y\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "y = 9"
	printf 'tb triple\nc\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "hit breakpoint 1 (temporary)"
	printf 'b add\nd 1\ni b\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "no breakpoints set"
	# inspection: locals, args, globals, strings, backtrace, memory, source
	printf 'p x\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "x = 3"
	printf 'p message\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "hello wdbg"
	printf 'i l\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "message ="
	printf 'i a\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "argc ="
	printf 'p counter\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "counter = 5"
	printf 'b add\nc\nbt\nc\nc\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "#1  triple"
	printf 'x message 1\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -qE "0x[0-9a-f]+: 0x"
	printf 'list\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "int y = triple(x)"
	# frame selection: print/set/info address the selected frame's locals
	printf 'b add\nc\nup\np n\nc\nc\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "n = 3"
	printf 'b add\nc\nf 2\np message\nc\nc\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "hello wdbg"
	printf 'b add\nc\nup\ndown\nc\nc\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "#0  add"
	printf 'b add\nc\nup\nset n 10\nc\nc\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "debuggee main returned 16"
	# expression evaluation (the repl model) and writing variables
	printf 'p add(2, 3)\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "= 5 (0x00000005)"
	printf 'set x 40\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "debuggee main returned 120"
	# locals and args participate in evaluated expressions
	printf 'p x * 2 + counter\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "= 11"
	printf 'b add\nc\np add(a, 39)\nc\nc\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "= 42"
	# software watchpoints: stop on change, list and delete
	printf 'watch counter\nc\nc\nq\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "counter changed: 5 (0x00000005) -> 14"
	printf 'watch counter\nd w 1\ni w\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "no watchpoints set"
	# fatal signals: post-mortem stop, location, and refusal to resume
	printf 'l\nc\n' | ./bin/wdbg tests/segv_fixture.w | grep -q "fatal signal: SIGSEGV"
	printf 'l\nc\n' | ./bin/wdbg tests/segv_fixture.w | grep -q "segv_fixture.w:7"
	printf 'c\n' | ./bin/wdbg tests/segv_fixture.w > /dev/null 2>&1; test $$? -eq 1
	# the compiler driver runs the same debugger via 'w --debug'
	printf 'c\n' | ./bin/wv2 --debug tests/debug_fixture.w | grep -q "after breakpoint"
	@echo "debug test OK"

wdbg_x64: w FORCE
	./bin/wv2 x64 debugger/debugger.w -o ./bin/wdbg64

# The x64 debugger: same in-process model with the 64-bit sigcontext
# reached through runtime signal thunks (SA_SIGINFO + SA_RESTORER) and
# 8-byte stack slots.
debug_test_x64: wdbg_x64 FORCE
	# basics: trap announcement, registers, location, raw stack, continue
	printf 'r\nl\nc\n' | ./bin/wdbg64 tests/debug_fixture.w | grep -q "breakpoint hit at eip="
	printf 'r\nc\n' | ./bin/wdbg64 tests/debug_fixture.w | grep -q "rip: 0x"
	printf 'l\nc\n' | ./bin/wdbg64 tests/debug_fixture.w | grep -q "debug_fixture.w:9"
	printf 'st\nc\n' | ./bin/wdbg64 tests/debug_fixture.w | grep -qE "0x[0-9a-f]+: 0x"
	printf 'c\n' | ./bin/wdbg64 tests/debug_fixture.w | grep -q "after breakpoint"
	printf 'c\n' | ./bin/wdbg64 tests/debug_fixture.w | grep -q "debuggee main returned 7"
	printf 'c\nc\n' | ./bin/wdbg64 tests/debug_fixture.w --break_start | grep -q "after breakpoint"
	printf 'q\n' | ./bin/wdbg64 tests/debug_fixture.w > /dev/null
	# stepping: step, step into a call, next over a call, stepi, finish
	printf 's\nl\nc\n' | ./bin/wdbg64 tests/debug_fixture.w | grep -q "debug_fixture.w:10"
	printf 's\ns\nl\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "debug_fixture2.w:12"
	printf 'n\nn\nl\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "debug_fixture2.w:22"
	printf 'si\nl\nc\n' | ./bin/wdbg64 tests/debug_fixture.w | grep -q "debug_fixture.w:10"
	printf 's\ns\ns\nfin\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "value returned = 6"
	printf 's\nl\nc\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w --break_start | grep -q "debug_fixture2.w:17"
	# breakpoints: by function, file:line, temporary, delete, list
	printf 'b add\nc\np a\nc\nc\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "a = 3"
	printf 'b debug_fixture2.w:22\nc\np y\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "y = 9"
	printf 'tb triple\nc\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "hit breakpoint 1 (temporary)"
	printf 'b add\nd 1\ni b\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "no breakpoints set"
	# inspection: locals, args, globals, strings, backtrace, memory, source
	printf 'p x\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "x = 3"
	printf 'p message\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "hello wdbg"
	printf 'i l\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "message ="
	printf 'i a\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "argc ="
	printf 'p counter\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "counter = 5"
	printf 'b add\nc\nbt\nc\nc\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "#1  triple"
	printf 'x message 1\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -qE "0x[0-9a-f]+: 0x"
	printf 'list\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "int y = triple(x)"
	# frame selection: print/set/info address the selected frame's locals
	printf 'b add\nc\nup\np n\nc\nc\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "n = 3"
	printf 'b add\nc\nf 2\np message\nc\nc\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "hello wdbg"
	printf 'b add\nc\nup\ndown\nc\nc\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "#0  add"
	printf 'b add\nc\nup\nset n 10\nc\nc\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "debuggee main returned 16"
	# expression evaluation (the repl model) and writing variables
	printf 'p add(2, 3)\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "= 5 (0x00000005)"
	printf 'set x 40\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "debuggee main returned 120"
	# locals and args participate in evaluated expressions
	printf 'p x * 2 + counter\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "= 11"
	printf 'b add\nc\np add(a, 39)\nc\nc\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "= 42"
	# software watchpoints: stop on change, list and delete
	printf 'watch counter\nc\nc\nq\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "counter changed: 5 (0x00000005) -> 14"
	printf 'watch counter\nd w 1\ni w\nc\n' | ./bin/wdbg64 tests/debug_fixture2.w | grep -q "no watchpoints set"
	# fatal signals: post-mortem stop, location, and refusal to resume
	printf 'l\nc\n' | ./bin/wdbg64 tests/segv_fixture.w | grep -q "fatal signal: SIGSEGV"
	printf 'l\nc\n' | ./bin/wdbg64 tests/segv_fixture.w | grep -q "segv_fixture.w:7"
	printf 'c\n' | ./bin/wdbg64 tests/segv_fixture.w > /dev/null 2>&1; test $$? -eq 1
	@echo "debug x64 test OK"

tests: build verify lib_test path_test grammar_test list_test type_table_test bignum_test float_literal_test float_test float_reference_test array_slice_string_test string_utf8_test grapheme_test bounds_trap_test range_bounds_trap_test buffer_field_assign_test array_error_test warning_test strict_mode_test check_json_test symbols_test self_host_warning_test int64_x86_error_test struct_test struct_method_test pointer_test range_test type_system_p0_test type_system_error_test type_system_warning_test for_test switch_test compound_assign_test infer_test ternary_test print_builtin_test script_mode_test prelude_test list_methods_test str_test math_test for_container_test template_string_test generator_test defer_test default_args_test varargs_w_test feature_interaction_test feature_combo_test dynamic_var_test generics_test generics_inference_test import_test c_import_test c_preprocessor_test c_import_errno_test c_import_libc_test directory_test multilayer_test threading_test hash_map_test hash_table_test map_set_builtin_test list_builtin_test string_test array_list_test json_test json_codec_test parser_generator_test parser_generator_w_test parser_generator_c_test wtest_map_test mcp_test lsp_test hook_test wexec_test metadata_check metadata_test linked_list_test format_test time_test args_test result_test result_propagate_test env_test process_test stream_test file_test net_test poll_test framing_test event_loop_test task_test task_io_test json_rpc_test net_basic debug_test repl_test dynamic_test float_abi_test varargs_test extern_data_test graphics_math_test graphics_darwin pac_flag_test pac_darwin test hello tests_x64 FORCE


clean:
	rm -f wv2 wv3 wv4 wv5 test test_output.txt grammar_test bin/*
	rm -rf bin/.wexec_cache

w: *.w */*.w
	mkdir -p bin
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2


# sudo apt install radare2
asm_codegen_get_context:
	rasm2 -a x86 -b 32 -C "mov eax,[esp+4]; jmp eax"

FORCE:
