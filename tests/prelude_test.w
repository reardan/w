# The prelude input helpers, driven by piped stdin (declared by the
# directives below): input() takes the first line, ints() scans every
# integer out of the rest, read_all() drains what remains.
# wbuild: stdin="header line\n1 2 3\n-4 and x5\n"
# wbuild: expect_stdout="header line" expect_stdout="[1, 2, 3, -4, 5]"
# wbuild: expect_stdout="7" expect_stdout="leftover:"
header := input()
println(header)
nums := ints()
println(nums)
println(nums.sum())
leftover := read_all()
print(c"leftover:")
println(leftover)
