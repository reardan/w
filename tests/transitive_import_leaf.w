# Leaf module for check_imports_test (build.base.json): defines a symbol
# that tests/transitive_import_mid.w re-exports by plain import, and that
# tests/transitive_import_warn_fixture.w / _clean_fixture.w use without
# and with (respectively) importing this module directly.
int transitive_leaf_value():
	return 42
