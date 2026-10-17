import tests.safe_partial_move_import_fixture


struct NestedMoveOwner:
	own PartialPair* left
	own PartialPair* right


own NestedMoveOwner* nested_move_owner():
	return new NestedMoveOwner(partial_pair(), partial_pair())


own int* nested_move_take(own NestedMoveOwner* owner):
	return owner.left.first


struct NestedMoveMiddle:
	own[group] PartialView* child


struct NestedMoveOuter:
	own[group] NestedMoveMiddle* middle


own[a] PartialView* nested_move_extract(own[a] NestedMoveOuter* outer):
	return outer.middle.child
