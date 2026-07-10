# Fixture for deps_test: a tiny program with one explicit import. The
# expected 'bin/wv2 deps' output pinned in build.json covers the root
# file, the explicitly imported module, and the auto-imported container
# runtime modules every program receives.
import lib.lib
import lib.assert


int main():
	assert1(1)
	return 0
