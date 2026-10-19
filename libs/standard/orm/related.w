# w-orm relations (unit U2.1, docs/projects/orm/u2_1.md).
#
# prefetch_related execution, explicit relation loaders and streaming
# iteration:
#
#   orm_result* r = Author_objects(db).prefetch_related(c"books__tags").all()
#   # 3 queries: authors, their books (one IN query), those books' tags
#   for Author* a in Author_rows(r):
#       for Book* b in Author_books(a): println(b.title)
#   orm_result_free(r)
#
# Every hop runs one SELECT ... WHERE key IN (...) per batch of keys (a
# batch stays under dialect.max_params) and stitches the rows into the
# relation slots of the rows already loaded. Rows loaded by a prefetch are
# owned by the same orm_result as the rows they are stitched into (C6).
#
# query.w imports this module at its end, so importing the ORM (orm.w or
# query.w) is enough; all(), first() and get() call orm_prefetch_execute.
import libs.standard.orm.query
import libs.standard.orm.atomic


# Keys per prefetch query; 0 = derive from dialect.max_params. Tests set it
# to force batching.
int __orm_prefetch_batch


# ---------------------------------------------------------------------------
# Prefetch objects

# Prefetch(path, queryset, to_attr). qs (may be 0) filters/orders the rows
# of the LAST hop of path and must be a queryset over that hop's model; it
# may itself select_related or prefetch_related. to_attr (may be 0) stores
# the last hop's rows as a list[void*] read with orm_row_prefetched instead
# of in the relation slot. Strings are borrowed.
orm_prefetch* orm_prefetch_new(char* path, orm_queryset* qs, char* to_attr):
	orm_prefetch* pf = new orm_prefetch()
	pf.path = path
	if (qs != 0): pf.queryset = cast(void*, qs.query)
	pf.to_attr = to_attr
	return pf


# qs.prefetch(orm_prefetch_new(...)): records a Prefetch object.
orm_queryset* orm_queryset_prefetch(orm_queryset* qs, orm_prefetch* pf):
	orm_queryset* c = orm_queryset_clone(qs)
	c.query.prefetch.push(pf)
	return c


# ---------------------------------------------------------------------------
# to_attr storage
#
# A to_attr list lives in the row meta's attr_names / attr_values (load.w),
# apart from the text annotations, so annotation readers (serializers)
# never see it. The list is owned by the result the prefetch stored its
# rows in.

# The list a prefetch stored under to_attr on this row, or 0.
list[void*] orm_row_prefetched(orm_model_desc* m, void* row, char* to_attr):
	orm_row_meta* meta = orm_row_meta_get(m, row)
	if (meta == 0 || meta.attr_names == 0 || to_attr == 0): return 0
	for i in range(meta.attr_names.length):
		if (strcmp(meta.attr_names[i], to_attr) == 0): return cast(list[void*], meta.attr_values[i])
	return 0


# Per-stitch state: attr name lists are shared by the rows a stitch
# touched, so adding a name copies the list once per distinct source list.
struct orm_attr_writer:
	orm_result* owner
	char* name
	map[int, int] copies        # old names list -> new names list


orm_row_meta* orm_row_meta_ensure(orm_model_desc* m, void* row, orm_result* owner):
	orm_row_meta* meta = orm_row_meta_get(m, row)
	if (meta != 0): return meta
	meta = cast(orm_row_meta*, orm_result_alloc(owner, sizeof(orm_row_meta)))
	meta.result = owner
	orm_row_meta_set(m, row, meta)
	return meta


void orm_attr_set(orm_attr_writer* w, orm_model_desc* m, void* row, list[void*] value):
	orm_row_meta* meta = orm_row_meta_ensure(m, row, w.owner)
	if (meta.attr_names != 0):
		for i in range(meta.attr_names.length):
			if (strcmp(meta.attr_names[i], w.name) == 0):
				meta.attr_values[i] = cast(void*, value)
				return
	int old = cast(int, meta.attr_names)
	list[char*] names = 0
	if (old in w.copies): names = cast(list[char*], w.copies[old])
	else:
		names = cast(list[char*], orm_result_list(w.owner))
		if (meta.attr_names != 0):
			for char* n in meta.attr_names: names.push(n)
		names.push(w.name)
		w.copies[old] = cast(int, names)
	if (meta.attr_values == 0):
		meta.attr_values = cast(list[void*], orm_result_list(w.owner))
	meta.attr_names = names
	meta.attr_values.push(cast(void*, value))


orm_attr_writer* orm_attr_writer_new(orm_result* owner, char* to_attr):
	orm_attr_writer* w = new orm_attr_writer()
	w.owner = owner
	w.name = orm_result_strdup(owner, to_attr)
	w.copies = new map[int, int]
	return w


void orm_attr_writer_free(orm_attr_writer* w):
	if (w == 0): return
	w.copies.free()
	free(cast(void*, w))


# ---------------------------------------------------------------------------
# Ownership

# Moves everything src owns into dst and frees src's shell (not its rows,
# which now belong to dst). Row metas that pointed at src point at dst.
void orm_result_adopt(orm_result* dst, orm_result* src):
	if (src == 0): return
	for void* p in src.owned: dst.owned.push(p)
	for void* l in src.owned_lists: dst.owned_lists.push(l)
	if (src.model != 0):
		for void* row in src.rows:
			orm_row_meta* meta = orm_row_meta_get(src.model, row)
			if (meta != 0 && meta.result == src): meta.result = dst
	src.owned.clear()
	src.owned_lists.clear()
	orm_result_free(src)


# ---------------------------------------------------------------------------
# M2M through tables
#
# An M2M hop selects the target rows joined to the through table:
#   SELECT t0.*, t1.<through_from> FROM <target> t0
#   LEFT JOIN <through> t1 ON t1.<through_to> = t0.<pk>
#   WHERE t1.<through_from> IN (...)
# It runs over a private copy of the target descriptor with one extra
# reverse relation "_prefetch_link" to a private descriptor of the through
# table, so the compiler builds the join; the owner key comes back as the
# annotation "_prefetch_key". Rows load exactly as target rows (same
# struct_size and field descriptors).

map[char*, orm_model_desc*] __orm_prefetch_m2m_models


char* ORM_PREFETCH_LINK():
	return c"_prefetch_link"


char* ORM_PREFETCH_KEY():
	return c"_prefetch_key"


orm_model_desc* orm_prefetch_m2m_model(orm_field_desc* rel):
	if (__orm_prefetch_m2m_models == 0): __orm_prefetch_m2m_models = new map[char*, orm_model_desc*]
	string_builder* key = string_new()
	string_append(key, rel.through_table)
	string_append(key, c".")
	string_append(key, rel.through_from)
	if (key.data in __orm_prefetch_m2m_models):
		orm_model_desc* found = __orm_prefetch_m2m_models[key.data]
		string_free(key)
		return found
	orm_model_desc* t = orm_field_target(rel)
	orm_model_desc* through = orm_model_new(rel.through_table, rel.through_table, 2 * sizeof(int))
	orm_model_add_field(through, orm_field_new(rel.through_from, rel.through_from, ORM_INT, 0, 0))
	orm_model_add_field(through, orm_field_new(rel.through_to, rel.through_to, ORM_INT, sizeof(int), 0))
	orm_model_desc* copy = orm_model_new(t.name, t.table, t.struct_size)
	for orm_field_desc* fd in t.fields: orm_model_add_field(copy, fd)
	orm_field_desc* link = orm_field_new(ORM_PREFETCH_LINK(), 0, ORM_REVERSE_FK, -1, 0)
	link.rel_model = through.name
	link.rel_target = through
	link.reverse_field = rel.through_to
	orm_model_add_field(copy, link)
	__orm_prefetch_m2m_models[strclone(key.data)] = copy
	string_free(key)
	return copy


# ---------------------------------------------------------------------------
# Prefetch execution

int orm_prefetch_batch_size(orm_db* db):
	if (__orm_prefetch_batch > 0): return __orm_prefetch_batch
	int n = db.dialect.max_params - 100
	if (n < 1): n = 1
	return n


int orm_prefetch_fail(orm_db* db, char* a, char* b, char* c):
	string_builder* msg = string_new()
	string_append(msg, c"orm: prefetch_related: ")
	string_append(msg, a)
	if (b != 0): string_append(msg, b)
	if (c != 0): string_append(msg, c)
	orm_db_set_error(db, msg.data)
	string_free(msg)
	return 0


# Appends v to l unless already present (keys are few per hop).
void orm_key_add(list[int] l, map[int, int] seen, int v):
	if (v in seen): return
	seen[v] = 1
	l.push(v)


void orm_key_add_ptr(list[void*] l, map[int, int] seen, void* p):
	int k = cast(int, p)
	if (k in seen): return
	seen[k] = 1
	l.push(p)


int orm_prefetch_rows(orm_db* db, orm_model_desc* m, list[void*] rows, list[orm_prefetch*] prefetches, orm_result* owner, int force);


# One hop: everything a hop needs to build its queries and stitch rows.
struct orm_hop:
	orm_db* db
	orm_model_desc* model        # parents' model
	orm_field_desc* rel
	orm_model_desc* target
	orm_model_desc* query_model  # target, or the M2M copy
	orm_query* custom            # Prefetch queryset, or 0
	char* to_attr
	int force                    # FK: reload even when the slot is set
	orm_result* owner
	list[void*] parents
	list[void*] children         # rows loaded by this hop, in query order
	char* key_path               # path of the IN lookup on query_model


# Runs the hop's queries for keys, batching; appends the loaded rows to
# h.children and moves their memory into h.owner.
int orm_hop_query(orm_hop* h, list[int] keys):
	orm_db* db = h.db
	orm_query* base = 0
	if (h.custom != 0):
		if (h.custom.model != h.target):
			return orm_prefetch_fail(db, c"queryset model does not match relation '", h.rel.name, c"'")
		if (h.custom.limit >= 0 || h.custom.offset > 0):
			return orm_prefetch_fail(db, c"a Prefetch queryset cannot be sliced (relation '", h.rel.name, c"')")
		if (h.custom.select.length > 0):
			return orm_prefetch_fail(db, c"a Prefetch queryset cannot use values() (relation '", h.rel.name, c"')")
		base = orm_query_clone(h.custom)
	else: base = orm_query_new(ORM_Q_SELECT, h.target)
	base.model = h.query_model
	base.prefetch.clear()
	if (base.order.length == 0): base.order.push(ord(orm_model_pk(h.target).name))
	if (base.only_fields.length > 0 && h.rel.kind == ORM_REVERSE_FK): base.only_fields.push(h.rel.reverse_field)
	if (h.rel.kind == ORM_M2M):
		orm_annotation* a = new orm_annotation()
		a.name = ORM_PREFETCH_KEY()
		a.expr = f(h.key_path)
		base.annotations.push(a)
	int batch = orm_prefetch_batch_size(db)
	int start = 0
	while (start < keys.length):
		int end = start + batch
		if (end > keys.length): end = keys.length
		list[char*] ids = new list[char*]
		for i in range(end - start): ids.push(orm_format_int(keys[start + i]))
		orm_query* q = orm_query_clone(base)
		q.where = q_and(q.where, q_in(h.key_path, ids))
		orm_result* sub = orm_run_select(db, q, ORM_VALUES_NONE)
		for char* s in ids: free(s)
		ids.free()
		if (sub == 0): return 0
		for void* row in sub.rows: h.children.push(row)
		orm_result_adopt(h.owner, sub)
		start = end
	# Nested prefetches of a Prefetch queryset apply to this hop's rows.
	if (h.custom != 0 && h.custom.prefetch.length > 0 && h.children.length > 0):
		if (orm_prefetch_rows(db, h.target, h.children, h.custom.prefetch, h.owner, 0) == 0): return 0
	return 1


int orm_row_pk_value(orm_model_desc* m, void* row):
	return orm_slot_get(row, orm_model_pk(m).offset)


# Forward FK: one query for the distinct <fk>_id values.
int orm_hop_fk(orm_hop* h):
	orm_field_desc* rel = h.rel
	list[int] keys = new list[int]
	map[int, int] seen = new map[int, int]
	int reuse = h.custom == 0 && h.to_attr == 0 && h.force == 0
	for void* p in h.parents:
		if (reuse && orm_slot_get(p, rel.rel_offset) != 0): continue
		if (rel.null_offset >= 0 && orm_slot_get(p, rel.null_offset) != 0): continue
		int id = orm_slot_get(p, rel.offset)
		if (id == 0 && (rel.flags & ORM_F_NULL) != 0): continue
		orm_key_add(keys, seen, id)
	seen.free()
	h.key_path = orm_model_pk(h.target).name
	int ok = 1
	if (keys.length > 0): ok = orm_hop_query(h, keys)
	keys.free()
	if (ok == 0): return 0
	map[int, int] by_pk = new map[int, int]
	for void* c in h.children:
		int pk = orm_row_pk_value(h.target, c)
		if ((pk in by_pk) == 0): by_pk[pk] = cast(int, c)
	orm_attr_writer* w = 0
	if (h.to_attr != 0): w = orm_attr_writer_new(h.owner, h.to_attr)
	for void* p in h.parents:
		int id = orm_slot_get(p, rel.offset)
		int isnull = rel.null_offset >= 0 && orm_slot_get(p, rel.null_offset) != 0
		void* found = 0
		if (isnull == 0 && (id in by_pk)): found = cast(void*, by_pk[id])
		if (w != 0):
			list[void*] l = orm_result_list(h.owner)
			if (found != 0): l.push(found)
			orm_attr_set(w, h.model, p, l)
		else if (found != 0 || reuse == 0 || orm_slot_get(p, rel.rel_offset) == 0):
			orm_slot_set(p, rel.rel_offset, cast(int, found))
	orm_attr_writer_free(w)
	by_pk.free()
	return 1


# Reverse FK and M2M: one query for the parents' primary keys; each child
# carries the parent key it belongs to.
int orm_hop_many(orm_hop* h):
	orm_field_desc* rel = h.rel
	orm_field_desc* back = 0
	if (rel.kind == ORM_REVERSE_FK):
		back = orm_model_field(h.target, rel.reverse_field)
		if (back == 0 || back.kind != ORM_FK):
			return orm_prefetch_fail(h.db, c"reverse relation '", rel.name, c"' names a missing FK")
		h.key_path = back.name
	else:
		h.query_model = orm_prefetch_m2m_model(rel)
		string_builder* kp = string_new()
		string_append(kp, ORM_PREFETCH_LINK())
		string_append(kp, c"__")
		string_append(kp, rel.through_from)
		h.key_path = orm_result_strdup(h.owner, kp.data)
		string_free(kp)
	# Parents by pk; rows that repeat a pk (joins) chain through next.
	list[int] keys = new list[int]
	map[int, int] head = new map[int, int]
	list[int] next = new list[int]
	list[void*] lists = new list[void*]
	orm_attr_writer* w = 0
	if (h.to_attr != 0): w = orm_attr_writer_new(h.owner, h.to_attr)
	for i in range(h.parents.length):
		void* p = h.parents[i]
		list[void*] l = 0
		if (w != 0):
			l = orm_result_list(h.owner)
			orm_attr_set(w, h.model, p, l)
		else:
			l = cast(list[void*], orm_slot_get(p, rel.rel_offset))
			if (l == 0):
				l = orm_result_list(h.owner)
				orm_slot_set(p, rel.rel_offset, cast(int, l))
			l.clear()
		lists.push(cast(void*, l))
		int pk = orm_row_pk_value(h.model, p)
		next.push(-1)
		if (pk in head): next[i] = head[pk]
		else: keys.push(pk)
		head[pk] = i
	orm_attr_writer_free(w)
	int ok = 1
	if (keys.length > 0): ok = orm_hop_query(h, keys)
	if (ok):
		for void* c in h.children:
			int key = 0
			if (back != 0): key = orm_slot_get(c, back.offset)
			else if (orm_parse_int(orm_row_annotation(h.query_model, c, ORM_PREFETCH_KEY()), &key) == 0): continue
			if ((key in head) == 0): continue
			int j = head[key]
			# head holds the last parent with this pk and next links back to
			# the first, so every duplicate gets the child; the reverse FK
			# pointer goes to the first.
			while (j >= 0):
				list[void*] l = cast(list[void*], lists[j])
				l.push(c)
				if (back != 0 && back.rel_offset >= 0 && next[j] < 0): orm_slot_set(c, back.rel_offset, cast(int, h.parents[j]))
				j = next[j]
	keys.free()
	head.free()
	next.free()
	lists.free()
	return ok


# The rows one level down a path: FK pointers, or list elements (from
# to_attr lists when given), each row once.
list[void*] orm_prefetch_next_rows(orm_model_desc* m, orm_field_desc* rel, list[void*] rows, char* to_attr):
	list[void*] out = new list[void*]
	map[int, int] seen = new map[int, int]
	for void* p in rows:
		if (to_attr != 0):
			list[void*] al = orm_row_prefetched(m, p, to_attr)
			if (al != 0):
				for void* c in al: orm_key_add_ptr(out, seen, c)
		else if (rel.kind == ORM_FK):
			void* c = cast(void*, orm_slot_get(p, rel.rel_offset))
			if (c != 0): orm_key_add_ptr(out, seen, c)
		else:
			list[void*] l = cast(list[void*], orm_slot_get(p, rel.rel_offset))
			if (l != 0):
				for void* c in l: orm_key_add_ptr(out, seen, c)
	seen.free()
	return out


int orm_list_has_str(list[char*] l, char* s):
	for char* x in l:
		if (strcmp(x, s) == 0): return 1
	return 0


# One Prefetch over rows of model m. done holds the default-slot paths
# already fetched in this run (shared prefixes run once).
int orm_prefetch_one(orm_db* db, orm_model_desc* m, list[void*] rows, orm_prefetch* pf, orm_result* owner, list[char*] done, int force):
	if (pf == 0 || pf.path == 0 || pf.path[0] == 0): return orm_prefetch_fail(db, c"empty path", 0, 0)
	list[char*] parts = orm_path_split(pf.path)
	list[void*] level = new list[void*]
	for void* r in rows: level.push(r)
	orm_model_desc* lm = m
	string_builder* prefix = string_new()
	int ok = 1
	for i in range(parts.length):
		int last = i == parts.length - 1
		orm_field_desc* rel = orm_model_field(lm, parts[i])
		if (rel == 0 || (rel.kind != ORM_FK && rel.kind != ORM_M2M && rel.kind != ORM_REVERSE_FK)):
			ok = orm_prefetch_fail(db, c"'", parts[i], c"' is not a relation")
			break
		if (orm_field_target(rel) == 0 || rel.rel_offset < 0):
			ok = orm_prefetch_fail(db, c"relation '", parts[i], c"' is not resolved (call orm_registry_resolve)")
			break
		if (prefix.length > 0): string_append(prefix, c"__")
		string_append(prefix, parts[i])
		orm_query* custom = 0
		char* to_attr = 0
		if (last):
			custom = cast(orm_query*, pf.queryset)
			to_attr = pf.to_attr
		int skip = custom == 0 && to_attr == 0 && force == 0 && orm_list_has_str(done, prefix.data)
		if (skip == 0 && level.length > 0):
			orm_hop* h = new orm_hop()
			h.db = db
			h.model = lm
			h.rel = rel
			h.target = orm_field_target(rel)
			h.query_model = h.target
			h.custom = custom
			h.to_attr = to_attr
			h.force = force && last
			h.owner = owner
			h.parents = level
			h.children = new list[void*]
			if (rel.kind == ORM_FK): ok = orm_hop_fk(h)
			else: ok = orm_hop_many(h)
			h.children.free()
			free(cast(void*, h))
			if (ok == 0): break
			if (to_attr == 0 && orm_list_has_str(done, prefix.data) == 0): done.push(strclone(prefix.data))
		if (last == 0):
			list[void*] next = orm_prefetch_next_rows(lm, rel, level, to_attr)
			level.free()
			level = next
			lm = orm_field_target(rel)
	string_free(prefix)
	level.free()
	for char* p in parts: free(p)
	parts.free()
	return ok


# Runs prefetches over rows of model m, storing new rows in owner.
int orm_prefetch_rows(orm_db* db, orm_model_desc* m, list[void*] rows, list[orm_prefetch*] prefetches, orm_result* owner, int force):
	list[char*] done = new list[char*]
	int ok = 1
	for orm_prefetch* pf in prefetches:
		if (ok): ok = orm_prefetch_one(db, m, rows, pf, owner, done, force)
	for char* d in done: free(d)
	done.free()
	return ok


# Hook called by all()/first()/get() in query.w: runs q.prefetch over the
# model rows of r. Returns 1, or 0 with orm_db_error(db) set.
int orm_prefetch_execute(orm_db* db, orm_query* q, orm_result* r):
	if (r == 0 || q.prefetch.length == 0 || r.rows.length == 0): return 1
	return orm_prefetch_rows(db, q.model, r.rows, q.prefetch, r, 0)


# prefetch_related_objects with Prefetch objects (custom querysets,
# to_attr); see orm_prefetch_related_objects.
orm_result* orm_prefetch_objects(orm_db* db, orm_model_desc* m, list[void*] rows, list[orm_prefetch*] prefetches):
	orm_clear_error(db)
	orm_result* owner = orm_result_new(m)
	if (orm_prefetch_rows(db, m, rows, prefetches, owner, 0) == 0):
		orm_result_free(owner)
		return 0
	return owner


# prefetch_related_objects(rows, path) for rows you already have (from any
# results, or orm_row_new). Returns a new orm_result that owns the loaded
# rows (its rows list is empty): free it only when done with the relation
# slots it filled. 0 on error.
orm_result* orm_prefetch_related_objects(orm_db* db, orm_model_desc* m, list[void*] rows, char* path):
	list[orm_prefetch*] one = new list[orm_prefetch*]
	one.push(orm_prefetch_new(path, 0, 0))
	orm_result* owner = orm_prefetch_objects(db, m, rows, one)
	free(cast(void*, one[0]))
	one.free()
	return owner


# Explicit loader for one relation of one row: always runs one query (none
# for an FK whose id is NULL), replacing the slot (FK pointer, or the
# list's contents for M2M / reverse FK). Returns the orm_result owning the
# loaded rows; free it when done with the slot. 0 on error.
#
# Generated wrappers (bin/orm_gen) are one line per relation:
#   orm_result* Book_load_author(orm_db* db, Book* row): return orm_load_related(db, Book_desc(), row, c"author")
orm_result* orm_load_related(orm_db* db, orm_model_desc* m, void* row, char* field):
	orm_clear_error(db)
	orm_field_desc* rel = orm_model_field(m, field)
	if (rel == 0 || (rel.kind != ORM_FK && rel.kind != ORM_M2M && rel.kind != ORM_REVERSE_FK)):
		orm_prefetch_fail(db, c"'", field, c"' is not a relation")
		return 0
	list[void*] rows = new list[void*]
	rows.push(row)
	list[orm_prefetch*] one = new list[orm_prefetch*]
	orm_prefetch* pf = orm_prefetch_new(field, 0, 0)
	one.push(pf)
	orm_result* owner = orm_result_new(orm_field_target(rel))
	int ok = orm_prefetch_rows(db, m, rows, one, owner, 1)
	free(cast(void*, pf))
	one.free()
	rows.free()
	if (ok == 0):
		orm_result_free(owner)
		return 0
	return owner


# ---------------------------------------------------------------------------
# iterator(): streaming over sql_query_cursor (U0.2)
#
#   orm_iterator* it = Book_objects(db).order_by(c"id").iterator(1000)
#   void* row = it.next()
#   while (row != 0):
#       use(cast(Book*, row))      # valid until chunk_size more rows are read
#       row = it.next()
#   if (orm_iterator_failed(it)): fail(orm_db_error(db))
#   orm_iterator_free(it)
#
# One statement (counted once). Rows are loaded chunk_size at a time into a
# chunk result that is freed when the next chunk is read, so memory stays
# bounded and the 100k-row collector limit does not apply. While the
# iterator is open the connection runs no other statement, so
# prefetch_related is rejected (use prefetch_related_objects per chunk).

struct orm_iterator:
	orm_db* db
	orm_query* query
	int values_mode
	orm_compiled* compiled
	sql_cursor* cursor
	int chunk_size
	orm_result* chunk
	int index
	int done
	int failed


orm_iterator* orm_queryset_iterator(orm_queryset* qs, int chunk_size):
	orm_db* db = qs.db
	orm_clear_error(db)
	orm_query* q = qs.query
	if (q.prefetch.length > 0):
		orm_db_set_error(db, c"orm: iterator() cannot be combined with prefetch_related")
		return 0
	if (db.conn == 0):
		orm_db_set_error(db, c"orm: database is not open")
		return 0
	if (q.for_update && db.dialect.supports_for_update == 0):
		orm_db_set_error(db, c"orm: select_for_update is not supported by this database")
		return 0
	orm_compiled* c = orm_compiled_new(db.dialect)
	if (orm_compile(q, db.dialect, c) == 0):
		if (c.error != 0):
			orm_db_set_error(db, c.error)
			free(c.error)
			c.error = 0
		else: orm_db_set_error(db, c"orm: query did not compile")
		orm_compiled_free(c)
		return 0
	db.query_count = db.query_count + 1
	char* text = c.sql.text.data
	if (db.log_queries): db.query_log.push(strclone(text))
	sql_cursor* cur = sql_query_cursor(db.conn, text, c.sql.parameters.length, sql_builder_values(c.sql))
	if (cur == 0):
		orm_db_set_error(db, sql_error(db.conn))
		orm_compiled_free(c)
		return 0
	orm_iterator* it = new orm_iterator()
	it.db = db
	it.query = q
	it.values_mode = qs.values_mode
	it.compiled = c
	it.cursor = cur
	if (chunk_size < 1): chunk_size = 2000
	it.chunk_size = chunk_size
	return it


int orm_iterator_failed(orm_iterator* it):
	return it == 0 || it.failed


# Reads the next chunk; 1 when it holds rows.
int orm_iterator_fill(orm_iterator* it):
	orm_result_free(it.chunk)
	it.chunk = 0
	it.index = 0
	if (it.done): return 0
	sql_cursor* cur = it.cursor
	int ncols = sql_cursor_columns(cur)
	sql_result* sr = sql_result_new(ncols)
	for i in range(ncols): sr.names.push(strclone(sql_cursor_column_name(cur, i)))
	while (sr.rows < it.chunk_size):
		int rc = sql_cursor_next(cur)
		if (rc < 0):
			orm_db_set_error(it.db, sql_error(it.db.conn))
			it.failed = 1
			it.done = 1
			sql_result_free(sr)
			return 0
		if (rc == 0):
			it.done = 1
			break
		for i in range(ncols):
			char* v = sql_cursor_value(cur, i)
			if (v != 0): v = strclone(v)
			sr.values.push(v)
			sr.lengths.push(sql_cursor_value_length(cur, i))
		sr.rows = sr.rows + 1
	if (sr.rows == 0):
		sql_result_free(sr)
		return 0
	orm_result* r = orm_result_new(it.query.model)
	int ok = 0
	if (it.values_mode != ORM_VALUES_NONE || it.query.select.length > 0): ok = orm_load_values(it.db, it.query, it.compiled, sr, r)
	else: ok = orm_load_models(it.db, it.query.model, it.compiled, sr, r)
	sql_result_free(sr)
	if (ok == 0):
		orm_result_free(r)
		it.failed = 1
		it.done = 1
		return 0
	it.chunk = r
	return 1


# The next row (model row or orm_values_row*), or 0 at the end or on error
# (orm_iterator_failed). A row stays valid until chunk_size further rows
# have been read or the iterator is freed.
void* orm_iterator_next(orm_iterator* it):
	if (it == 0 || it.failed): return 0
	if (it.chunk == 0 || it.index >= it.chunk.rows.length):
		if (orm_iterator_fill(it) == 0): return 0
	void* row = it.chunk.rows[it.index]
	it.index = it.index + 1
	return row


# Frees the iterator, its current chunk and the cursor (an unfinished
# cursor is finalized / cancelled, see U0.2).
void orm_iterator_free(orm_iterator* it):
	if (it == 0): return
	orm_result_free(it.chunk)
	sql_cursor_free(it.cursor)
	orm_compiled_free(it.compiled)
	free(cast(void*, it))


# Callback form: fn(row, ctx) returns 1 to continue, 0 to stop. Returns the
# number of rows delivered, or -1 with orm_db_error(db) set.
type orm_row_fn = fn(void*, void*) -> int

int orm_queryset_each(orm_queryset* qs, int chunk_size, orm_row_fn* fn, void* ctx):
	orm_iterator* it = orm_queryset_iterator(qs, chunk_size)
	if (it == 0): return -1
	int n = 0
	void* row = orm_iterator_next(it)
	while (row != 0):
		n = n + 1
		if (fn(row, ctx) == 0): break
		row = orm_iterator_next(it)
	int failed = it.failed
	orm_iterator_free(it)
	if (failed): return -1
	return n
