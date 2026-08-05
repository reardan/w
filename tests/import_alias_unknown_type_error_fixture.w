# A qualified type must be declared in the aliased module: no type
# 'no_such_type' exists there, so the parameter declaration is a
# compile error (grammar/import_statement.w).
# expect_fail
# expect_stderr: type 'no_such_type' is not defined in module imported as 'sub'
import tests.subfolder as sub


int use_missing(sub.no_such_type v):
	return 0


int main():
	return 0
