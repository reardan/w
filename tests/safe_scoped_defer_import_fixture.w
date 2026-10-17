void scoped_digit(refmut int* value, int amount):
	*value = *value * 10 + amount


void scoped_add(refmut int* value, int amount):
	*value = *value + amount


void scoped_dispose[T](own T* value):
	ref T* view = value


int scoped_observe(ref int* value):
	return *value
