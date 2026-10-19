# wbuild: step="bin/wv2 repl.w -o bin/repl_generic_iter"
# A REPL session over a generic container: the first for-in loop interns
# and compiles the '<base>_iter_*[T]' instantiations; the second loop
# resolves them through the symbol table instead (grammar/for_statement.w
# for_iter_generic_require's already-compiled path and
# for_iter_generic_value_type's instantiated-symbol branch), which only
# sessions with persistent symbols can reach. Blank lines close blocks.
# wbuild: step="bin/repl_generic_iter" stdin="struct box2[T]:\n\tT item\n\tint mark\n\nint box2_iter_begin[T](box2[T]* c):\n\treturn 0\n\nint box2_iter_done[T](box2[T]* c, int cursor):\n\treturn cursor >= 1\n\nT box2_iter_next[T](box2[T]* c, int cursor):\n\tc.mark = cursor\n\treturn c.item\n\nT box2_iter_value[T](box2[T]* c, int cursor):\n\treturn c.item\n\nbox2[int]* b = cast(box2[int]*, malloc(8))\nb.item = 41\nb.mark = 0\n\nfor x in b:\n\tprintln(x)\n\nfor y in b:\n\tprintln(y + 1)\n\n:quit\n" expect_stdout="41" expect_stdout="42"
/*
repl_generic_iter_test: generic container iteration inside one REPL
session. A compiled program's for-in loops always intern their
instantiations during the same compile, so the already-compiled branch
is unreachable there; the REPL's persistent symbol table takes it on
every repeat. The session also exercises multi-line block entries
(struct and generic function definitions) in a piped session.
*/
import lib.lib

# The steps above are the test; the program body only has to exist so
# the target's compile step succeeds.
int main():
	return 0

