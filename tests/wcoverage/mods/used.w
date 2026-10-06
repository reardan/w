# wcoverage fixture: imported by roots/root_a.w.
import tests.wcoverage.mods.used_by_used


int wcov_fixture_used():
	return wcov_fixture_used_by_used() + 1
