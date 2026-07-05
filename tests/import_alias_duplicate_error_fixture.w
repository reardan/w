# The same alias cannot be bound twice in one file.
import tests.subfolder as sub
import tests.level1.level2.level3.level_file as sub


int main():
	return 0
