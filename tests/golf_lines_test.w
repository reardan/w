# Golf ergonomics wave 5: lines(), whitespace split(s), l.reversed()
# and join -- reverse the words of every line, import-free.
# wbuild: x64
# wbuild: stdin="hello big world\n  a   b  \n\nlast\n"
# wbuild: expect_stdout="world big hello" expect_stdout="b a" expect_stdout="last"
# wbuild: expect_stdout="pieces:[a, , b]" expect_stdout="joined:x|y|z" expect_stdout="4 lines"
text := lines()
for l in text: println(join(split(l).reversed(), " "))
print(c"pieces:")
println(split(c"a,,b", ','))
print(c"joined:")
println(join(split("  x\ty z "), "|"))
println(f"{text.length} lines")
