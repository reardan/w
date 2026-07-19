# Synthetic fixture for wtest_archs_test (tools/test_map.w): a tiny
# multi-arch consumer whose __arch__ dependency has no win64
# implementation, modeling the tools/wexec.w sys_socket incident
# (docs/projects/ai_tooling_next_steps.md) at a scale cheap enough to
# run in every test suite. Compiles clean for the default (x86) and
# arm64_darwin selectors; win64 fails to resolve the import.
import tests.wtest.archs_fixture.thinglib.__arch__.thing

void main():
	int v = archs_fixture_thing_value()
	if (v == 42):
		println(c"archs_fixture: ok")
	else:
		println(c"archs_fixture: mismatch")
