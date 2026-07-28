# wbuild: expect_stdout="greeting str via f"
# wbuild: expect_stdout="1.250000"
# wbuild: expect_stdout="[5, -1, 12]"
# wbuild: expect_stdout="[one, two]"
# wbuild: expect_stdout="[]"
# wbuild: expect_stdout="big"
# wbuild: expect_stdout="char:ww" expect_stdout="int:120"
# wbuild: expect_stdout="idx:A" expect_stdout="byte:65" expect_stdout="97"
# Exercises the polymorphic print/println builtin: the target compares
# this program's stdout against the expected lines.
import lib.lib


int pbt_answer():
	return 42


int main(int argc, int argv):
	println(7)
	println(-3)
	print(1)
	print(2)
	println()
	println(c"cstr")
	println(s"strdesc")
	string name = s"str via f"
	println(f"greeting {name}")
	println('a')
	println(true)
	println(1.25)
	println(pbt_answer())
	int x = 9
	println(x > 5 ? c"big" : c"small")
	list[int] numbers = list[int]{5, -1, 12}
	println(numbers)
	list[char*] words = list[char*]{c"one", c"two"}
	println(words)
	list[int] empty = new list[int]
	println(empty)
	var v = 123
	println(v)
	# char-typed values render as characters; character literals are
	# untyped constants ('a' above prints 97) and char arithmetic
	# yields int, so both keep the numeric rendering
	char letter = 'w'
	print(c"char:")
	print(letter)
	println(letter)
	print(c"int:")
	println(letter + 1)
	string word = s"Az"
	print(c"idx:")
	println(word[0])
	# byte is a distinct 1-byte type and stays numeric
	byte raw = 65
	print(c"byte:")
	println(raw)
	return 0
