build:
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

test: FORCE
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2
	./bin/wv2 test.w >./bin/test
	chmod +x ./bin/test
	./bin/test arg1 arg2 arg3 -o output -i=input --input=doubledash

simple: FORCE
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2
	./bin/wv2 simple.w >./bin/simple
	chmod +x ./bin/simple
	./bin/simple

struct_test: FORCE
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2
	./bin/wv2 struct_test.w >./bin/struct_test
	chmod +x ./bin/struct_test
	./bin/struct_test

type_table_test: FORCE
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2
	./bin/wv2 type_table_test.w >./bin/type_table_test
	chmod +x ./bin/type_table_test
	./bin/type_table_test

grammar: FORCE
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2
	./bin/wv2 grammar_test.w >./bin/grammar_test
	chmod +x ./bin/grammar_test
	ddd ./bin/grammar_test

list_test: FORCE
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2
	./bin/wv2 list_test.w >./bin/list_test
	chmod +x ./bin/list_test
	./bin/list_test

repl: FORCE
	./w repl.w >./bin/repl
	chmod +x ./bin/repl
	./bin/repl test.w >./bin/test

range: FORCE
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2
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

tests: FORCE
	./w w.w >./bin/wv2
	chmod +x ./bin/wv2

	./bin/wv2 lib_test.w >./bin/lib_test
	chmod +x ./bin/lib_test
	./bin/lib_test

	./bin/wv2 grammar_test.w >./bin/grammar_test
	chmod +x ./bin/grammar_test
	./bin/grammar_test

	./bin/wv2 list_test.w >./bin/list_test
	chmod +x ./bin/list_test
	./bin/list_test

clean:
	rm -f wv2 wv3 wv4 wv5 test test_output.txt grammar_test bin/*


FORCE: