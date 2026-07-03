

build: w
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2
	./bin/wv2 w.w -o ./bin/wv3
	./bin/wv3 w.w -o ./bin/wv4
	./bin/wv4 w.w -o ./bin/wv5

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

tests_x64: verify_x64 lib_64_test path_64_test time_64_test result_64_test x64_test x64_float_test net_64_test dynamic_test_x64 FORCE

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
	grep -qF "warning: line indented with spaces instead of tabs" ./bin/warning_fixture.stderr
	grep -qF "warning: file does not end with a newline" ./bin/warning_fixture.stderr
	./bin/wv2 tests/warning_clean_fixture.w -o ./bin/warning_clean_fixture 2>./bin/warning_clean_fixture.stderr
	! grep -q "warning:" ./bin/warning_clean_fixture.stderr
	@echo "warning test OK"

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

lib_64_test_debug: w FORCE
	./bin/wv2 x64 lib/lib_test.w >./bin/lib_test
	chmod +x ./bin/lib_test
	ddd ./bin/lib_test

repl: w FORCE
	./bin/wv2 repl.w -o ./bin/repl
	./bin/repl

repl_test: w FORCE
	./bin/wv2 repl.w -o ./bin/repl
	printf 'print("hello from the repl\\x0a")\n:quit\n' | ./bin/repl | grep -q "hello from the repl"
	# A bad entry must not kill the process, and later entries must still work
	printf 'this is not valid w\nprint("recovered\\x0a")\n:quit\n' | ./bin/repl | grep -q "recovered"
	printf 'int x = = 3\nqq + 1\nprint("second recovery\\x0a")\n:quit\n' | ./bin/repl | grep -q "second recovery"
	# Multi-line function definitions persist and are callable
	printf 'int add(int a, int b):\n\treturn a + b\n\nadd(40, 2)\n:quit\n' | ./bin/repl | grep -q "42"
	# Interactive (pty) sessions auto-indent block bodies: no tabs typed here
	printf 'int fib(int n):\nif (n < 2):\nreturn n\nreturn fib(n - 1) + fib(n - 2)\n\nfib(10)\n:quit\n' | script -qc './bin/repl' /dev/null | grep -q "55"
	# Top-level variables persist between entries; bare expressions echo
	printf 'int x = 5\nx + 1\n:quit\n' | ./bin/repl | grep -q "6"
	# Redefinition shadows (Python-style rebinding); assignments stay silent
	printf 'int x = 5\nchar* x = "shadowed"\nx\n:quit\n' | ./bin/repl | grep -q "shadowed"
	! printf 'int y = 3\ny = 9\n:quit\n' | ./bin/repl | grep -q "9"
	# Structs, new and imports work at the prompt
	printf 'struct pt:\n\tint x\n\tint y\n\npt* p = new pt(3, 4)\np.x + p.y\n:quit\n' | ./bin/repl | grep -q "7"
	printf 'import structures.string\nstring* s = string_from("imported")\ns.data\n:quit\n' | ./bin/repl | grep -q "imported"
	# Errors inside multi-line entries and failed imports both recover
	printf 'int bad():\n\treturn qq\n\nprint("recovered fn\\x0a")\n:quit\n' | ./bin/repl | grep -q "recovered fn"
	printf 'import no.such.module\nprint("recovered import\\x0a")\n:quit\n' | ./bin/repl 2>/dev/null | grep -q "recovered import"
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

string_test: w FORCE
	./bin/wv2 structures/string_test.w -o ./bin/string_test
	./bin/string_test

array_list_test: w FORCE
	./bin/wv2 structures/array_list_test.w -o ./bin/array_list_test
	./bin/array_list_test

json_test: w FORCE
	./bin/wv2 structures/json_test.w -o ./bin/json_test
	./bin/json_test

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

tests: build verify lib_test path_test grammar_test list_test type_table_test bignum_test float_literal_test float_test float_reference_test warning_test struct_test struct_method_test pointer_test range_test type_system_p0_test for_test import_test directory_test multilayer_test threading_test hash_map_test string_test array_list_test json_test linked_list_test format_test time_test args_test result_test net_test net_basic debug_test repl_test dynamic_test test hello tests_x64 FORCE


clean:
	rm -f wv2 wv3 wv4 wv5 test test_output.txt grammar_test bin/*

w: *.w */*.w
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2


# sudo apt install radare2
asm_codegen_get_context:
	rasm2 -a x86 -b 32 -C "mov eax,[esp+4]; jmp eax"

FORCE:
