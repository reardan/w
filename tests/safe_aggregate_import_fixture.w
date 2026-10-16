struct ImportedView:
	ref[field] int* item
	int tag


ref[a] ImportedView aggregate_import_make(ref[a] int* p, int tag):
	return ImportedView(p, tag)


ref[a] int* aggregate_import_get(ref[a] ImportedView h):
	return h.item
