import lib.memory


struct Pair:
	int first
	int second


T* raw_allocate[T]():
	return new T


T* raw_construct[T](int first, int second):
	return new T(first, second)


int main():
	int* value = raw_allocate[int]()
	*value = 3
	Pair* pair = raw_construct[Pair](*value, 4)
	int result = pair.first + pair.second
	free(cast(void*, value))
	free(cast(void*, pair))
	return result - 7
