# Hand-written fixture: exactly what bin/orm_gen (U1.1) generates as the
# data module for tests/orm/fixtures/library.orm. Wave-1 units build and test
# against this file instead of against each other (docs/projects/orm.md).
#
# Generated data-module shape, per model M in FK dependency order:
#   struct M                                   the row struct (C1 layout rules)
#   orm_model_desc* M_desc()                   builds + registers the descriptor once
#   char* M_f_<field>()                        field handles (lookup paths)
#   <T>* M_<fk>(M*) / list[T*] M_<rel>(M*)     typed relation accessors
#   char* M_<ENUM>_<value>()                   enum values
# plus `void library_register()` registering every model and resolving.
import libs.standard.orm.contract


struct Author:
	int id
	char* name
	char* email
	char* created
	list[void*] books


struct Tag:
	int id
	char* name


struct Book:
	int id
	char* title
	int author_id
	Author* author
	list[void*] tags
	char* status
	char* price
	int pages
	int pages__isnull
	char* published_at


orm_model_desc* __library_Author_desc
orm_model_desc* __library_Tag_desc
orm_model_desc* __library_Book_desc


int __library_offset(void* base, void* field):
	return cast(int, field) - cast(int, base)


orm_model_desc* Author_desc():
	if (__library_Author_desc != 0): return __library_Author_desc
	Author probe
	orm_model_desc* m = orm_model_new(c"Author", c"library_author", sizeof(Author))
	orm_model_add_field(m, orm_field_new(c"id", c"id", ORM_INT, __library_offset(&probe, &probe.id), ORM_F_PK | ORM_F_AUTO))
	orm_field_desc* f = orm_model_add_field(m, orm_field_new(c"name", c"name", ORM_TEXT, __library_offset(&probe, &probe.name), 0))
	f.max_length = 200
	f = orm_model_add_field(m, orm_field_new(c"email", c"email", ORM_TEXT, __library_offset(&probe, &probe.email), ORM_F_UNIQUE))
	f.max_length = 254
	orm_model_add_field(m, orm_field_new(c"created", c"created", ORM_DATETIME, __library_offset(&probe, &probe.created), ORM_F_AUTO_NOW_ADD))
	f = orm_model_add_field(m, orm_field_new(c"books", 0, ORM_REVERSE_FK, -1, 0))
	f.rel_model = c"Book"
	f.rel_offset = __library_offset(&probe, &probe.books)
	f.reverse_field = c"author"
	orm_index_desc* idx = new orm_index_desc()
	idx.name = c"library_author_created_idx"
	idx.columns = new list[char*]
	idx.columns.push(c"created")
	m.indexes.push(idx)
	orm_register(m)
	__library_Author_desc = m
	return m


orm_model_desc* Tag_desc():
	if (__library_Tag_desc != 0): return __library_Tag_desc
	Tag probe
	orm_model_desc* m = orm_model_new(c"Tag", c"library_tag", sizeof(Tag))
	orm_model_add_field(m, orm_field_new(c"id", c"id", ORM_INT, __library_offset(&probe, &probe.id), ORM_F_PK | ORM_F_AUTO))
	orm_field_desc* f = orm_model_add_field(m, orm_field_new(c"name", c"name", ORM_TEXT, __library_offset(&probe, &probe.name), ORM_F_UNIQUE))
	f.max_length = 50
	orm_register(m)
	__library_Tag_desc = m
	return m


orm_model_desc* Book_desc():
	if (__library_Book_desc != 0): return __library_Book_desc
	Book probe
	orm_model_desc* m = orm_model_new(c"Book", c"library_book", sizeof(Book))
	m.history = 1
	orm_model_add_field(m, orm_field_new(c"id", c"id", ORM_INT, __library_offset(&probe, &probe.id), ORM_F_PK | ORM_F_AUTO))
	orm_field_desc* f = orm_model_add_field(m, orm_field_new(c"title", c"title", ORM_TEXT, __library_offset(&probe, &probe.title), 0))
	f.max_length = 300
	f = orm_model_add_field(m, orm_field_new(c"author", c"author_id", ORM_FK, __library_offset(&probe, &probe.author_id), ORM_F_INDEXED))
	f.rel_model = c"Author"
	f.rel_offset = __library_offset(&probe, &probe.author)
	f.on_delete = ORM_CASCADE
	f.related_name = c"books"
	f = orm_model_add_field(m, orm_field_new(c"tags", 0, ORM_M2M, -1, 0))
	f.rel_model = c"Tag"
	f.rel_offset = __library_offset(&probe, &probe.tags)
	f.through_table = c"library_book_tags"
	f.through_from = c"book_id"
	f.through_to = c"tag_id"
	f = orm_model_add_field(m, orm_field_new(c"status", c"status", ORM_ENUM, __library_offset(&probe, &probe.status), 0))
	f.default_sql = c"'draft'"
	f.max_length = 5
	f.enum_values.push(c"draft")
	f.enum_values.push(c"pub")
	f = orm_model_add_field(m, orm_field_new(c"price", c"price", ORM_DECIMAL, __library_offset(&probe, &probe.price), 0))
	f.digits = 8
	f.places = 2
	f = orm_model_add_field(m, orm_field_new(c"pages", c"pages", ORM_INT, __library_offset(&probe, &probe.pages), ORM_F_NULL))
	f.null_offset = __library_offset(&probe, &probe.pages__isnull)
	orm_model_add_field(m, orm_field_new(c"published_at", c"published_at", ORM_DATETIME, __library_offset(&probe, &probe.published_at), ORM_F_NULL))
	orm_check_desc* chk = new orm_check_desc()
	chk.name = c"library_book_price_nonnegative"
	chk.condition_sql = c"price >= 0"
	m.checks.push(chk)
	orm_register(m)
	__library_Book_desc = m
	return m


# Field handles.
char* Author_f_id(): return c"id"
char* Author_f_name(): return c"name"
char* Author_f_email(): return c"email"
char* Author_f_created(): return c"created"
char* Author_f_books(): return c"books"
char* Tag_f_id(): return c"id"
char* Tag_f_name(): return c"name"
char* Book_f_id(): return c"id"
char* Book_f_title(): return c"title"
char* Book_f_author(): return c"author"
char* Book_f_tags(): return c"tags"
char* Book_f_status(): return c"status"
char* Book_f_price(): return c"price"
char* Book_f_pages(): return c"pages"
char* Book_f_published_at(): return c"published_at"


# Enum values.
char* Book_Status_draft(): return c"draft"
char* Book_Status_pub(): return c"pub"


# Typed relation accessors (relation slots hold void*/list[void*]).
Author* Book_author(Book* b): return b.author
list[Tag*] Book_tags(Book* b): return cast(list[Tag*], b.tags)
list[Book*] Author_books(Author* a): return cast(list[Book*], a.books)


void library_register():
	Author_desc()
	Tag_desc()
	Book_desc()
	char* missing = 0
	if (orm_registry_resolve(&missing) == 0):
		print(c"library_register: unresolved relation target ")
		println(missing)
