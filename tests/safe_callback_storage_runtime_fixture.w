import lib.memory_debug


struct Environment:
	own int* value


type Invoke = fn[](ref Environment*, int) -> int
type View = fn[a](ref[a] Environment*) -> ref[a] int*


struct Captured:
	Invoke* code
	View* view
	own Environment* environment


int invoke(ref Environment* environment, int extra):
	ref int* value = environment.value
	return *value + extra


ref[a] int* view(ref[a] Environment* environment):
	return environment.value


own Captured* capture(int number):
	own int* value = new int
	*value = number
	own Environment* environment = new Environment(value)
	return new Captured(invoke, view, environment)


int execute(own Captured* captured, int fail):
	if fail: return -1
	ref Environment* environment = captured.environment
	ref int* result = captured.view(environment)
	return captured.code(environment, 3) + *result


int exercise():
	int total = 0
	for i in range(30):
		total += execute(capture(i), 0)
		if execute(capture(i), 1) != -1: return -1000
		own Captured* captured = capture(i)
		Invoke* code = captured.code
		captured = capture(i + 1)
		own Environment* environment = captured.environment
		total += code(environment, 3)
	return total


int main():
	int before = 0
	unsafe:
		before = debug_alloc_report_leaks()
	if exercise() != 1515: return 1
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return after - before
