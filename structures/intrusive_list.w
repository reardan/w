/*
Intrusive doubly-linked circular list and hlist, after the Linux kernel's
include/linux/list.h (design: docs/projects/linux_idioms.md).

Unlike structures/linked_list.w, the link fields live inside the user's
struct: no per-node allocation, one object can sit on several lists at
once, and unlink is O(1) when the node is already in hand.

A list is anchored by a list_head that links to itself when empty. The
same struct doubles as the per-node link. Recover the containing struct
with container_of and a field offset obtained via the null-base trick:

	struct job:
		int priority
		list_head queue_link

	int job_queue_link_offset():
		job* base = cast(job*, 0)
		return cast(int, &base.queue_link)

	job* j = cast(job*, container_of(node, job_queue_link_offset()))

Iteration uses the standard cursor protocol, yielding list_head*:

	for list_head* node in &queue:
		...

Do not unlink the node the cursor is on while iterating; delete either
before advancing (grab next first) or after the loop.
*/
import lib.lib
import lib.assert


struct list_head:
	list_head* next
	list_head* prev


# hlist: a list with a single-word head, for hash buckets where the
# anchor array must be dense. Entries still unlink in O(1) because each
# node points back at whatever slot pointed to it.
struct hlist_node:
	hlist_node* next
	hlist_node** pprev


struct hlist_head:
	hlist_node* first


void* container_of(void* member, int offset):
	return cast(void*, cast(char*, member) - offset)


void list_init(list_head* head):
	head.next = head
	head.prev = head


int list_empty(list_head* head):
	return head.next == head


void list_insert_between(list_head* entry, list_head* before, list_head* after):
	before.next = entry
	entry.prev = before
	entry.next = after
	after.prev = entry


# Insert right after head (LIFO / stack order).
void list_add(list_head* entry, list_head* head):
	list_insert_between(entry, head, head.next)


# Insert right before head (FIFO / queue order).
void list_add_tail(list_head* entry, list_head* head):
	list_insert_between(entry, head.prev, head)


# Unlink and re-init so a repeated del or an empty-check on the entry is
# safe (the kernel's list_del_init).
void list_del(list_head* entry):
	entry.prev.next = entry.next
	entry.next.prev = entry.prev
	list_init(entry)


list_head* list_first(list_head* head):
	assert1(list_empty(head) == 0)
	return head.next


list_head* list_last(list_head* head):
	assert1(list_empty(head) == 0)
	return head.prev


# Move entry to the front/back of (possibly another) list.
void list_move(list_head* entry, list_head* head):
	list_del(entry)
	list_add(entry, head)


void list_move_tail(list_head* entry, list_head* head):
	list_del(entry)
	list_add_tail(entry, head)


int list_length(list_head* head):
	int n = 0
	list_head* node = head.next
	while (node != head):
		n = n + 1
		node = node.next
	return n


# Cursor protocol (docs/projects/iteration.md): cursors are node
# addresses; the anchor head is the past-the-end sentinel.
int list_head_iter_begin(list_head* head):
	return cast(int, head.next)


int list_head_iter_done(list_head* head, int cursor):
	return cursor == cast(int, head)


int list_head_iter_next(list_head* head, int cursor):
	list_head* node = cast(list_head*, cursor)
	return cast(int, node.next)


int list_head_iter_value(list_head* head, int cursor):
	return cursor


void hlist_init(hlist_head* head):
	head.first = 0


int hlist_empty(hlist_head* head):
	return head.first == 0


void hlist_add_head(hlist_node* entry, hlist_head* head):
	entry.next = head.first
	if (head.first != 0):
		head.first.pprev = &entry.next
	head.first = entry
	entry.pprev = &head.first


void hlist_del(hlist_node* entry):
	if (entry.pprev == 0):
		return
	hlist_node** pprev = entry.pprev
	*pprev = entry.next
	if (entry.next != 0):
		entry.next.pprev = pprev
	entry.next = 0
	entry.pprev = 0
