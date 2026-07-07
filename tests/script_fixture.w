# Script mode: no main() boilerplate; declarations (imports, functions,
# structs) may appear before the first top-level statement.
import lib.math


int sf_square(int x):
	return x * x


total := 0
for int i in range(6):
	if i % 2 == 0:
		total += sf_square(i)
println(total)
best := max(total, 19)
println(best ? c"nonzero" : c"zero")
values := list[int]{4, 1, 3}
values.sort()
println(values)
defer println(c"deferred ran last")
println(f"total={total}")
