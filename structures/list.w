/*
list
	append
	appendleft
	clear
	copy
	count
	extend
	extendleft
	index
	insert
	pop
	popleft
	remove
	reverse
	rotate

sub classes / specialty versions
	LinkedList
	ArrayList
	FlatList
	DoublyLinkedList
	RingBuffer

*/
import assert
import integer
import lib.math

# Depends on codegen indirectly for load_int/save_int for now
# This will be removed once int*[] lookups are working.

int capacity
int length
char* array


void create():
	array = 0
	length = capacity = 0


void die():
	# TODO: free children
	free(array)
	create()


void resize(int new_capacity):
	assert1(new_capacity > capacity)
	array = realloc(array, capacity * 4, new_capacity * 4)
	assert1(array != 0)  /* not sure why this doesn't work */
	capacity = new_capacity


void ensure(int n):
	if (length + n > capacity):
		resize(max(length * 2, n))


int push(int value):
	ensure(1)
	# array[length++] = value
	save_int(array + length * 4, value)
	length = length + 1
	return length - 1


int get(int i):
	return load_int(array + i * 4)


int pop():
	if(length == 0):
		return 0 /* null indicates empty: caller should check this */
	length = length - 1
	# int result = array[length]
	int result = load_int(array + length * 4)
	return result


# assume strings and join
int join(char* delimiter):
	# loop through array to get total strlen
	int n = 0
	int i = 0
	while (i < length):
		char* s = get(i)
		n = n + strlen(s)
		i = i + 1

	# join strings together
	int delimiter_count = 0
	if (delimiter != 0):
		delimiter_count = strlen(delimiter) * n
	int result = malloc(n + delimiter_count + 1)
	int cur = result
	i = 0
	while (i < length):
		char* s = get(i)
		cur = strcpy(cur, s)
		if ((delimiter != 0) & (i < length - 1)):
			cur = strcpy(cur, delimiter)
		i = i + 1
	result[n + delimiter_count] = 0
	return result


# splits str by delimiter and pushes on to this list
void split_string(char* str, char* delimiter):
	char* token_start = str
	while (str[0]):

		if (starts_with(str, delimiter)):
			# duplicate
			str[0] = 0
			push(strclone(token_start))

			str = str + strlen(delimiter)
			token_start = str
		else:
			str = str + 1

	# duplicate
	str[0] = 0
	push(strclone(token_start))
