struct OwnedView:
	own int* stored
	ref[item] int* item
	ref[data] int[] data
	int tag


own[a,b] OwnedView* owned_view_new(ref[a] int* item, ref[b] int[] data):
	return new OwnedView(new int, item, data, 7)


own[a,b] OwnedView* owned_view_pass(own[a,b] OwnedView* value):
	return value


ref[b] int[] owned_view_take_data(own[a,b] OwnedView* value):
	return value.data


ref[a] int* owned_view_take_item(own[a,b] OwnedView* value):
	return value.item
