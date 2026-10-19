# Hand-written fixture: exactly what bin/orm_gen (U1.1) generates as the
# API module for tests/orm/fixtures/library.orm (docs/projects/orm.md,
# "Generated code shape"). Per model M: M_objects, M_rows, M_new, M_save,
# M_delete, M_free over the runtime in libs/standard/orm/orm.w.
import tests.orm.fixtures.library_orm
import libs.standard.orm.orm


orm_queryset* Author_objects(orm_db* db): return orm_objects(db, Author_desc())
list[Author*] Author_rows(orm_result* r): return cast(list[Author*], r.rows)
Author* Author_new(): return cast(Author*, orm_row_new(Author_desc()))
int Author_save(orm_db* db, Author* row): return orm_save(db, Author_desc(), row)
int Author_delete(orm_db* db, Author* row): return orm_delete_row(db, Author_desc(), row)
void Author_free(Author* row): orm_row_free(Author_desc(), row)


orm_queryset* Tag_objects(orm_db* db): return orm_objects(db, Tag_desc())
list[Tag*] Tag_rows(orm_result* r): return cast(list[Tag*], r.rows)
Tag* Tag_new(): return cast(Tag*, orm_row_new(Tag_desc()))
int Tag_save(orm_db* db, Tag* row): return orm_save(db, Tag_desc(), row)
int Tag_delete(orm_db* db, Tag* row): return orm_delete_row(db, Tag_desc(), row)
void Tag_free(Tag* row): orm_row_free(Tag_desc(), row)


orm_queryset* Book_objects(orm_db* db): return orm_objects(db, Book_desc())
list[Book*] Book_rows(orm_result* r): return cast(list[Book*], r.rows)
Book* Book_new(): return cast(Book*, orm_row_new(Book_desc()))
int Book_save(orm_db* db, Book* row): return orm_save(db, Book_desc(), row)
int Book_delete(orm_db* db, Book* row): return orm_delete_row(db, Book_desc(), row)
void Book_free(Book* row): orm_row_free(Book_desc(), row)
