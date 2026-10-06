# wcoverage fixture: in the harness closure, but roots/root_b.w also
# imports it by name, so it counts as covered.
int wcov_fixture_harness_direct():
	return 7
