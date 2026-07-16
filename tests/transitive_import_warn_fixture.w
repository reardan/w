# check_imports_test (build.base.json): imports only the middle module
# and calls a symbol that is actually declared in the leaf module,
# resolved through transitive_import_mid's plain import. `w check
# --imports` must warn once; a plain `w check` must stay silent (the
# flag defaults off).
import tests.transitive_import_mid


int main():
	return transitive_leaf_value()
