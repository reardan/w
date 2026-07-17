# check_imports_test (build.base.json): the same call as
# transitive_import_warn_fixture.w, but the leaf module is imported
# directly (alongside the middle module), so `w check --imports` must
# stay silent.
import tests.transitive_import_mid
import tests.transitive_import_leaf


int main():
	return transitive_leaf_value()
