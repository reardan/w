# sorted has the same element rules as sort (issue #360): floats have
# no built-in ordering — lib/stats.w's stats_sorted covers float lists.
# expect_fail
# expect_stderr: list sorted requires int-like or char* elements, got 'float32'
l := list[float32]{1.5, 0.5}
s := l.sorted()
println(len(s))
