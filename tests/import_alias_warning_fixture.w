# The module is imported only through an alias, so the unqualified
# reference below compiles (the symbol table stays global) but triggers
# the unqualified-use warning asserted by the warning_test target.
# expect_stderr: warning: unqualified use of 'subfolder_value' from module imported as 'sub'
import tests.subfolder as sub


int main():
	return subfolder_value()
