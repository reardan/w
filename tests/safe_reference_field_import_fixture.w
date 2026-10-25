struct ReferencePair:
	ref[left] int* first
	ref[right] int* second


struct ReferenceOwner:
	own int* stored
	ref[items] int[] items
	refmut[value] int* value
	ref[left, right] ReferencePair pair


own[a, b, c, d] ReferenceOwner* reference_owner(ref[a] int[] items, refmut[b] int* value, ref[c] int* left, ref[d] int* right):
	return new ReferenceOwner(new int, items, value, ReferencePair(left, right))


own[a, b, c, d] ReferenceOwner* reference_update(own[a, b, c, d] ReferenceOwner* owner, ref[a] int[] items, ref[c] int* left, ref[d] int* right):
	owner.items = items
	owner.pair = ReferencePair(left, right)
	return owner


ref[a] int[] reference_take(own[a, b, c, d] ReferenceOwner* owner, ref[a] int[] items):
	owner.items = items
	return owner.items


ref[a] T* reference_pass[T](ref[a] T* value):
	return value
