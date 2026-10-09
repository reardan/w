# Input for 'wcoverage changed' in coverage_test: every line is in
# changed_fixture.diff; debug_dump is exempt from the new-code rule.
int never_called():
	return 1


int debug_dump():   # coverage: exempt debug output only
	return 2


int main(int argc, int argv):
	int x = argc
	if (x > 5):
		x = 0
	return x - 1
