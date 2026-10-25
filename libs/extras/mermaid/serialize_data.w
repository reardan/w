# Canonical data source.
import libs.extras.mermaid.serialize_common

void mm_serialize_data_body(mm_serializer* out, mm_document* d, int variant):
	out.failed = 1

int mm_serialize_data_class_defs(int kind):
	return 0
