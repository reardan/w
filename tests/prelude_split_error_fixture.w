# Prelude split/join (golf ergonomics wave 5) take C strings or UTF-8
# strings; lists must hold char* or string pieces.
# wbuild: fixture_group=prelude_math_error_test
# expect_fail
# expect_stderr: prelude 'join' argument must be a list of char* or string: 'list[int]'
println(join(list[int]{1, 2}, ","))
