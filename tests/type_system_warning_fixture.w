# expect_stderr: warning: initialization type mismatch: expected 'binary_op_warning*', got 'function'
# expect_stderr: warning: assignment type mismatch: expected 'binary_op_warning*', got 'function'
import lib.lib


type binary_op_warning = fn(int, int) -> int


int good_binary(int a, int b):
	return a + b


char* wrong_return(int a, int b):
	return c"wrong"


int wrong_arity(int a):
	return a


void function_pointer_mismatch_warning():
	binary_op_warning* op = wrong_arity
	op = wrong_return


int main():
	return 0
