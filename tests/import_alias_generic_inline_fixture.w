# Root for import_alias_generic_inline_test.
import tests.import_alias_generic_module as g


int twice[T](T key):
	return g.alias_grow[int](1) * 2


int main():
	return g.alias_grow[int](1) + twice[int](1) - 96
