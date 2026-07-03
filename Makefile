

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

tests_x64: verify_x64 lib_64_test x64_test dynamic_test_x64 FORCE

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

struct_test_debug: w FORCE
	./bin/wv2 tests/struct_test.w >./bin/struct_test
	chmod +x ./bin/struct_test
	ddd ./bin/struct_test

range_test: w FORCE
	./bin/wv2 tests/range_test.w >./bin/range_test
	chmod +x ./bin/range_test
	./bin/range_test

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
	# A bad line must not kill the process, and later lines must still work
	printf 'this is not valid w\nprint("recovered\\x0a")\n:quit\n' | ./bin/repl | grep -q "recovered"
	printf 'print("no closing paren"\nint x = = 3\nprint("second recovery\\x0a")\n:quit\n' | ./bin/repl | grep -q "second recovery"
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

args_test: w FORCE
	./bin/wv2 lib/args_test.w -o ./bin/args_test
	./bin/args_test

wdbg: w FORCE
	./bin/wv2 debugger/debugger.w -o ./bin/wdbg

# The in-process debugger: compile a fixture with a 'debugger' statement,
# drive the command loop over stdin, and check each command's output.
debug_test: wdbg FORCE
	printf 'r\nl\nc\n' | ./bin/wdbg tests/debug_fixture.w | grep -q "breakpoint hit at eip="
	printf 'r\nc\n' | ./bin/wdbg tests/debug_fixture.w | grep -q "eax: 0x"
	printf 'l\nc\n' | ./bin/wdbg tests/debug_fixture.w | grep -q "debug_fixture.w:9"
	printf 's\nc\n' | ./bin/wdbg tests/debug_fixture.w | grep -qE "0x[0-9a-f]+: 0x"
	printf 'c\n' | ./bin/wdbg tests/debug_fixture.w | grep -q "after breakpoint"
	printf 'c\n' | ./bin/wdbg tests/debug_fixture.w | grep -q "debuggee main returned 7"
	printf 'c\nc\n' | ./bin/wdbg tests/debug_fixture.w --break_start | grep -q "after breakpoint"
	printf 'q\n' | ./bin/wdbg tests/debug_fixture.w > /dev/null
	@echo "debug test OK"

tests: build verify lib_test grammar_test list_test type_table_test warning_test struct_test pointer_test range_test for_test import_test directory_test multilayer_test threading_test hash_map_test string_test array_list_test json_test linked_list_test format_test args_test debug_test dynamic_test test hello tests_x64 FORCE


clean:
	rm -f wv2 wv3 wv4 wv5 test test_output.txt grammar_test bin/*

w: *.w */*.w
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2


# sudo apt install radare2
asm_codegen_get_context:
	rasm2 -a x86 -b 32 -C "mov eax,[esp+4]; jmp eax"

FORCE:
