build:
	./cc500 <cc500.c >cc500v2
	chmod +x ./cc500v2
	./cc500v2 <cc500.c >cc500v3
	chmod +x ./cc500v3
	./cc500v3 <cc500.c >cc500v4
	chmod +x ./cc500v4
	./cc500v4 <cc500.c >cc500v5

update:
	./archive.sh
	mv -f cc500v2 cc500

test: FORCE
	./cc500 <cc500.c >cc500v2
	chmod +x ./cc500v2
	./cc500v2 <test.w >test
	chmod +x ./test
	./test

old:
	cc cc500.c
	./a.out <cc500.c >cc500
	chmod +x ./cc500

clean:
	rm -f ./a.out ./cc500 ./cc500v2 ./cc500v3


FORCE: