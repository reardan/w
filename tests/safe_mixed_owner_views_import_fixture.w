import tests.safe_mixed_owner_import_fixture


ref[a] int[] mixed_view_data(ref[a] OwnedView* holder):
	return holder.data


ref[a] OwnedView* mixed_view_pass(ref[a] OwnedView* holder):
	return holder


ref[a] int* mixed_view_stored(ref[a] OwnedView* holder):
	return holder.stored
