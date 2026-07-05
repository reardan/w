# Qualified access must name a symbol declared in the aliased module:
# local_helper lives in this file, so sub.local_helper is a compile error.
import tests.subfolder as sub


int local_helper():
	return 1


int main():
	return sub.local_helper()
