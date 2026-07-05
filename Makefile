

# The seed stage stays flagless (the committed seed may predate --strict);
# the self-host stages compile with warnings as errors so unsafe type
# mismatches fail the build.
build: w
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

# x86-only: structures/array_list.w does not pass on x64 yet (word-size
# assumptions), matching array_list_test being absent from tests_x64.
event_loop_test: w FORCE
	./bin/wv2 lib/event_loop_test.w -o ./bin/event_loop_test
	./bin/event_loop_test

# x86-only: the structures/ containers behind json.w do not pass on x64 yet
# (see hash_map_test/string_test being absent from tests_x64).
json_rpc_test: w FORCE
	./bin/wv2 lib/json_rpc_test.w -o ./bin/json_rpc_test
	./bin/json_rpc_test
	./bin/wv2 examples/web/json_rpc_server.w -o ./bin/json_rpc_server

pointer_test: w FORCE
	./bin/wv2 tests/pointer_test.w >./bin/pointer_test
	chmod +x ./bin/pointer_test
	./bin/pointer_test

hello: w FORCE
	./bin/wv2 tests/hello.w >./bin/hello
	chmod +x ./bin/hello
	./bin/hello

import_test: w FORCE
	./bin/wv2 tests/import_test.w >./bin/import_test
	chmod +x ./bin/import_test
	./bin/import_test

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

tests_x64: verify_x64 lib_64_test path_64_test time_64_test result_64_test env_64_test process_64_test stream_64_test array_slice_string_64_test x64_test x64_float_test x64_int64_test net_64_test poll_64_test framing_64_test dynamic_test_x64 c_import_libc_test_x64 FORCE

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
	grep -qF '"file": "/workspace/tests/warning_fixture.w"' ./bin/check_json_warning.ndjson
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
	# Built-in container declarations work at the prompt (the runtime is
	# not auto-imported into the REPL's buffer, so import it first)
	printf 'import structures.w_list\nlist[int] l = list[int]{40, 2}\nl[0] + l[1]\n:quit\n' | ./bin/repl | grep -q "42"
	printf 'import structures.hash_table\nmap[char*, int] m = new map[char*, int]\nm[c"a"] = 41\nm[c"a"] + 1\n:quit\n' | ./bin/repl | grep -q "42"
	printf 'import structures.string\nstring_builder* s = string_from(c"imported")\ns.data\n:quit\n' | ./bin/repl | grep -q "imported"
	# Errors inside multi-line entries and failed imports both recover
	printf 'int bad():\n\treturn qq\n\nprint(c"recovered fn\\x0a")\n:quit\n' | ./bin/repl | grep -q "recovered fn"
	printf 'import no.such.module\nprint(c"recovered import\\x0a")\n:quit\n' | ./bin/repl 2>/dev/null | grep -q "recovered import"
	# Run a file, then attach the prompt to its live definitions
	printf ':quit\n' | ./bin/repl tests/repl_fixture.w | grep -q "fixture main ran"
	printf 'fixture_helper(21)\nfixture_global\n:quit\n' | ./bin/repl tests/repl_fixture.w | grep -q "42"
	printf 'fixture_global\n:quit\n' | ./bin/repl tests/repl_fixture.w | grep -q "11"
	! printf ':quit\n' | ./bin/repl tests/repl_fixture.w --no_main | grep -q "fixture main ran"
	@echo "repl test OK"

for_test: w FORCE
	./bin/wv2 tests/for_test.w >./bin/for_test
	chmod +x ./bin/for_test
	./bin/for_test

# Cursor-protocol iteration: for x in <container>
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

hash_table_test: w FORCE
	./bin/wv2 structures/hash_table_test.w -o ./bin/hash_table_test
	./bin/hash_table_test

map_set_builtin_test: w FORCE
	./bin/wv2 tests/map_set_builtin_test.w -o ./bin/map_set_builtin_test
	./bin/map_set_builtin_test
	! ./bin/wv2 tests/map_value_array_error_fixture.w -o ./bin/map_value_array_error_fixture 2>./bin/map_value_array_error_fixture.stderr
	grep -qF "map value type cannot be a fixed-size array" ./bin/map_value_array_error_fixture.stderr

# Built-in typed list[T]: literals, indexing, push/pop, length, iteration
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

string_test: w FORCE
	./bin/wv2 structures/string_test.w -o ./bin/string_test
	./bin/string_test

array_list_test: w FORCE
	./bin/wv2 structures/array_list_test.w -o ./bin/array_list_test
	./bin/array_list_test

json_test: w FORCE
	./bin/wv2 structures/json_test.w -o ./bin/json_test
	./bin/json_test

# to_json/from_json builtin round trips (x86 only: structures/json.w and
# the container runtimes it uses have pre-existing x64 issues, matching
# json_test)
json_codec_test: w FORCE
	./bin/wv2 tests/json_codec_test.w -o ./bin/json_codec_test
	./bin/json_codec_test

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
	./bin/wv2 tools/test_map.w -o ./bin/wtest

test_changed: wtest FORCE
	git diff --name-only HEAD | ./bin/wtest changed | xargs -r $(MAKE)

wtest_map_test: wtest FORCE
	printf 'grammar/promote.w\n' | ./bin/wtest changed > ./bin/wtest_map.out
	printf 'verify\nself_host_warning_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed structures/json.w > ./bin/wtest_map.out
	printf 'json_test\njson_codec_test\njson_rpc_test\n' > ./bin/wtest_map.expected
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
	./bin/wtest changed tools/wexec.w tests/wexec/good.json > ./bin/wtest_map.out
	printf 'wexec_test\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	./bin/wtest changed build.json > ./bin/wtest_map.out
	printf 'wexec_test\ntests\n' > ./bin/wtest_map.expected
	diff -u ./bin/wtest_map.expected ./bin/wtest_map.out
	@echo "wtest map test OK"

rewrite_c_strings: w FORCE
	./bin/wv2 tools/rewrite_c_string_literals.w -o ./bin/rewrite_c_strings

grapheme_data: w FORCE
	./bin/wv2 tools/generate_grapheme_data.w -o ./bin/generate_grapheme_data
	./bin/generate_grapheme_data

wmcp: w FORCE
	./bin/wv2 tools/mcp/w_toolchain_mcp.w -o ./bin/wmcp

mcp_test: wmcp FORCE
	./bin/wv2 tools/mcp/mcp_test.w -o ./bin/mcp_test
	./bin/mcp_test

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
	# no requested target: usage plus the target list, nonzero exit
	! ./bin/wexec -f tests/wexec/good.json > ./bin/wexec_noarg.out 2>./bin/wexec_noarg.stderr
	grep -q "usage: wexec" ./bin/wexec_noarg.stderr
	grep -q "main" ./bin/wexec_noarg.out
	# the real manifest: build and run a program end to end
	./bin/wexec hello | grep -q "hello, world!"
	@echo "wexec test OK"

linked_list_test: w FORCE
	./bin/wv2 structures/linked_list_test.w -o ./bin/linked_list_test
	./bin/linked_list_test

format_test: w FORCE
	./bin/wv2 lib/format_test.w -o ./bin/format_test
	./bin/format_test

time_test: w FORCE
	./bin/wv2 lib/time_test.w -o ./bin/time_test
	./bin/time_test

args_test: w FORCE
	./bin/wv2 lib/args_test.w -o ./bin/args_test
	./bin/args_test

path_test: w FORCE
	./bin/wv2 lib/path_test.w -o ./bin/path_test
	./bin/path_test

result_test: w FORCE
	./bin/wv2 lib/result_test.w -o ./bin/result_test
	./bin/result_test

result_64_test: w FORCE
	./bin/wv2 x64 lib/result_test.w -o ./bin/result_64_test
	./bin/result_64_test

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
	# expression evaluation (the repl model) and writing variables
	printf 'p add(2, 3)\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "= 5 (0x00000005)"
	printf 'set x 40\nc\n' | ./bin/wdbg tests/debug_fixture2.w | grep -q "debuggee main returned 120"
	# fatal signals: post-mortem stop, location, and refusal to resume
	printf 'l\nc\n' | ./bin/wdbg tests/segv_fixture.w | grep -q "fatal signal: SIGSEGV"
	printf 'l\nc\n' | ./bin/wdbg tests/segv_fixture.w | grep -q "segv_fixture.w:7"
	printf 'c\n' | ./bin/wdbg tests/segv_fixture.w > /dev/null 2>&1; test $$? -eq 1
	# the compiler driver runs the same debugger via 'w --debug'
	printf 'c\n' | ./bin/wv2 --debug tests/debug_fixture.w | grep -q "after breakpoint"
	@echo "debug test OK"

tests: build verify lib_test path_test grammar_test list_test type_table_test bignum_test float_literal_test float_test float_reference_test array_slice_string_test string_utf8_test grapheme_test bounds_trap_test range_bounds_trap_test buffer_field_assign_test array_error_test warning_test strict_mode_test check_json_test symbols_test self_host_warning_test int64_x86_error_test struct_test struct_method_test pointer_test range_test type_system_p0_test type_system_error_test type_system_warning_test for_test for_container_test import_test c_import_test c_preprocessor_test c_import_errno_test c_import_libc_test directory_test multilayer_test threading_test hash_map_test hash_table_test map_set_builtin_test list_builtin_test string_test array_list_test json_test json_codec_test parser_generator_test parser_generator_w_test parser_generator_c_test wtest_map_test mcp_test wexec_test linked_list_test format_test time_test args_test result_test env_test process_test stream_test file_test net_test poll_test framing_test event_loop_test json_rpc_test net_basic debug_test repl_test dynamic_test test hello tests_x64 FORCE


clean:
	rm -f wv2 wv3 wv4 wv5 test test_output.txt grammar_test bin/*

w: *.w */*.w
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2


# sudo apt install radare2
asm_codegen_get_context:
	rasm2 -a x86 -b 32 -C "mov eax,[esp+4]; jmp eax"

FORCE:
