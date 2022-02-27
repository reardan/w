import testing


int test_creation():
	ll = new linked_list()


int test_from_iterator():
	int length = 10
	ll = new linked_list(range(length))
	assert_equal(length, ll.length)


int test_push():
	ll = new linked_list()
	ll.push(1)
	ll.push(1, 2)
	assert_equal(ll.length, 3)
