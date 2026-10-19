# Prints the canonical descriptor dump (libs/standard/orm/schema/dump.w) of
# the hand-written library fixture. orm_gen_test (tools/orm_gen.w) compares
# it with orm_gen_dump_generated.w's output: bin/orm_gen must produce
# descriptors identical to tests/orm/fixtures/library_orm.w.
import tests.orm.fixtures.library_orm
import libs.standard.orm.schema.dump


int main():
	library_register()
	print(orm_schema_dump_registry())
	return 0
