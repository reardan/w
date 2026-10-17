struct OptionalFieldRecord:
	optref[data] int* value
	int tag


struct OptionalFieldOwner:
	own int* stored
	optrefmut[data] int* value


struct OptionalFieldOuter:
	own[group] OptionalFieldOwner* child


ref[a] OptionalFieldRecord optional_field_record(optref[a] int* value):
	return OptionalFieldRecord(value, 3)


own[a] OptionalFieldOwner* optional_field_owner(optrefmut[a] int* value):
	return new OptionalFieldOwner(new int, value)


optref[a] int* optional_field_read(ref[a] OptionalFieldOwner* owner):
	return owner.value
