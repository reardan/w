type ImportedCallable = fn[source](ref[source] int*) -> ref[source] int*


ref[result] int* imported_callable_view(ref[result] int* value):
	return value


ImportedCallable* imported_callable_factory():
	return imported_callable_view
