# enumerate binds index and element, and W has no tuples for a
# one-variable form to bind (issue #360).
# expect_fail
# expect_stderr: enumerate requires two loop variables: for i, x in enumerate(l)
l := list[int]{1, 2}
for x in enumerate(l):
	println(x)
