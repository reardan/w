# len() reads a length: containers, buffers and char* qualify; a bare
# int does not (issue #360).
# expect_fail
# expect_stderr: unsupported len argument type: 'int'
n := 5
println(len(n))
