build:
	./w w.w >wv2
	chmod +x ./wv2
	./wv2 w.w >wv3
	chmod +x ./wv3
	./wv3 w.w >wv4
	chmod +x ./wv4
	./wv4 w.w >wv5

update:
	./archive.sh
	mv -f wv2 w

test: FORCE
	./w w.w >wv2
	chmod +x ./wv2
	./wv2 test.w >test
	chmod +x ./test
	./test arg1 arg2 arg3 -o output -i=input --input=doubledash

range: FORCE
	./w w.w >wv2
	chmod +x ./wv2
	./wv2 range_test.w >range_test
	chmod +x ./range_test
	./range_test

test1: FORCE
	./w test.w >test
	chmod +x ./test
	./test arg1 arg2 arg3 -o output -i=input --input=doubledash

debug: FORCE
	./w test.w >test
	chmod +x ./test
	gdb -ex run --args test arg1 arg2 arg3

tests: FORCE
	./w w.w >wv2
	chmod +x ./wv2
	./wv2 grammar_test.w >grammar_test
	chmod +x ./grammar_test
	./grammar_test arg1 arg2 arg3 -o output -i=input --input=doubledash


old:
	cc w.w
	./a.out <w.w >w
	chmod +x ./w

clean:
	rm -f ./wv2 ./wv3 ./wv4 ./wv5 ./test ./test_output.txt ./grammar_test


FORCE: