import lib.lib
import lib.assert


struct queue_node:
	void* item
	queue_node* next


struct queue:
	int length
	int maxsize
	queue_node* head
	queue_node* tail


queue* queue_new_maxsize(int maxsize):
	queue* q = new queue()
	q.length = 0
	q.maxsize = maxsize
	q.head = 0
	q.tail = 0
	return q


queue* queue_new():
	return queue_new_maxsize(0)


int queue_empty(queue* q):
	return q.length == 0


int queue_size(queue* q):
	return q.length


int queue_full(queue* q):
	if (q.maxsize <= 0):
		return 0
	return q.length >= q.maxsize


int queue_try_put(queue* q, void* item):
	if (queue_full(q)):
		return 0
	queue_node* node = new queue_node()
	node.item = item
	node.next = 0
	if (q.head == 0):
		q.head = node
	else:
		q.tail.next = node
	q.tail = node
	q.length = q.length + 1
	return 1


void queue_put(queue* q, void* item):
	asserts(c"queue_put on a full queue", queue_try_put(q, item))


void* queue_get(queue* q):
	if (q.length == 0):
		return 0
	queue_node* node = q.head
	void* item = node.item
	q.head = node.next
	if (q.head == 0):
		q.tail = 0
	q.length = q.length - 1
	free(node)
	return item


void queue_free(queue* q):
	while (queue_empty(q) == 0):
		queue_get(q)
	free(q)
