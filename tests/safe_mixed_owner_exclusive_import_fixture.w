struct ExclusiveOwner:
	own int* stored
	refmut[item] int* item
	ref[shared] int* shared


own[a, b] ExclusiveOwner* exclusive_new(refmut[a] int* item, ref[b] int* shared):
	return new ExclusiveOwner(new int, item, shared)


refmut[a] int* exclusive_take(own[a, b] ExclusiveOwner* holder):
	return holder.item


ref[b] int* exclusive_shared(own[a, b] ExclusiveOwner* holder):
	return holder.shared


ref[a] int* exclusive_inspect(ref[a] ExclusiveOwner* holder):
	return holder.item
