# Runtime trap input: a list slice whose normalized start exceeds its end
# must trap reporting the normalized pair (issue #360; the limit is the
# end bound, matching the buffer range check convention). Asserted by
# container_trap_test.
void main():
	list[int] l = list[int]{1, 2, 3}
	list[int] s = l[2:1]
	print(s.length)
