# wbuild: binary=wvm_fault_fixture arch=x64
import lib.lib

int guest_fault_site():
	int* pointer = cast(int*, 1)
	return pointer[0]

int main():
	return guest_fault_site()
