# Golf ergonomics wave 5: it-expressions chain straight off the prelude
# stdin helpers (sum of the squares of the even inputs).
# wbuild: x64
# wbuild: stdin="1 2 3\n4 5 6\n"
# wbuild: expect_stdout="56"
println(ints().filter(it % 2 == 0).map(it * it).sum())
