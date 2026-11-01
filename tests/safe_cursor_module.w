# A multi-parameter user cursor imported through an alias by contract tests.
struct WCursor[A, B]:
	own A* first
	own B* second


int WCursor_iter_begin[A, B](ref WCursor[A, B]* c): return 0


int WCursor_iter_done[A, B](ref WCursor[A, B]* c, int cursor): return cursor >= 1


int WCursor_iter_next[A, B](ref WCursor[A, B]* c, int cursor): return cursor + 1


ref[a] A* WCursor_iter_value[A, B](ref[a] WCursor[A, B]* c, int cursor): return c.first


own WCursor[A, B]* make_cursor[A, B](own A* first, own B* second):
	return new WCursor[A, B](first, second)
