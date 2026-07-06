import lib.lib

# The definition uses a type parameter that was never declared ('U';
# only 'T' is a parameter). The error surfaces at instantiation time,
# when the definition is re-parsed with only T bound.
T first_of[T](T a, U b):
	return a


int main(int argc, char** argv):
	return first_of[int](1, 2)
