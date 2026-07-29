# Prelude any/all elements must be int-like (issue #360): floats have
# no built-in truthiness here.
# expect_fail
# expect_stderr: prelude 'all' argument must be a list of int-like elements: 'list[float32]'
l := list[float32]{1.5}
x := all(l)
println(x)
