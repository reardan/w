

build: w
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2
	./bin/wv2 w.w >./bin/wv3
	chmod +x ./bin/wv3
	./bin/wv3 w.w >./bin/wv4
	chmod +x ./bin/wv4
	./bin/wv4 w.w >./bin/wv5

update:
	./archive.sh
	mv -f ./bin/wv2 ./w

test: w FORCE
	./bin/wv2 test.w >./bin/test
	chmod +x ./bin/test
	./bin/test

test_debug: w FORCE
	./bin/wv2 test.w >./bin/test
	chmod +x ./bin/test
	ddd ./bin/test

testing_ground: w FORCE
	./bin/wv2 testing_ground.w >./bin/testing_ground
	chmod +x ./bin/testing_ground
	./bin/testing_ground arg1 arg2 arg3 -o output -i=input --input=doubledash

asm_test: w FORCE
	./bin/wv2 asm_test.w >./bin/asm_test
	chmod +x ./bin/asm_test
	./bin/asm_test

net_basic: w FORCE
	./bin/wv2 net_basic.w >./bin/net_basic
	chmod +x ./bin/net_basic
	./bin/net_basic

net: w FORCE
	./bin/wv2 net.w >./bin/net
	chmod +x ./bin/net
	./bin/net

pointer_test: w FORCE
	./bin/wv2 pointer_test.w >./bin/pointer_test
	chmod +x ./bin/pointer_test
	./bin/pointer_test

hello: w FORCE
	./bin/wv2 hello.w >./bin/hello
	chmod +x ./bin/hello
	./bin/hello

import_test: w FORCE
	./bin/wv2 import_test.w >./bin/import_test
	chmod +x ./bin/import_test
	./bin/import_test


directory_test: w FORCE
	./bin/wv2 directory_test.w >./bin/directory_test
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
	./bin/wv2 simple.w >./bin/simple
	chmod +x ./bin/simple
	./bin/simple

simple_debug: w FORCE
	./bin/wv2 simple.w >./bin/simple
	chmod +x ./bin/simple
	ddd ./bin/simple

x64_test: w FORCE
	./bin/wv2 x64 x64_test.w >./bin/x64_test
	chmod +x ./bin/x64_test
	./bin/x64_test

x64_test_debug: w FORCE
	./bin/wv2 x64 x64_test.w >./bin/x64_test
	chmod +x ./bin/x64_test
	ddd ./bin/x64_test

elf: w FORCE
	./bin/wv2 elf.w >./bin/elf
	chmod +x ./bin/elf
	./bin/elf

convert: w FORCE
	./bin/wv2 convert.w >./bin/convert
	chmod +x ./bin/convert
	objdump -d ~/git/net/tcp | ./bin/convert

struct_test: w FORCE
	./bin/wv2 struct_test.w >./bin/struct_test
	chmod +x ./bin/struct_test
	./bin/struct_test

struct_test_debug: w FORCE
	./bin/wv2 struct_test.w >./bin/struct_test
	chmod +x ./bin/struct_test
	ddd ./bin/struct_test

range_test: w FORCE
	./bin/wv2 range_test.w >./bin/range_test
	chmod +x ./bin/range_test
	./bin/range_test

range_test_debug: w FORCE
	./bin/wv2 range_test.w >./bin/range_test
	chmod +x ./bin/range_test
	ddd ./bin/range_test

type_table_test: w FORCE
	./bin/wv2 type_table_test.w >./bin/type_table_test
	chmod +x ./bin/type_table_test
	./bin/type_table_test

logging: w FORCE
	./bin/wv2 logging.w >./bin/logging
	chmod +x ./bin/logging
	./bin/logging

threading: w FORCE
	./bin/wv2 threading.w >./bin/threading
	chmod +x ./bin/threading
	./bin/threading

threading_test: w FORCE
	./bin/wv2 threading_test.w >./bin/threading_test
	chmod +x ./bin/threading_test
	./bin/threading_test

threading_test_debug: w FORCE
	./bin/wv2 threading_test.w >./bin/threading_test
	chmod +x ./bin/threading_test
	ddd ./bin/threading_test

whttp: w FORCE
	./bin/wv2 whttp.w >./bin/whttp
	chmod +x ./bin/whttp
	./bin/whttp

tcp: w FORCE
	./bin/wv2 tcp.w >./bin/tcp
	chmod +x ./bin/tcp
	./bin/tcp
#	ddd ./bin/tcp

grammar_test: w FORCE
	./bin/wv2 grammar_test.w >./bin/grammar_test
	chmod +x ./bin/grammar_test
	./bin/grammar_test
#	ddd ./bin/grammar_test

list_test: w FORCE
	./bin/wv2 list_test.w >./bin/list_test
	chmod +x ./bin/list_test
	./bin/list_test

lib_test: w FORCE
	./bin/wv2 lib_test.w >./bin/lib_test
	chmod +x ./bin/lib_test
	./bin/lib_test

lib_64_test: w FORCE
	./bin/wv2 x64 lib_test.w >./bin/lib_test
	chmod +x ./bin/lib_test
	./bin/lib_test

lib_64_test_debug: w FORCE
	./bin/wv2 x64 lib_test.w >./bin/lib_test
	chmod +x ./bin/lib_test
	ddd ./bin/lib_test

repl: FORCE
	./w repl.w >./bin/repl
	chmod +x ./bin/repl
	./bin/repl test.w >./bin/test

for: w FORCE
	./bin/wv2 for_test.w >./bin/for_test
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

tests: build lib_test grammar_test list_test type_table_test FORCE


clean:
	rm -f wv2 wv3 wv4 wv5 test test_output.txt grammar_test bin/*

w: *.w
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2


# sudo apt install radare2
asm_codegen_get_context:
	rasm2 -a x86 -b 32 -C "mov eax,[esp+4]; jmp eax"

FORCE:
