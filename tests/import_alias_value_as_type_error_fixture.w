# A qualified name in a type position must be a type: subfolder_value
# is a function in the aliased module, so declaring through it is a
# compile error (grammar/import_statement.w).
# expect_fail
# expect_stderr: 'subfolder_value' is a value, not a type, in module imported as 'sub'
import tests.subfolder as sub


int use_value(sub.subfolder_value v):
	return 0


int main():
	return 0
