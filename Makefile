build:
	./cc500 cc500.c >cc500v2
	chmod +x ./cc500v2
	./cc500v2 cc500.c >cc500v3
	chmod +x ./cc500v3
	./cc500v3 cc500.c >cc500v4
	chmod +x ./cc500v4
	./cc500v4 cc500.c >cc500v5

update:
	./archive.sh
	mv -f cc500v2 cc500

test: FORCE
	./cc500 cc500.c >cc500v2
	chmod +x ./cc500v2
	./cc500v2 test.w >test
	chmod +x ./test
	./test arg1 arg2 arg3 -o output -i=input --input=doubledash

tester: FORCE
	./cc500 <cc500.c >cc500v2
	chmod +x ./cc500v2
	./cc500v2 cc500.c >cc500v3
	chmod +x ./cc500v3
	./cc500v3 test.w >test
	chmod +x ./test
	./test arg1 arg2 arg3 <test_output.txt

old:
	cc cc500.c
	./a.out <cc500.c >cc500
	chmod +x ./cc500

clean:
	rm -f ./cc500v2 ./cc500v3 ./cc500v4 ./cc500v5 ./test ./test_output.txt


FORCE: