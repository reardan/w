# The prelude input helpers, driven by piped stdin (declared by the
# directives below): input() takes the first line as a UTF-8 string,
# ints() scans every integer out of the rest, read_all() drains what
# remains, and input() at EOF returns 0 (a null descriptor).
# wbuild: stdin="header line\n1 2 3\n-4 and x5\n"
# wbuild: expect_stdout="header line" expect_stdout="[1, 2, 3, -4, 5]"
# wbuild: expect_stdout="7" expect_stdout="leftover:"
# wbuild: expect_stdout="len:11" expect_stdout="first:h" expect_stdout="eof reached"
header := input()
println(header)
print(c"len:")
println(len(header))
print(c"first:")
println(header[0])
nums := ints()
println(nums)
println(nums.sum())
leftover := read_all()
print(c"leftover:")
println(leftover)
more := input()
println(more ? c"more input" : c"eof reached")
