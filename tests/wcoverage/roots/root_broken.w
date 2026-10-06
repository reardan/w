# wcoverage fixture root that does not compile (an undefined call), so
# it is counted as skipped and covers nothing.
import tests.wcoverage.mods.unused


int main():
	return wcov_fixture_no_such_function()
