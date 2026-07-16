# Map/set elements are out of scope for '++'/'--' v1 (the pending
# map/key slots need their own read/write emission,
# grammar/hash_builtin.w); spell it 'm[k] += 1'. See
# docs/projects/increment_decrement.md.
# expect_fail
# expect_stderr: '++' and '--' are not supported on map or set elements
int main():
	map[int, int] m = new map[int, int]
	m[1] = 2
	m[1]++
	return 0
