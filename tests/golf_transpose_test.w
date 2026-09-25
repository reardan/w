# Golf ergonomics wave 5: a matrix read with lines().map(split(it)) and
# transposed with a nested it-expression.
# wbuild: x64
# wbuild: stdin="1 2 3\n4 5 6\n"
# wbuild: expect_stdout="1 4" expect_stdout="2 5" expect_stdout="3 6" expect_stdout="words:6"
m := lines().map(split(it))
for c in range(m[0].length): println(join(m.map(it[c]), " "))
println(f"words:{m.map(it.length).sum()}")
