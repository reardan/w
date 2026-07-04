struct holder_with_array:
	int[2] values


int main(int argc, int argv):
	holder_with_array* h = new holder_with_array(3)
	return h.values.length
