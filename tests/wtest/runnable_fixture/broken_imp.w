# Fixture ROOT for bin/wtest's --runnable-here closure-level needs
# attribution (never executed OR COMPILED; selected through
# tests/wtest/manifest_runnable.json): the second import below does not
# exist, so 'bin/wv2 deps' fails and this root can never have a cached
# closure. The needs scan must fall back to the ROOT text — which
# carries no directives — and keep the target on every host, even
# though the first import (dep_dyn.w) would attribute a dynamic-link
# need if a partial closure were ever used. Deliberately broken:
# 'bin/wv2 check' on this file fails by design, like the other
# compile-error fixtures under tests/.
import tests.wtest.runnable_fixture.dep_dyn
import tests.wtest.runnable_fixture.does_not_exist

int main():
	return dep_dyn_probe()
