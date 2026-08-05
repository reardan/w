# Fixture ROOT for bin/wtest's --runnable-here closure-level needs
# attribution (never executed; selected through
# tests/wtest/manifest_runnable.json): dynamically linked only through
# its import — dep_dyn.w carries the c_lib directive, nothing here
# does — so a root-only scan misses the need entirely.
import tests.wtest.runnable_fixture.dep_dyn

int main():
	return dep_dyn_probe()
