# wcoverage fixture root: covers mods/used.w and, through it,
# mods/used_by_used.w.
import tests.wcoverage.harness
import tests.wcoverage.mods.used


int main():
	return wcov_fixture_used() + wcov_fixture_harness() - 15
