import lib.testing
import structures.intrusive_list


# One object on two lists at once: a queue link and an owner link.
struct ijob:
	int priority
	list_head queue_link
	list_head owner_link
	char* name


int ijob_queue_link_offset():
	ijob* base = cast(ijob*, 0)
	return cast(int, &base.queue_link)


int ijob_owner_link_offset():
	ijob* base = cast(ijob*, 0)
	return cast(int, &base.owner_link)


ijob* ijob_from_queue(list_head* node):
	return cast(ijob*, container_of(cast(void*, node), ijob_queue_link_offset()))


ijob* ijob_from_owner(list_head* node):
	return cast(ijob*, container_of(cast(void*, node), ijob_owner_link_offset()))


ijob* ijob_new(int priority, char* name):
	ijob* j = new ijob()
	j.priority = priority
	j.name = name
	list_init(&j.queue_link)
	list_init(&j.owner_link)
	return j


void test_empty_list():
	list_head queue
	list_init(&queue)
	assert_equal(1, list_empty(&queue))
	assert_equal(0, list_length(&queue))


void test_add_tail_is_fifo():
	list_head queue
	list_init(&queue)
	ijob* a = ijob_new(1, c"a")
	ijob* b = ijob_new(2, c"b")
	ijob* c = ijob_new(3, c"c")
	list_add_tail(&a.queue_link, &queue)
	list_add_tail(&b.queue_link, &queue)
	list_add_tail(&c.queue_link, &queue)
	assert_equal(3, list_length(&queue))
	assert_equal(1, ijob_from_queue(list_first(&queue)).priority)
	assert_equal(3, ijob_from_queue(list_last(&queue)).priority)
	free(a)
	free(b)
	free(c)


void test_add_is_lifo():
	list_head stack
	list_init(&stack)
	ijob* a = ijob_new(1, c"a")
	ijob* b = ijob_new(2, c"b")
	list_add(&a.queue_link, &stack)
	list_add(&b.queue_link, &stack)
	assert_equal(2, ijob_from_queue(list_first(&stack)).priority)
	free(a)
	free(b)


void test_del_is_o1_and_reinits():
	list_head queue
	list_init(&queue)
	ijob* a = ijob_new(1, c"a")
	ijob* b = ijob_new(2, c"b")
	ijob* c = ijob_new(3, c"c")
	list_add_tail(&a.queue_link, &queue)
	list_add_tail(&b.queue_link, &queue)
	list_add_tail(&c.queue_link, &queue)

	# Unlink the middle node without touching the anchor.
	list_del(&b.queue_link)
	assert_equal(2, list_length(&queue))
	assert_equal(1, ijob_from_queue(list_first(&queue)).priority)
	assert_equal(3, ijob_from_queue(list_last(&queue)).priority)

	# del re-inits, so the node is safely empty and re-deletable.
	assert_equal(1, list_empty(&b.queue_link))
	list_del(&b.queue_link)
	assert_equal(2, list_length(&queue))
	free(a)
	free(b)
	free(c)


void test_one_object_on_two_lists():
	list_head queue
	list_head owned
	list_init(&queue)
	list_init(&owned)
	ijob* j = ijob_new(9, c"both")
	list_add_tail(&j.queue_link, &queue)
	list_add_tail(&j.owner_link, &owned)
	assert_equal(9, ijob_from_queue(list_first(&queue)).priority)
	assert_equal(9, ijob_from_owner(list_first(&owned)).priority)

	# Dropping it from one list leaves it on the other.
	list_del(&j.queue_link)
	assert_equal(1, list_empty(&queue))
	assert_equal(1, list_length(&owned))
	assert_strings_equal(c"both", ijob_from_owner(list_first(&owned)).name)
	free(j)


void test_move_between_lists():
	list_head pending
	list_head running
	list_init(&pending)
	list_init(&running)
	ijob* j = ijob_new(5, c"task")
	list_add_tail(&j.queue_link, &pending)
	list_move_tail(&j.queue_link, &running)
	assert_equal(1, list_empty(&pending))
	assert_equal(5, ijob_from_queue(list_first(&running)).priority)
	list_move(&j.queue_link, &pending)
	assert_equal(1, list_empty(&running))
	assert_equal(1, list_length(&pending))
	free(j)


void test_for_loop_cursor_protocol():
	list_head queue
	list_init(&queue)
	ijob* a = ijob_new(10, c"a")
	ijob* b = ijob_new(20, c"b")
	ijob* c = ijob_new(30, c"c")
	list_add_tail(&a.queue_link, &queue)
	list_add_tail(&b.queue_link, &queue)
	list_add_tail(&c.queue_link, &queue)
	int sum = 0
	int count = 0
	list_head* anchor = &queue
	for list_head* node in anchor:
		sum = sum + ijob_from_queue(node).priority
		count = count + 1
	assert_equal(60, sum)
	assert_equal(3, count)
	free(a)
	free(b)
	free(c)


# --- hlist ---

struct hitem:
	int key
	hlist_node link


int hitem_link_offset():
	hitem* base = cast(hitem*, 0)
	return cast(int, &base.link)


hitem* hitem_from_node(hlist_node* node):
	return cast(hitem*, container_of(cast(void*, node), hitem_link_offset()))


hitem* hitem_new(int key):
	hitem* item = new hitem()
	item.key = key
	item.link.next = 0
	item.link.pprev = 0
	return item


void test_hlist_add_and_del():
	hlist_head bucket
	hlist_init(&bucket)
	assert_equal(1, hlist_empty(&bucket))

	hitem* a = hitem_new(1)
	hitem* b = hitem_new(2)
	hitem* c = hitem_new(3)
	hlist_add_head(&a.link, &bucket)
	hlist_add_head(&b.link, &bucket)
	hlist_add_head(&c.link, &bucket)

	# Head insertion: c, b, a.
	assert_equal(3, hitem_from_node(bucket.first).key)
	assert_equal(2, hitem_from_node(bucket.first.next).key)
	assert_equal(1, hitem_from_node(bucket.first.next.next).key)

	# Delete the middle entry; chain heals through pprev.
	hlist_del(&b.link)
	assert_equal(3, hitem_from_node(bucket.first).key)
	assert_equal(1, hitem_from_node(bucket.first.next).key)
	assert_equal(0, cast(int, bucket.first.next.next))

	# Delete the head; bucket.first follows.
	hlist_del(&c.link)
	assert_equal(1, hitem_from_node(bucket.first).key)

	# Deleting an unlinked entry is a no-op.
	hlist_del(&b.link)
	hlist_del(&a.link)
	assert_equal(1, hlist_empty(&bucket))
	free(a)
	free(b)
	free(c)


void test_hlist_as_hash_buckets():
	# A tiny fixed-size chained hash table out of hlist heads.
	hlist_head[8] buckets
	int i = 0
	while (i < 8):
		hlist_init(&buckets[i])
		i = i + 1

	i = 0
	while (i < 32):
		hitem* item = hitem_new(i)
		hlist_add_head(&item.link, &buckets[i % 8])
		i = i + 1

	# Every key hashes to key % 8; verify chain membership.
	int found = 0
	i = 0
	while (i < 8):
		hlist_node* node = buckets[i].first
		while (node != 0):
			assert_equal(i, hitem_from_node(node).key % 8)
			found = found + 1
			node = node.next
		i = i + 1
	assert_equal(32, found)
