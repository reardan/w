# Prelude any/all take one list of int-like elements (issue #360): a
# bare int constant is not a sequence.
# expect_fail
# expect_stderr: prelude 'any' argument must be a list of int-like elements: 'constant'
x := any(5)
println(x)
