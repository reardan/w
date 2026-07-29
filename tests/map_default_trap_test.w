# Trap-contract regression for issue #327: maps built WITHOUT the
# 'new map[K, V](...)' argument list keep the documented missing-key
# trap, even in a program whose other maps opted into defaults — the
# compound-assignment path included. The directives assert the run
# fails with the unchanged trap message.
# wbuild: x64
# wbuild: expect_fail
# wbuild: expect_stderr="map key not found: plain"
# wbuild: expect_stderr="stack trace (most recent call first):"
# wbuild: expect_stderr="at main ("
import lib.lib


int main():
	# a defaulted map vivifies fine in the same program...
	map[char*, int] defaulted = new map[char*, int](0)
	defaulted[c"a"] += 1
	if (defaulted[c"a"] != 1):
		exit(2)
	# ...but a plain map's compound assignment still traps on a
	# missing key, exactly as before the opt-in existed
	map[char*, int] plain = new map[char*, int]
	plain[c"plain"] += 1
	print(c"unreachable")
	return 0
