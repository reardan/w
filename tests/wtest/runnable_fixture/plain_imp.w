# Fixture ROOT for bin/wtest's --runnable-here closure-level needs
# attribution (never executed; selected through
# tests/wtest/manifest_runnable.json): a clean import chain — no
# directive anywhere in the closure — so the filter must keep the
# target on every host.
import tests.wtest.runnable_fixture.dep_plain

int main():
	return dep_plain_value()
