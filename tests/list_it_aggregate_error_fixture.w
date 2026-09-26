# it-expression sum/min/max aggregate int-like values only, like the
# no-argument forms.
# wbuild: fixture_group=list_it_error_test
# expect_fail
# expect_stderr: list sum requires int-like elements
l := list[int]{1, 2}
println(l.sum(it > 1 ? c"a" : c"b"))
