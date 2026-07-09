# Generic helpers filling gaps in the built-in list[T]/map[K, V] pseudo-method
# surface (docs/projects/typed_containers.md "Deferred work"): no free(), and
# no remove-by-index.


# list[T]/map[K, V] have no free() pseudo-method yet; reach into the
# auto-imported __w_list/__w_hash_table runtime directly, the same pattern
# compiler/type_table.w uses for type_table_truncate().
void list_free[T](list[T] l):
	__w_list_free(cast(__w_list*, l))


void map_free[K, V](map[K, V] m):
	__w_map_free(cast(__w_hash_table*, m))


# Removes the element at index, shifting later elements down to keep order
# (list[T] has no remove(i) pseudo-method yet).
void list_remove_at[T](list[T] l, int index):
	int i = index
	while (i + 1 < l.length):
		l[i] = l[i + 1]
		i = i + 1
	l.pop()
