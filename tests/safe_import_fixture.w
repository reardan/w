int safe_import_read(ref int* p):
	return *p

int safe_import_consume(own int* p):
	return *p

ref int* safe_import_view(ref int* p):
	return p
