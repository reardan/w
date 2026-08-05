# Fixture MODULE for bin/wtest's --runnable-here closure-level needs
# attribution (tools/test_map.w; never executed, reached only through
# tests/wtest/manifest_runnable.json roots): no directives anywhere,
# so a root importing this module must be kept on every host — the
# closure scan must not invent needs.
int dep_plain_value():
	return 7
