# Prints the canonical descriptor dump (libs/standard/orm/schema/dump.w) of
# the bin/orm_gen output for tests/orm/fixtures/library.orm (written to
# tests/orm/generated/ by the orm_generated target). orm_gen_test compares
# it with orm_gen_dump_fixture.w's output.
import tests.orm.generated.library_orm
import libs.standard.orm.schema.dump


int main():
	library_register()
	print(orm_schema_dump_registry())
	return 0
