# expect_fail
# expect_stderr: cannot initialize fixed-array field in constructor
struct holder_with_array:
	int[2] values


int main(int argc, int argv):
	holder_with_array* h = new holder_with_array(3)
	return h.values.length
