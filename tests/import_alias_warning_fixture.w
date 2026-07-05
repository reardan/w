# The module is imported only through an alias, so the unqualified
# reference below compiles (the symbol table stays global) but triggers
# the unqualified-use warning asserted by the warning_test target.
import tests.subfolder as sub


int main():
	return subfolder_value()
