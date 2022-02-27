struct linked_list_node:
	void* data
	linked_list_node* next


linked_list_node* start
linked_list_node* end
uint length


create():
	start = end = null
	length = 0


delete():
	for node in iterator(): free(node)
	create()


push(value):
	auto node = new linked_list_node()
	if not start:
		start = node
	end.next = node
	end = node
	length += 1


pop():
	assert(length > 0)
	for node in iterator():
		if node.next == end:
			node.next = null
			free(end)
			end = null
			length -= 1
			return


iterator():
	auto node = start
	while node:
		yield node
		node = node.next
