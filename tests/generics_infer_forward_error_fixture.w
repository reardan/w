import lib.lib

# Inference requires the generic's definition to appear before the call
# site: an unregistered name followed by '(' is an ordinary unknown
# symbol (forward calls keep requiring explicit 'later_pick[int](...)').
int main(int argc, char** argv):
	return later_pick(1, 2)


T later_pick[T](T a, T b):
	if (a > b):
		return a
	return b
