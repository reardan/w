# wcoverage fixture: stands in for lib/testing.w (--harness). Every
# root imports it, so its closure must not count as covered.
import tests.wcoverage.mods.harness_only
import tests.wcoverage.mods.harness_direct


int wcov_fixture_harness():
	return wcov_fixture_harness_only() + wcov_fixture_harness_direct()
