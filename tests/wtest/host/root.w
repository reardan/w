import lib.lib
import tests.wtest.host.middle


int main():
	if (host_middle_value() != 620): return 1
	println(c"host transitive OK")
	return 0
