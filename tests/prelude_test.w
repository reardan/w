# The prelude input helpers, driven by piped stdin (see the Makefile /
# build.json target): input() takes the first line, ints() scans every
# integer out of the rest, read_all() drains what remains.
header := input()
println(header)
nums := ints()
println(nums)
println(nums.sum())
leftover := read_all()
print(c"leftover:")
println(leftover)
