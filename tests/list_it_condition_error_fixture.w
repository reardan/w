# filter/count/any/all/index test the expression's truthiness, so it
# must be an int-like or pointer value.
# wbuild: fixture_group=list_it_error_test
# expect_fail
# expect_stderr: list filter condition must be an int-like or pointer value, got 'string value'
l := list[int]{1, 2}
println(l.filter(f"{it}").length)
