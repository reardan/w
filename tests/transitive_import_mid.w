# Middle module for check_imports_test (build.base.json): a plain import
# re-exports transitive_import_leaf's symbols into anything that imports
# this module, without those callers importing the leaf module directly
# (the "transitive import reliance" failure class -- #145, #147).
import tests.transitive_import_leaf
