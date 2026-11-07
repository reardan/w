# A pointer to an alias names the same type as a pointer to what the
# alias stands for: with 'type handle_t = void*', 'handle_t*' is void**,
# however it is spelled (a declaration, a parameter, a return type, a
# cast or '&'), so passing one where the other is wanted needs no cast
# and draws no warning. The strict steps fail on any warning.
# wbuild: step="bin/wv2 --strict tests/alias_pointer_test.w -o bin/alias_pointer_strict"
# wbuild: step="bin/wv2 --strict --streaming tests/alias_pointer_test.w -o bin/alias_pointer_strict_streaming"
# wbuild: step="bin/wv2 x64 --strict tests/alias_pointer_test.w -o bin/alias_pointer_strict64"
# wbuild: x64
import lib.assert


type ap_handle = void*


struct ap_node:
	int value


type ap_node_ptr = ap_node*


ap_handle* ap_slot


int ap_store(ap_handle* out, int v):
	*out = cast(ap_handle, v)
	return 1


ap_node_ptr* ap_first(ap_node_ptr* list):
	return cast(ap_node_ptr*, cast(int, list))


ap_node_ptr* ap_same(ap_node_ptr* p):
	ap_node_ptr* q = p
	return q


int main():
	void* h = 0
	assert_equal(1, ap_store(cast(ap_handle*, cast(int, &h)), 5))
	assert_equal(5, cast(int, h))
	ap_handle* q = cast(ap_handle*, &h)
	ap_store(q, 6)
	assert_equal(6, cast(int, h))
	void** r = &h
	ap_store(r, 7)
	assert_equal(7, cast(int, *q))
	ap_handle h2 = 0
	ap_store(&h2, 8)
	assert_equal(8, cast(int, h2))
	ap_slot = &h2
	assert_equal(8, cast(int, *ap_slot))

	ap_node n
	n.value = 9
	ap_node_ptr np = &n
	ap_node_ptr* pp = ap_first(&np)
	assert_equal(9, (*pp).value)
	ap_node** raw = ap_same(pp)
	assert_equal(9, (*raw).value)
	return 0
