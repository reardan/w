# wbuild: arch_only=x64
# U1.1: the descriptors bin/orm_gen generates for tests/orm/fixtures/shop.orm
# (every type and option; written to tests/orm/generated/ by the
# orm_generated target) compile, register, resolve and match the schema.
import tests.orm.generated.shop_orm
import lib.assert
import lib.str


void check_fields_fit(orm_model_desc* m):
	for orm_field_desc* f in m.fields:
		if (f.offset >= 0): assert1(f.offset + f.size <= m.struct_size)
		if (f.rel_offset >= 0): assert1(f.rel_offset + sizeof(int) <= m.struct_size)
		if (f.null_offset >= 0): assert1(f.null_offset + sizeof(int) <= m.struct_size)
		if (orm_field_has_column(f)): assert1(f.offset >= 0)
		else:
			assert1(f.offset == -1)
			assert1(f.rel_offset >= 0)


orm_field_desc* field(orm_model_desc* m, char* name):
	orm_field_desc* f = orm_model_field(m, name)
	if (f == 0):
		print(c"missing field ")
		println(name)
	assert1(f != 0)
	return f


void test_registry():
	shop_register()
	list[orm_model_desc*] models = orm_registry_models()
	assert_equal(5, models.length)
	assert_strings_equal(c"Coupon", models[0].name)
	assert_strings_equal(c"Country", models[1].name)
	assert_strings_equal(c"Customer", models[2].name)
	assert_strings_equal(c"Store", models[3].name)
	assert_strings_equal(c"Order", models[4].name)
	for orm_model_desc* m in models:
		check_fields_fit(m)
		assert1(m.schema_json != 0)
		assert_contains(m.schema_json, m.table)
		for orm_field_desc* f in m.fields:
			if (f.rel_model != 0): assert1(f.rel_target == orm_model_lookup(f.rel_model))


void test_customer():
	orm_model_desc* m = Customer_desc()
	assert_strings_equal(c"shop_customers", m.table)
	assert_equal(sizeof(Customer), m.struct_size)
	Customer probe
	assert_equal(ORM_F_DEPRECATED, field(m, c"legacy_code").flags)
	assert_equal(ORM_F_NO_HISTORY | ORM_F_READ_ONLY, field(m, c"secret").flags)
	assert_equal(ORM_F_INDEXED, field(m, c"visits").flags)
	assert_equal(ORM_F_AUTO_NOW, field(m, c"touched").flags)
	assert_strings_equal(c"CURRENT_TIMESTAMP", field(m, c"touched").default_sql)
	assert_strings_equal(c"TRUE", field(m, c"active").default_sql)
	assert_equal(ORM_BOOL, field(m, c"active").kind)
	assert_equal(ORM_BIGINT, field(m, c"points").kind)
	assert_equal(ORM_FLOAT, field(m, c"rating").kind)
	assert_equal(ORM_UUID, field(m, c"token").kind)
	assert_equal(ORM_JSON, field(m, c"prefs").kind)
	assert_strings_equal(c"'{}'", field(m, c"prefs").default_sql)
	assert_equal(ORM_DATE, field(m, c"birthday").kind)
	assert_equal(0, field(m, c"bio").max_length)
	# Self FK, nullable: void* slot, null flag, typed accessor.
	orm_field_desc* ref = field(m, c"referrer")
	assert_equal(ORM_FK, ref.kind)
	assert_strings_equal(c"referrer_id", ref.column)
	assert_equal(ORM_F_NULL | ORM_F_INDEXED, ref.flags)
	assert_equal(ORM_SET_NULL, ref.on_delete)
	assert_equal(cast(int, &probe.referrer_id) - cast(int, &probe), ref.offset)
	assert_equal(cast(int, &probe.referrer) - cast(int, &probe), ref.rel_offset)
	assert_equal(cast(int, &probe.referrer__isnull) - cast(int, &probe), ref.null_offset)
	assert_equal(ORM_PROTECT, field(m, c"favorite_store").on_delete)
	Customer other
	probe.referrer = &other
	assert1(Customer_referrer(&probe) == &other)
	# Reverse relations appended after the model's own fields.
	int n = m.fields.length
	assert_strings_equal(c"referrals", m.fields[n - 3].name)
	assert_strings_equal(c"stores", m.fields[n - 2].name)
	assert_strings_equal(c"orders", m.fields[n - 1].name)
	assert_equal(ORM_REVERSE_FK, m.fields[n - 1].kind)
	assert_strings_equal(c"customer", m.fields[n - 1].reverse_field)
	assert_strings_equal(c"customer_email_active", m.indexes[0].name)
	assert_equal(2, m.indexes[0].columns.length)
	assert_strings_equal(c"active", m.indexes[0].columns[1])


void test_store_order():
	orm_model_desc* store = Store_desc()
	orm_field_desc* peers = field(store, c"neighbors")
	assert_equal(ORM_M2M, peers.kind)
	assert_strings_equal(c"shop_store_neighbors", peers.through_table)
	assert_strings_equal(c"from_store_id", peers.through_from)
	assert_strings_equal(c"to_store_id", peers.through_to)
	assert_strings_equal(c"'Main Street'", field(store, c"name").default_sql)
	assert_equal(ORM_RESTRICT, field(store, c"owner").on_delete)
	orm_model_desc* order = Order_desc()
	assert_equal(1, order.history)
	orm_field_desc* state = field(order, c"state")
	assert_equal(ORM_ENUM, state.kind)
	assert_equal(9, state.max_length)
	assert_equal(4, state.enum_values.length)
	assert_strings_equal(c"shipped", Order_State_shipped())
	assert_strings_equal(c"0.00", field(order, c"total").default_sql)
	assert_equal(12, field(order, c"total").digits)
	assert_strings_equal(c"NULL", field(order, c"discount").default_sql)
	assert1(field(order, c"discount").null_offset > 0)
	assert_equal(ORM_SET_DEFAULT, field(order, c"coupon").on_delete)
	assert_equal(ORM_DO_NOTHING, field(order, c"store").on_delete)
	assert_equal(1, order.unique_together.length)
	assert_strings_equal(c"customer_id", order.unique_together[0][0])
	assert_strings_equal(c"store_id", order.unique_together[0][1])
	assert_equal(2, order.checks.length)
	assert_strings_equal(c"shop_order_total_check", order.checks[0].name)
	assert_strings_equal(c"shop_order_check2", order.checks[1].name)
	assert_strings_equal(c"quantity > 0", order.checks[1].condition_sql)


void test_custom_pk():
	orm_model_desc* country = Country_desc()
	assert_equal(0, country.pk_index)
	orm_field_desc* pk = orm_model_pk(country)
	assert_strings_equal(c"iso", pk.name)
	assert_equal(ORM_F_PK, pk.flags)
	assert_equal(ORM_TEXT, pk.kind)
	assert_equal(2, country.fields.length)


void test_snapshot():
	char* json = shop_schema_json()
	assert1(starts_with_at(json, c"{\"format\":\"w-orm-schema\",\"version\":1,\"app\":\"shop\",\"models\":[", 0))
	assert_contains(json, c"\"deprecated\":true")
	assert_contains(json, c"\"table\":\"shop_customers\"")


int main():
	test_registry()
	test_customer()
	test_store_order()
	test_custom_pk()
	test_snapshot()
	println(c"orm_gen_shop_test: ok")
	return 0
