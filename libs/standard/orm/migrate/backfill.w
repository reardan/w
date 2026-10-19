# w-orm migration backfills (issue #754, unit U2.4).
#
# A BACKFILL op names a W function registered here. The applier calls it
# repeatedly with (db, batch_size); each call does at most one batch (for
# example an UPDATE over the next batch_size pks still missing a value) and
# returns the number of rows it changed: 0 means done, a negative number an
# error (orm_db_set_error explains). Outside an atomic migration every call
# runs in its own transaction, so no batch holds a long lock.
#
#   int book_isbn_backfill(orm_db* db, int batch):
#   	...
#   orm_backfill_register(c"library_book_isbn_backfill", book_isbn_backfill)
import libs.standard.orm.contract


type orm_backfill_fn = fn(orm_db*, int) -> int


map[char*, orm_backfill_fn*] __orm_backfills


void orm_backfill_register(char* name, orm_backfill_fn* f):
	if (__orm_backfills == 0): __orm_backfills = new map[char*, orm_backfill_fn*]
	__orm_backfills[name] = f


orm_backfill_fn* orm_backfill_lookup(char* name):
	if (__orm_backfills == 0 || name == 0): return 0
	if (name in __orm_backfills): return __orm_backfills[name]
	return 0
