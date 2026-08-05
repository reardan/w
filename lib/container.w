# Generic helpers that used to fill gaps in the built-in list[T]/map[K, V]
# pseudo-method surface (docs/projects/typed_containers.md "Deferred work").
# The gaps have since closed — every helper here has a first-class
# pseudo-method equivalent — so these stay only for source compatibility.


# DEPRECATED: use the first-class l.free() / m.free() / s.free()
# pseudo-method instead; these wrappers predate it and stay for source
# compatibility. Same contract either way: the container's owned storage
# and header are freed, element/value POINTERS are not chased, and using
# the variable afterwards is caller error (lib/memory.w free contract).
# The bodies keep the direct __w_list_free/__w_map_free casts rather
# than calling the pseudo-method because the pinned seed still parses
# these generic bodies (structures/json.w, in w.w's import closure,
# instantiates them) and predates .free(); they can become thin
# .free() wrappers after the next SEEDS bump.
void list_free[T](list[T] l):
	__w_list_free(cast(__w_list*, l))


void map_free[K, V](map[K, V] m):
	__w_map_free(cast(__w_hash_table*, m))


# DEPRECATED: use the first-class l.remove(index) pseudo-method instead;
# this predates it and stays for source compatibility.
void list_remove_at[T](list[T] l, int index):
	int i = index
	while (i + 1 < l.length):
		l[i] = l[i + 1]
		i = i + 1
	l.pop()
