# Richer debuggee for the wdbg feature tests: functions with arguments
# and locals, nested calls, a global and a string local.
import lib.lib

int counter

int add(int a, int b):
	int total = a + b
	return total

int triple(int n):
	int doubled = add(n, n)
	int result = add(doubled, n)
	return result

int main(int argc, int argv):
	counter = 5
	int x = 3
	char* message = c"hello wdbg"
	debugger
	int y = triple(x)
	counter = counter + y
	println(message)
	return y
