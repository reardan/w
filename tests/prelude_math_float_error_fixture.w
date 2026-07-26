# Prelude max/min/abs are int-only (issue #360): floats must import
# lib.math or spell the comparison out.
# expect_fail
# expect_stderr: prelude 'max' argument must be an int-like value: 'float32 value'
x := max(1.5, 2.0)
println(x)
