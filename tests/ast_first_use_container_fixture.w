# No container declarations pre-register the types used by these expressions.
struct ast_fresh_item:
	int value
	int other

struct ast_fresh_nested:
	int value

struct ast_fresh_generic:
	int value

struct ast_fresh_pointer:
	int value

type ast_fresh_alias = ast_fresh_item

T ast_fresh_identity[T](T value): return value

int ast_fresh_sequence

int ast_fresh_tick(int value):
	ast_fresh_sequence = ast_fresh_sequence * 10 + value
	return value

# Introduce a container, both pointer levels, then a generic signature in
# one root. The pointer names must outlive the temporary expression arena.
int ast_fresh_pointer_sizes():
	return (sizeof(list[ast_fresh_pointer]**) + ast_fresh_identity[int](sizeof(list[ast_fresh_pointer]*)))

int main():
	items := list[ast_fresh_item]{ast_fresh_item(ast_fresh_tick(1), ast_fresh_tick(2))}
	if (items[0].value != 1 || items[0].other != 2 || ast_fresh_sequence != 12): return 1
	aliases := list[ast_fresh_alias]{ast_fresh_item(3, 4)}
	if (aliases[0].other != 4): return 2
	nested := list[map[int, ast_fresh_nested]]{map[int, ast_fresh_nested]{5: ast_fresh_nested(6)}}
	if (nested[0][5].value != 6): return 3
	# The map exists, but the snapshot's list type does not.
	values := nested[0].values()
	if (values.length != 1 || values[0].value != 6): return 4
	members := set[uint16]{7, 8}
	keys := members.keys()
	if (keys.length != 2 || (7 in keys) == 0 || (8 in keys) == 0): return 5
	# The generic type argument introduces the container before the signature.
	generic := ast_fresh_identity[list[ast_fresh_generic]](list[ast_fresh_generic]{ast_fresh_generic(9)})
	if (generic[0].value != 9): return 6
	defaults := new map[uint16, list[set[uint16]]]()
	inner := defaults[1]
	inner.push(set[uint16]{10})
	if ((10 in defaults[1][0]) == 0): return 7
	if (ast_fresh_pointer_sizes() != 2 * __word_size__): return 8
	list[ast_fresh_pointer]** pointer = cast(list[ast_fresh_pointer]**, 0)
	if (cast(int, pointer) != 0): return 9
	# Snapshot registration at the end of a root and before a new pointer.
	map[uint8, ast_fresh_pointer] mapping = new map[uint8, ast_fresh_pointer]
	mapping[1] = ast_fresh_pointer(11)
	snapshot := mapping.values()
	if (snapshot[0].value != 11): return 10
	if (mapping.keys().length + sizeof(ast_fresh_nested**) != 1 + __word_size__): return 11
	items.free()
	aliases.free()
	nested[0].free()
	nested.free()
	values.free()
	members.free()
	keys.free()
	generic.free()
	inner[0].free()
	inner.free()
	defaults.free()
	mapping.free()
	snapshot.free()
	return 0
