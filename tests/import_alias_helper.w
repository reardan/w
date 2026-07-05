# Helper for import_test: binds a file-scoped alias inside an imported
# module and uses qualified access through it.
import tests.subfolder as helper_sub


int helper_qualified_value():
	return helper_sub.subfolder_value()
