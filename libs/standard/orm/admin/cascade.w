# w-orm admin delete preview (unit U5.1, docs/projects/orm/u5_1.md):
# what deleting a row takes with it, following every registered FK's
# on_delete (Django's NestedObjects collector). The database performs the
# cascade itself (the FKs are ON DELETE CASCADE / RESTRICT); this only
# reads, so the confirmation page can list it.
#
#   adm_cascade* c = orm_admin_collect(db, site, Author_desc(), author)
#   c.root            # tree: the row, then the rows cascading from it
#   c.protected       # rows whose PROTECT / RESTRICT FK blocks the delete
#   c.links           # M2M link rows that go with them (counts per table)
#
# Cost: one query per (level, FK pointing at the level's model) and one
# COUNT per M2M relation of a level's model, independent of row counts.
import libs.standard.orm.admin.site


struct adm_node:
	orm_model_desc* model
	int pk
	char* label                  # owned
	list[adm_node*] children


struct adm_link_count:
	char* name                   # owned, "Book-tag relationship"
	int count


struct adm_cascade:
	adm_node* root
	list[adm_node*] protected    # owned nodes (no children)
	list[adm_link_count*] links
	map[char*, int] counts       # model name -> objects deleted
	list[char*] order            # model names in first-seen order
	int queries
	int failed


adm_node* adm_node_new(orm_admin_site* site, orm_model_desc* m, void* row):
	adm_node* n = new adm_node()
	n.model = m
	n.pk = orm_slot_get(row, orm_model_pk(m).offset)
	n.label = orm_admin_label(site, m, row)
	n.children = new list[adm_node*]
	return n


void adm_node_free(adm_node* n):
	for adm_node* c in n.children: adm_node_free(c)
	n.children.free()
	free(n.label)
	free(cast(void*, n))


void adm_cascade_free(adm_cascade* c):
	if (c == 0): return
	if (c.root != 0): adm_node_free(c.root)
	for adm_node* p in c.protected: adm_node_free(p)
	c.protected.free()
	for adm_link_count* l in c.links:
		free(l.name)
		free(cast(void*, l))
	c.links.free()
	map_free[char*, int](c.counts)
	c.order.free()
	free(cast(void*, c))


void adm_cascade_count(adm_cascade* c, orm_model_desc* m, int n):
	if (m.name in c.counts): c.counts[m.name] = c.counts[m.name] + n
	else:
		c.counts[m.name] = n
		c.order.push(m.name)


# "<Model>-<target> relationship" (Django's through model verbose name).
char* adm_link_name(orm_model_desc* m, orm_model_desc* target):
	char* t = auth_verbose_name(target.name)
	string_builder* s = string_new()
	string_append(s, m.name)
	string_append_char(s, '-')
	string_append(s, t)
	string_append(s, c" relationship")
	free(t)
	char* out = s.data
	free(cast(void*, s))
	return out


void adm_cascade_link(adm_cascade* c, char* name, int n):
	for adm_link_count* l in c.links:
		if (strcmp(l.name, name) == 0):
			l.count = l.count + n
			free(name)
			return
	adm_link_count* nl = new adm_link_count()
	nl.name = name
	nl.count = n
	c.links.push(nl)


adm_node* adm_find_node(list[adm_node*] nodes, int pk):
	for adm_node* n in nodes:
		if (n.pk == pk): return n
	return 0


# Collects what cascades from `level` (nodes of model m, all already in
# the tree). depth bounds self-referencing cycles.
void adm_collect_level(orm_db* db, orm_admin_site* site, adm_cascade* c, orm_model_desc* m, list[adm_node*] level, int depth):
	if (level.length == 0 || c.failed || depth > 16): return
	list[char*] ids = new list[char*]
	for adm_node* n in level: ids.push(itoa(n.pk))
	# M2M link rows of these objects (either side of the relation).
	for orm_model_desc* rm in orm_registry_models():
		for orm_field_desc* mf in rm.fields:
			if (c.failed): break
			if (mf.kind != ORM_M2M || mf.through_table == 0 || mf.rel_target == 0): continue
			char* col = 0
			if (rm == m): col = mf.through_from
			else if (orm_field_target(mf) == m): col = mf.through_to
			if (col == 0): continue
			orm_model_desc* through = orm_through_desc(mf)
			int n = orm_objects(db, through).filter(q_in(col, ids)).count()
			c.queries = c.queries + 1
			if (n < 0): c.failed = 1
			else if (n > 0): adm_cascade_link(c, adm_link_name(rm, orm_field_target(mf)), n)
	# Rows whose FK points at these objects.
	for orm_model_desc* fm in orm_registry_models():
		for orm_field_desc* f in fm.fields:
			if (c.failed): break
			if (f.kind != ORM_FK || f.rel_target != cast(void*, m)): continue
			int od = f.on_delete
			if (od != ORM_CASCADE && od != ORM_PROTECT && od != ORM_RESTRICT): continue
			orm_field_desc* fpk = orm_model_pk(fm)
			if (fpk == 0): continue
			orm_result* r = orm_objects(db, fm).filter(q_in(f.name, ids)).order_by(fpk.name).all()
			c.queries = c.queries + 1
			if (r == 0):
				c.failed = 1
				break
			list[adm_node*] next = new list[adm_node*]
			for void* row in r.rows:
				adm_node* child = adm_node_new(site, fm, row)
				if (od == ORM_CASCADE):
					adm_node* parent = adm_find_node(level, orm_slot_get(row, f.offset))
					if (parent == 0):
						adm_node_free(child)
						continue
					parent.children.push(child)
					next.push(child)
				else: c.protected.push(child)
			orm_result_free(r)
			if (next.length > 0):
				adm_cascade_count(c, fm, next.length)
				adm_collect_level(db, site, c, fm, next, depth + 1)
			next.free()
	adm_free_list(ids)


# The delete preview of `row` (of model m). c.failed is set (with
# orm_db_error) when a query failed.
adm_cascade* orm_admin_collect(orm_db* db, orm_admin_site* site, orm_model_desc* m, void* row):
	adm_cascade* c = new adm_cascade()
	c.protected = new list[adm_node*]
	c.links = new list[adm_link_count*]
	c.counts = new map[char*, int]
	c.order = new list[char*]
	c.root = adm_node_new(site, m, row)
	adm_cascade_count(c, m, 1)
	list[adm_node*] level = new list[adm_node*]
	level.push(c.root)
	adm_collect_level(db, site, c, m, level, 0)
	level.free()
	return c
