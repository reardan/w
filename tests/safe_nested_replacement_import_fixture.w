import tests.safe_nested_move_import_fixture


own int* nested_replacement_value(int value):
	own int* result = new int
	*result = value
	return result


struct NestedReplacementView:
	ref[first] int[] first
	ref[second] int[] second


struct NestedReplacementMiddle:
	own[y,x] NestedReplacementView* child


struct NestedReplacementOuter:
	own[b,a] NestedReplacementMiddle* middle


struct NestedReplacementBuffers:
	own PartialBuffer* child
	own int* sibling


struct NestedReplacementRecord:
	ref[data] int* value


struct NestedReplacementHolder:
	ref[group] NestedReplacementRecord view


struct NestedReplacementRoot:
	own[group] NestedReplacementHolder* holder
