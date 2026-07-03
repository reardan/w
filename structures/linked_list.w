/*
Singly linked list of word values with head and tail pointers.
Push appends in O(1); pop removes from the tail in O(n).
*/
import lib.lib
import lib.assert


struct linked_list_node:
	int data
	linked_list_node* next


struct linked_list:
	int length
	linked_list_node* head
	linked_list_node* tail


linked_list* linked_list_new():
	linked_list* list = malloc(12)
	list.length = 0
	list.head = 0
	list.tail = 0
	return list


void linked_list_push(linked_list* list, int value):
	linked_list_node* node = malloc(8)
	node.data = value
	node.next = 0
	if (list.head == 0):
		list.head = node
	else:
		list.tail.next = node
	list.tail = node
	list.length = list.length + 1


int linked_list_get(linked_list* list, int index):
	assert1(index < list.length)
	linked_list_node* node = list.head
	while (index > 0):
		node = node.next
		index = index - 1
	return node.data


int linked_list_iter_begin(linked_list* list):
	return list.head


int linked_list_iter_done(linked_list* list, int cursor):
	return cursor == 0


int linked_list_iter_next(linked_list* list, int cursor):
	linked_list_node* node = cursor
	return node.next


int linked_list_iter_value(linked_list* list, int cursor):
	linked_list_node* node = cursor
	return node.data


int linked_list_pop(linked_list* list):
	assert1(list.length > 0)
	linked_list_node* last = list.tail
	int value = last.data
	if (list.head == last):
		list.head = 0
		list.tail = 0
	else:
		linked_list_node* node = list.head
		while (node.next != last):
			node = node.next
		node.next = 0
		list.tail = node
	free(last)
	list.length = list.length - 1
	return value


void linked_list_free(linked_list* list):
	linked_list_node* node = list.head
	while (node != 0):
		linked_list_node* next = node.next
		free(node)
		node = next
	free(list)
