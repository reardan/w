# Lists are the only enumerable shape (issue #360): maps and sets
# iterate their keys directly.
# expect_fail
# expect_stderr: enumerate requires a list, got 'set[int]'
s := set[int]{1, 2}
for i, x in enumerate(s):
	println(x)
