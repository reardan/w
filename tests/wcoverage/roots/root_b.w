# wcoverage fixture root: names mods/harness_direct.w in its own import
# line, so that harness module counts as covered.
import tests.wcoverage.harness
import tests.wcoverage.mods.harness_direct


int main():
	return wcov_fixture_harness_direct() - 7
