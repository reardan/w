import lib.safe_buffer


struct FieldNode:
	own int* value
	own int* other


struct FieldOwner:
	own FieldNode* node
	own WIntBuffer* buffer
	int tag


own FieldNode* field_node(int value, refmut[a] int* calls):
	*calls += 1
	own int* stored = new int
	*stored = value
	return new FieldNode(stored, new int)


own FieldOwner* field_replace(own FieldOwner* holder, own FieldNode* node):
	holder.node = node
	return holder
